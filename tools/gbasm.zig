const std = @import("std");

// gbasm - a two-pass assembler for the SM83.
//
// It reads assembly source and writes a Game Boy ROM image. The project
// uses it to regenerate the bundled test ROMs from their assembly sources,
// so the automated test suite never depends on downloaded binaries.
//
// Directives: org, db, dw, ds.
// Numbers: $FF, 0xFF, %101, 0b101, decimal, 'c'.
// A label is a name followed by ':'. An immediate is a number, a label, or
// a label with a +/- constant suffix. Mnemonics and registers are matched
// case-insensitively.

const MaxOperands = 3;

const DbItem = union(enum) {
    byte: Expr,
    string: []const u8,
};

const Expr = union(enum) {
    number: i32,
    label: []const u8,
};

const Instr = struct {
    mnemonic: []const u8,
    operands: [MaxOperands]?[]const u8 = .{ null, null, null },
    count: u8 = 0,
};

const Kind = union(enum) {
    org: u16,
    db: []const DbItem,
    dw: []const Expr,
    ds: u16,
    instr: Instr,
};

const Statement = struct {
    address: u16 = 0,
    label: ?[]const u8 = null,
    kind: Kind,
};

pub const Error = error{
    InvalidMnemonic,
    InvalidOperand,
    MissingOperand,
    ExtraOperand,
    UndefinedLabel,
    DuplicateLabel,
    BadNumber,
    Range,
    OutOfMemory,
};

const SymbolMap = std.StringHashMapUnmanaged(u16);

// Operand shapes used for sizing. An immediate may be a number or a label.
const Shape = enum { reg8, reg16, imm8, imm16, rel8 };

const Assembler = struct {
    allocator: std.mem.Allocator,
    statements: std.ArrayListUnmanaged(Statement) = .empty,
    symbols: SymbolMap = .empty,

    fn deinit(self: *Assembler) void {
        const a = self.allocator;
        for (self.statements.items) |*stmt| switch (stmt.kind) {
            .db => |items| a.free(items),
            .dw => |items| a.free(items),
            else => {},
        };
        self.statements.deinit(a);
        self.symbols.deinit(a);
    }

    fn trim(s: []const u8) []const u8 {
        return std.mem.trim(u8, s, " \t\r\n");
    }

    // Strips a comment, respecting single and double quotes.
    fn stripComment(line: []const u8) []const u8 {
        var in_single = false;
        var in_double = false;
        for (line, 0..) |c, i| {
            switch (c) {
                '\'' => in_single = !in_single,
                '"' => in_double = !in_double,
                ';' => if (!in_single and !in_double) return line[0..i],
                else => {},
            }
        }
        return line;
    }

    fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
        }
        return true;
    }

    fn isLabelChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
    }

    fn labelName(token: []const u8) ?[]const u8 {
        if (token.len == 0 or !isLabelChar(token[0])) return null;
        var end: usize = 1;
        while (end < token.len and isLabelChar(token[end])) : (end += 1) {}
        return token[0..end];
    }

    fn parseNumber(self: *Assembler, token: []const u8) Error!i32 {
        _ = self;
        if (token.len == 0) return error.BadNumber;
        if (token[0] == '\'') {
            if (token.len != 3 or token[2] != '\'') return error.BadNumber;
            return token[1];
        }
        var base: u8 = 10;
        var digits = token;
        if (token[0] == '$') {
            base = 16;
            digits = token[1..];
        } else if (std.mem.startsWith(u8, token, "0x")) {
            base = 16;
            digits = token[2..];
        } else if (token[0] == '%') {
            base = 2;
            digits = token[1..];
        } else if (std.mem.startsWith(u8, token, "0b")) {
            base = 2;
            digits = token[2..];
        }
        if (digits.len == 0) return error.BadNumber;
        var value: i64 = 0;
        for (digits) |c| {
            const d: i32 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.BadNumber,
            };
            if (d >= base) return error.BadNumber;
            value = value * base + d;
        }
        if (value > std.math.maxInt(i32)) return error.BadNumber;
        return @intCast(value);
    }

    fn parseExpr(self: *Assembler, token: []const u8) Error!Expr {
        if (self.parseNumber(token)) |n| {
            return .{ .number = n };
        } else |err| {
            if (err != error.BadNumber) return err;
        }
        // Label with optional +/- constant suffix. The offset is only
        // validated; plain labels encode their base address.
        if (labelName(token)) |name| {
            const rest = token[name.len..];
            if (rest.len == 0) return .{ .label = name };
            if (rest.len >= 2 and (rest[0] == '+' or rest[0] == '-')) {
                _ = try self.parseNumber(rest[1..]);
                return .{ .label = name };
            }
        }
        return error.InvalidOperand;
    }

    fn exprValue(self: *Assembler, expr: Expr) Error!u16 {
        return switch (expr) {
            .number => |n| blk: {
                if (n < 0 or n > 0xffff) return error.Range;
                break :blk @intCast(n);
            },
            .label => |name| self.symbols.get(name) orelse error.UndefinedLabel,
        };
    }

    fn exprByte(self: *Assembler, expr: Expr) Error!u8 {
        const v = try self.exprValue(expr);
        if (v > 0xff) return error.Range;
        return @intCast(v);
    }

    // ---- operand classification -----------------------------------------

    fn reg8Index(token: []const u8) ?u8 {
        if (token.len == 1) {
            for ("bcdeh", 0..) |c, i| {
                if (std.ascii.toLower(token[0]) == c) return @intCast(i);
            }
            if (std.ascii.toLower(token[0]) == 'a') return 7;
            if (std.ascii.toLower(token[0]) == 'l') return 5;
        }
        if (token.len == 4 and eqIgnoreCase(token, "(hl)")) return 6;
        return null;
    }

    fn reg16Index(token: []const u8) ?u2 {
        const names = [_][]const u8{ "bc", "de", "hl", "sp" };
        for (names, 0..) |name, i| {
            if (eqIgnoreCase(token, name)) return @intCast(i);
        }
        return null;
    }

    fn condIndex(token: []const u8) ?u2 {
        const names = [_][]const u8{ "nz", "z", "nc", "c" };
        for (names, 0..) |name, i| {
            if (eqIgnoreCase(token, name)) return @intCast(i);
        }
        return null;
    }

    // Stack pair index for PUSH/POP: BC=0, DE=1, HL=2, AF=3.
    fn stack16Index(token: []const u8) ?u2 {
        if (eqIgnoreCase(token, "af")) return 3;
        return reg16Index(token);
    }

    fn isParenthesized(token: []const u8) bool {
        return token.len >= 2 and token[0] == '(' and token[token.len - 1] == ')';
    }

    fn parenInner(token: []const u8) []const u8 {
        return token[1 .. token.len - 1];
    }

    // Classifies an operand token into an encoding shape.
    fn classify(self: *Assembler, token: []const u8) Shape {
        _ = self;
        if (reg8Index(token) != null) return .reg8;
        if (reg16Index(token) != null) return .reg16;
        if (isParenthesized(token)) return .imm16;
        return .imm8; // numbers and labels
    }

    // ---- parsing --------------------------------------------------------

    fn splitMnemonic(line: []const u8) struct { name: []const u8, rest: []const u8 } {
        const trimmed = trim(line);
        var end: usize = 0;
        while (end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[end]) or trimmed[end] == '.')) : (end += 1) {}
        return .{ .name = trimmed[0..end], .rest = trim(trimmed[end..]) };
    }

    fn splitOperands(self: *Assembler, allocator: std.mem.Allocator, rest: []const u8) Error![]const []const u8 {
        _ = self;
        var result: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer result.deinit(allocator);
        var start: usize = 0;
        var i: usize = 0;
        var in_single = false;
        var in_double = false;
        while (i < rest.len) : (i += 1) {
            switch (rest[i]) {
                '\'' => in_single = !in_single,
                '"' => in_double = !in_double,
                ',' => if (!in_single and !in_double) {
                    try result.append(allocator, trim(rest[start..i]));
                    start = i + 1;
                },
                else => {},
            }
        }
        if (rest.len != 0) try result.append(allocator, trim(rest[start..]));
        return result.toOwnedSlice(allocator);
    }

    fn parseLine(self: *Assembler, allocator: std.mem.Allocator, line: []const u8) Error!?Statement {
        const trimmed = trim(stripComment(line));
        if (trimmed.len == 0) return null;

        var label: ?[]const u8 = null;
        var body = trimmed;

        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            const head = trim(trimmed[0..colon]);
            if (head.len != 0 and labelName(head) != null and eqIgnoreCase(head, labelName(head).?)) {
                label = head;
                body = trim(trimmed[colon + 1 ..]);
                if (body.len == 0) {
                    // A bare label carries no bytes and does not move the
                    // program counter.
                    return .{ .label = label, .kind = .{ .ds = 0 } };
                }
            }
        }

        const mn = splitMnemonic(body);
        const operands = try self.splitOperands(allocator, mn.rest);
        defer allocator.free(operands);
        var count: usize = 0;
        while (count < operands.len and operands[count].len != 0) : (count += 1) {}

        if (eqIgnoreCase(mn.name, "org")) {
            if (count != 1) return error.InvalidOperand;
            const value = try self.exprValue(try self.parseExpr(operands[0]));
            return .{ .label = label, .kind = .{ .org = value } };
        }
        if (eqIgnoreCase(mn.name, "db")) {
            if (count == 0) return error.InvalidOperand;
            const items = try self.parseDbItems(allocator, operands[0..count]);
            return .{ .label = label, .kind = .{ .db = items } };
        }
        if (eqIgnoreCase(mn.name, "dw")) {
            if (count == 0) return error.InvalidOperand;
            const items = try self.parseDwItems(allocator, operands[0..count]);
            return .{ .label = label, .kind = .{ .dw = items } };
        }
        if (eqIgnoreCase(mn.name, "ds")) {
            if (count != 1) return error.InvalidOperand;
            const value = try self.exprValue(try self.parseExpr(operands[0]));
            return .{ .label = label, .kind = .{ .ds = value } };
        }

        if (count > MaxOperands) return error.ExtraOperand;
        var instr = Instr{ .mnemonic = mn.name };
        for (operands[0..count], 0..) |op, i| instr.operands[i] = op;
        instr.count = @intCast(count);
        return .{ .label = label, .kind = .{ .instr = instr } };
    }

    fn parseDbItems(self: *Assembler, allocator: std.mem.Allocator, items: []const []const u8) Error![]const DbItem {
        var result: std.ArrayListUnmanaged(DbItem) = .empty;
        errdefer result.deinit(allocator);
        for (items) |item| {
            if (item.len >= 2 and item[0] == '"' and item[item.len - 1] == '"') {
                try result.append(allocator, .{ .string = item[1 .. item.len - 1] });
            } else {
                try result.append(allocator, .{ .byte = try self.parseExpr(item) });
            }
        }
        return result.toOwnedSlice(allocator);
    }

    fn parseDwItems(self: *Assembler, allocator: std.mem.Allocator, items: []const []const u8) Error![]const Expr {
        var result: std.ArrayListUnmanaged(Expr) = .empty;
        errdefer result.deinit(allocator);
        for (items) |item| try result.append(allocator, try self.parseExpr(item));
        return result.toOwnedSlice(allocator);
    }

    // ---- sizing ---------------------------------------------------------

    fn statementSize(self: *Assembler, stmt: Statement) Error!u16 {
        return switch (stmt.kind) {
            .org => 0,
            .ds => |n| n,
            .db => |items| blk: {
                var total: usize = 0;
                for (items) |item| switch (item) {
                    .byte => total += 1,
                    .string => |s| total += s.len,
                };
                break :blk @intCast(total);
            },
            .dw => |items| @intCast(items.len * 2),
            .instr => |instr| self.instructionSize(instr),
        };
    }

    fn operand(ops: *const [MaxOperands]?[]const u8, i: u8) ?[]const u8 {
        return if (i < ops.len) ops[i] else null;
    }

    // Sizes are fixed by instruction shape, never by the value of a label.
    fn instructionSize(self: *Assembler, instr: Instr) Error!u16 {
        const m = instr.mnemonic;
        const ops = &instr.operands;
        const op0 = operand(ops, 0);
        const op1 = operand(ops, 1);

        const no_operand = [_][]const u8{ "nop", "halt", "stop", "di", "ei", "reti", "rlca", "rrca", "rla", "rra", "daa", "cpl", "scf", "ccf" };
        for (no_operand) |name| {
            if (eqIgnoreCase(m, name)) return 1;
        }

        if (eqIgnoreCase(m, "ld")) return self.ldSize(op0, op1);
        if (eqIgnoreCase(m, "ldh") or eqIgnoreCase(m, "lda")) return 2;
        if (eqIgnoreCase(m, "push") or eqIgnoreCase(m, "pop")) return 1;
        if (eqIgnoreCase(m, "inc") or eqIgnoreCase(m, "dec")) return 1;
        if (eqIgnoreCase(m, "jr")) return 2;
        if (eqIgnoreCase(m, "jp")) {
            if (op0 != null and isParenthesized(op0.?)) return 1; // JP (HL)
            return 3;
        }
        if (eqIgnoreCase(m, "call")) return 3;
        if (eqIgnoreCase(m, "ret")) return 1;
        if (eqIgnoreCase(m, "rst")) return 1;

        const alu_names = [_][]const u8{ "add", "adc", "sub", "sbc", "and", "xor", "or", "cp" };
        for (alu_names) |name| {
            if (eqIgnoreCase(m, name)) {
                if (op0 == null) return error.MissingOperand;
                if (eqIgnoreCase(m, "add")) {
                    // ADD HL,r16 (1) / ADD SP,e8 (2) / ADD A,r8 (1) / ADD A,d8 (2)
                    if (op1 != null) {
                        if (eqIgnoreCase(op0.?, "hl")) return 1;
                        if (eqIgnoreCase(op0.?, "sp")) return 2;
                        return if (reg8Index(op1.?) != null) @as(u16, 1) else 2;
                    }
                    return if (reg8Index(op0.?) != null) @as(u16, 1) else 2;
                }
                // ADC/SUB/SBC/AND/XOR/OR/CP
                if (op1 != null) return if (reg8Index(op1.?) != null) @as(u16, 1) else 2;
                return if (reg8Index(op0.?) != null) @as(u16, 1) else 2;
            }
        }

        const cb_names = [_][]const u8{ "rlc", "rrc", "rl", "rr", "sla", "sra", "swap", "srl", "bit", "res", "set" };
        for (cb_names) |name| {
            if (eqIgnoreCase(m, name)) return 2;
        }

        return error.InvalidMnemonic;
    }

    fn ldSize(self: *Assembler, op0: ?[]const u8, op1: ?[]const u8) Error!u16 {
        _ = self;
        if (op0 == null or op1 == null) return error.MissingOperand;

        // LD r16,d16
        if (reg16Index(op0.?) != null) return 3;

        // LD SP,HL / LD HL,SP+e8
        if (reg16Index(op1.?) != null) {
            if (eqIgnoreCase(op0.?, "hl") and eqIgnoreCase(op1.?, "sp")) return 2;
            return 1;
        }

        // LD (r16mem),A / LD A,(r16mem) / LD (HL+),A etc: 1 byte each.
        if (isParenthesized(op0.?) or isParenthesized(op1.?)) {
            const inner = if (isParenthesized(op0.?)) parenInner(op0.?) else parenInner(op1.?);
            if (eqIgnoreCase(inner, "c")) return 1;
            if (eqIgnoreCase(inner, "bc") or eqIgnoreCase(inner, "de")) return 1;
            if (eqIgnoreCase(inner, "hl") or eqIgnoreCase(inner, "hl+") or eqIgnoreCase(inner, "hl-")) {
                // LD (HL),A / LD A,(HL) / LDI/LDD are one byte; LD (HL),d8 is two.
                if (isParenthesized(op0.?) and reg8Index(op1.?) == null) return 2;
                return 1;
            }
            return 3; // LD A,(a16) / LD (a16),A / LD (a16),SP
        }

        // LD r8,r8 / LD r8,d8
        if (reg8Index(op0.?) != null and reg8Index(op1.?) != null) return 1;
        return 2;
    }

    // ---- pass 1 ---------------------------------------------------------

    fn pass1(self: *Assembler) Error!void {
        var address: u16 = 0;
        for (self.statements.items) |*stmt| {
            stmt.address = address;
            switch (stmt.kind) {
                .org => |target| {
                    if (stmt.label) |label| {
                        if (self.symbols.contains(label)) return error.DuplicateLabel;
                        try self.symbols.put(self.allocator, label, target);
                    }
                    address = target;
                },
                else => {
                    if (stmt.label) |label| {
                        if (self.symbols.contains(label)) return error.DuplicateLabel;
                        try self.symbols.put(self.allocator, label, address);
                    }
                    address +%= try self.statementSize(stmt.*);
                },
            }
        }
    }

    fn emit(self: *Assembler, out: *std.ArrayListUnmanaged(u8), stmt: Statement) Error!void {
        switch (stmt.kind) {
            .org => |target| {
                // Pad the image with zeros up to the target address.
                var cursor = out.items.len;
                while (cursor < target) : (cursor += 1) try out.append(self.allocator, 0);
            },
            .ds => |n| {
                var i: u16 = 0;
                while (i < n) : (i += 1) try out.append(self.allocator, 0);
            },
            .db => |items| for (items) |item| switch (item) {
                .byte => |expr| try out.append(self.allocator, try self.exprByte(expr)),
                .string => |s| for (s) |c| try out.append(self.allocator, c),
            },
            .dw => |items| for (items) |expr| {
                const v = try self.exprValue(expr);
                try out.append(self.allocator, @truncate(v));
                try out.append(self.allocator, @truncate(v >> 8));
            },
            .instr => |instr| try self.emitInstruction(out, instr, stmt.address),
        }
    }

    fn byte(self: *Assembler, out: *std.ArrayListUnmanaged(u8), value: u8) Error!void {
        try out.append(self.allocator, value);
    }

    fn emitByte(self: *Assembler, out: *std.ArrayListUnmanaged(u8), token: []const u8) Error!void {
        try out.append(self.allocator, try self.exprByte(try self.parseExpr(token)));
    }

    fn emitWord(self: *Assembler, out: *std.ArrayListUnmanaged(u8), token: []const u8) Error!void {
        const v = try self.exprValue(try self.parseExpr(token));
        try out.append(self.allocator, @truncate(v));
        try out.append(self.allocator, @truncate(v >> 8));
    }

    fn emitRel8(self: *Assembler, out: *std.ArrayListUnmanaged(u8), token: []const u8, address: u16, instr_len: u16) Error!void {
        const target = try self.exprValue(try self.parseExpr(token));
        const offset = @as(i32, target) - @as(i32, address +% instr_len);
        if (offset < -128 or offset > 127) return error.Range;
        try out.append(self.allocator, @bitCast(@as(i8, @intCast(offset))));
    }

    // Emits a signed 8-bit immediate. Used by ADD SP,e8 and LD HL,SP+e8,
    // where the operand is an offset from SP, not a branch target.
    fn emitSigned8(self: *Assembler, out: *std.ArrayListUnmanaged(u8), token: []const u8) Error!void {
        const value = try self.exprValue(try self.parseExpr(token));
        if (value > 0x7f and value < 0x100) {
            // Accept an unsigned encoding of a negative offset.
            try out.append(self.allocator, @truncate(value));
            return;
        }
        if (value > 0xff) return error.Range;
        try out.append(self.allocator, @truncate(value));
    }

    fn emitInstruction(self: *Assembler, out: *std.ArrayListUnmanaged(u8), instr: Instr, address: u16) Error!void {
        const m = instr.mnemonic;
        const ops = &instr.operands;
        const op0 = operand(ops, 0);
        const op1 = operand(ops, 1);

        const single_table = [_]struct { name: []const u8, op: u8 }{
            .{ .name = "nop", .op = 0x00 },  .{ .name = "halt", .op = 0x76 },
            .{ .name = "stop", .op = 0x10 }, .{ .name = "di", .op = 0xf3 },
            .{ .name = "ei", .op = 0xfb },   .{ .name = "reti", .op = 0xd9 },
            .{ .name = "rlca", .op = 0x07 }, .{ .name = "rrca", .op = 0x0f },
            .{ .name = "rla", .op = 0x17 },  .{ .name = "rra", .op = 0x1f },
            .{ .name = "daa", .op = 0x27 },  .{ .name = "cpl", .op = 0x2f },
            .{ .name = "scf", .op = 0x37 },  .{ .name = "ccf", .op = 0x3f },
        };
        for (single_table) |entry| {
            if (eqIgnoreCase(m, entry.name)) {
                try self.byte(out, entry.op);
                return;
            }
        }

        if (eqIgnoreCase(m, "ld")) return self.emitLd(out, op0, op1);
        if (eqIgnoreCase(m, "ldh") or eqIgnoreCase(m, "lda")) return self.emitLdh(out, op0, op1);

        if (eqIgnoreCase(m, "push")) {
            try self.byte(out, @intCast(0xc5 + @as(u8, stack16Index(op0.?).?) * 16));
            return;
        }
        if (eqIgnoreCase(m, "pop")) {
            try self.byte(out, @intCast(0xc1 + @as(u8, stack16Index(op0.?).?) * 16));
            return;
        }

        if (eqIgnoreCase(m, "inc")) {
            if (reg16Index(op0.?)) |p| {
                try self.byte(out, @intCast(0x03 + @as(u8, p) * 16));
            } else {
                try self.byte(out, @intCast(0x04 + reg8Index(op0.?).? * 8));
            }
            return;
        }
        if (eqIgnoreCase(m, "dec")) {
            if (reg16Index(op0.?)) |p| {
                try self.byte(out, @intCast(0x0b + @as(u8, p) * 16));
            } else {
                try self.byte(out, @intCast(0x05 + reg8Index(op0.?).? * 8));
            }
            return;
        }

        if (eqIgnoreCase(m, "jr")) {
            const cc = if (op0 != null and condIndex(op0.?) != null) condIndex(op0.?).? else null;
            const target = if (cc != null) op1.? else op0.?;
            try self.byte(out, if (cc) |c| @as(u8, 0x20) + @as(u8, c) * 8 else 0x18);
            return self.emitRel8(out, target, address, 2);
        }

        if (eqIgnoreCase(m, "jp")) {
            if (op0 != null and isParenthesized(op0.?)) {
                try self.byte(out, 0xe9);
                return;
            }
            const cc = if (op0 != null and condIndex(op0.?) != null) condIndex(op0.?).? else null;
            const target = if (cc != null) op1.? else op0.?;
            try self.byte(out, if (cc) |c| @as(u8, 0xc2) + @as(u8, c) * 8 else 0xc3);
            return self.emitWord(out, target);
        }

        if (eqIgnoreCase(m, "call")) {
            const cc = if (op0 != null and condIndex(op0.?) != null) condIndex(op0.?).? else null;
            const target = if (cc != null) op1.? else op0.?;
            try self.byte(out, if (cc) |c| @as(u8, 0xc4) + @as(u8, c) * 8 else 0xcd);
            return self.emitWord(out, target);
        }

        if (eqIgnoreCase(m, "ret")) {
            const cc = if (op0 != null and condIndex(op0.?) != null) condIndex(op0.?).? else null;
            try self.byte(out, if (cc) |c| @as(u8, 0xc0) + @as(u8, c) * 8 else 0xc9);
            return;
        }

        if (eqIgnoreCase(m, "rst")) {
            const value = try self.exprValue(try self.parseExpr(op0.?));
            if (value > 0x38 or value & 7 != 0) return error.Range;
            try self.byte(out, @intCast(0xc7 + value));
            return;
        }

        const alu_names = [_][]const u8{ "add", "adc", "sub", "sbc", "and", "xor", "or", "cp" };
        const alu_imm = [_]u8{ 0xc6, 0xce, 0xd6, 0xde, 0xe6, 0xee, 0xf6, 0xfe };
        for (alu_names, 0..) |name, i| {
            if (eqIgnoreCase(m, name)) {
                if (eqIgnoreCase(m, "add")) {
                    if (op1 != null and eqIgnoreCase(op0.?, "hl")) {
                        try self.byte(out, @intCast(0x09 + @as(u8, reg16Index(op1.?).?) * 16));
                        return;
                    }
                    if (op1 != null and eqIgnoreCase(op0.?, "sp")) {
                        try self.byte(out, 0xe8);
                        return self.emitSigned8(out, op1.?);
                    }
                    if (op1 != null and reg8Index(op1.?) != null) {
                        try self.byte(out, @intCast(0x80 + i * 8 + reg8Index(op1.?).?));
                        return;
                    }
                    if (op1 != null) {
                        try self.byte(out, alu_imm[i]);
                        return self.emitByte(out, op1.?);
                    }
                    if (reg8Index(op0.?) != null) {
                        try self.byte(out, @intCast(0x80 + i * 8 + reg8Index(op0.?).?));
                        return;
                    }
                    try self.byte(out, alu_imm[i]);
                    return self.emitByte(out, op0.?);
                }
                // ADC/SUB/SBC/AND/XOR/OR/CP
                if (op1 != null and reg8Index(op1.?) != null) {
                    try self.byte(out, @intCast(0x80 + i * 8 + reg8Index(op1.?).?));
                    return;
                }
                if (op1 != null) {
                    try self.byte(out, alu_imm[i]);
                    return self.emitByte(out, op1.?);
                }
                if (reg8Index(op0.?) != null) {
                    try self.byte(out, @intCast(0x80 + i * 8 + reg8Index(op0.?).?));
                    return;
                }
                try self.byte(out, alu_imm[i]);
                return self.emitByte(out, op0.?);
            }
        }

        const cb_shift = [_][]const u8{ "rlc", "rrc", "rl", "rr", "sla", "sra", "swap", "srl" };
        for (cb_shift, 0..) |name, i| {
            if (eqIgnoreCase(m, name)) {
                try self.byte(out, 0xcb);
                try self.byte(out, @intCast(i * 8 + reg8Index(op0.?).?));
                return;
            }
        }
        const cb_bit = [_][]const u8{ "bit", "res", "set" };
        for (cb_bit, 0..) |name, i| {
            if (eqIgnoreCase(m, name)) {
                const bit = try self.exprByte(try self.parseExpr(op0.?));
                if (bit > 7) return error.Range;
                try self.byte(out, 0xcb);
                try self.byte(out, @intCast(0x40 + i * 0x40 + bit * 8 + reg8Index(op1.?).?));
                return;
            }
        }

        return error.InvalidMnemonic;
    }

    fn emitLd(self: *Assembler, out: *std.ArrayListUnmanaged(u8), op0: ?[]const u8, op1: ?[]const u8) Error!void {
        const a = op0.?;
        const b = op1.?;

        // LD SP,HL
        if (eqIgnoreCase(a, "sp") and eqIgnoreCase(b, "hl")) {
            try self.byte(out, 0xf9);
            return;
        }
        // LD HL,SP+e8 (offset given as sp+/-N)
        if (eqIgnoreCase(a, "hl")) {
            if (std.mem.startsWith(u8, b, "SP+") or std.mem.startsWith(u8, b, "sp+")) {
                try self.byte(out, 0xf8);
                return self.emitSigned8(out, b[3..]);
            }
            if (std.mem.startsWith(u8, b, "SP-") or std.mem.startsWith(u8, b, "sp-")) {
                const value = try self.exprValue(try self.parseExpr(b[3..]));
                const negated = @as(i64, -@as(i64, value));
                if (negated < -128 or negated > 127) return error.Range;
                try self.byte(out, 0xf8);
                try self.byte(out, @bitCast(@as(i8, @intCast(negated))));
                return;
            }
        }
        // LD r16,d16 (BC/DE/HL/SP)
        if (reg16Index(a) != null) {
            try self.byte(out, @intCast(0x01 + @as(u8, reg16Index(a).?) * 16));
            return self.emitWord(out, b);
        }

        // LD (r16mem),A and LD (HL+),A / (HL-),A and LD (a16),A and LD (a16),SP
        if (isParenthesized(a)) {
            const inner = parenInner(a);
            if (eqIgnoreCase(inner, "c")) {
                try self.byte(out, 0xe2);
                return;
            }
            if (eqIgnoreCase(inner, "hl")) {
                // LD (HL),r8 or LD (HL),d8
                if (reg8Index(b)) |s| {
                    try self.byte(out, @intCast(0x40 + 6 * 8 + s));
                } else {
                    try self.byte(out, 0x36);
                    return self.emitByte(out, b);
                }
                return;
            }
            if (eqIgnoreCase(inner, "hl+")) {
                try self.byte(out, 0x22);
                return;
            }
            if (eqIgnoreCase(inner, "hl-")) {
                try self.byte(out, 0x32);
                return;
            }
            if (reg16Index(inner)) |p| {
                try self.byte(out, @intCast(0x02 + @as(u8, p) * 16));
                return;
            }
            if (eqIgnoreCase(b, "sp")) {
                try self.byte(out, 0x08);
                return self.emitWord(out, inner);
            }
            try self.byte(out, 0xea);
            return self.emitWord(out, inner);
        }

        // LD A,(r16mem) and LD A,(HL+)/(HL-) and LD A,(a16)
        if (isParenthesized(b)) {
            const inner = parenInner(b);
            if (eqIgnoreCase(inner, "c")) {
                try self.byte(out, 0xf2);
                return;
            }
            if (eqIgnoreCase(inner, "hl")) {
                try self.byte(out, 0x7e);
                return;
            }
            if (eqIgnoreCase(inner, "hl+")) {
                try self.byte(out, 0x2a);
                return;
            }
            if (eqIgnoreCase(inner, "hl-")) {
                try self.byte(out, 0x3a);
                return;
            }
            if (reg16Index(inner)) |p| {
                try self.byte(out, @intCast(0x0a + @as(u8, p) * 16));
                return;
            }
            try self.byte(out, 0xfa);
            return self.emitWord(out, inner);
        }

        // LD r8,r8 / LD r8,d8
        const d = reg8Index(a).?;
        if (reg8Index(b)) |s| {
            try self.byte(out, @intCast(0x40 + d * 8 + s));
            return;
        }
        try self.byte(out, @intCast(0x06 + d * 8));
        return self.emitByte(out, b);
    }

    fn emitLdh(self: *Assembler, out: *std.ArrayListUnmanaged(u8), op0: ?[]const u8, op1: ?[]const u8) Error!void {
        const a = op0.?;
        const b = op1.?;
        // LDH A,(n)
        if (eqIgnoreCase(a, "a") and isParenthesized(b)) {
            try self.byte(out, 0xf0);
            return self.emitByte(out, parenInner(b));
        }
        // LDH (n),A
        if (isParenthesized(a) and eqIgnoreCase(b, "a")) {
            try self.byte(out, 0xe0);
            return self.emitByte(out, parenInner(a));
        }
        return error.InvalidOperand;
    }
};

fn splitLines(allocator: std.mem.Allocator, source: []const u8) !*std.ArrayListUnmanaged([]const u8) {
    const lines = try allocator.create(std.ArrayListUnmanaged([]const u8));
    errdefer allocator.destroy(lines);
    lines.* = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    return lines;
}

// Assembles a source file into a complete ROM image.
pub fn assemble(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var assembler = Assembler{ .allocator = allocator };
    defer assembler.deinit();

    const lines = try splitLines(allocator, source);
    defer {
        lines.deinit(allocator);
        allocator.destroy(lines);
    }

    for (lines.items) |line| {
        if (try assembler.parseLine(allocator, line)) |stmt| {
            try assembler.statements.append(allocator, stmt);
        }
    }

    try assembler.pass1();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (assembler.statements.items) |stmt| try assembler.emit(&out, stmt);
    return out.toOwnedSlice(allocator);
}

// ---- file pipeline -------------------------------------------------------

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const buffer = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

fn writeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    _ = allocator;
    const dir = std.Io.Dir.cwd();
    const file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

fn assembleDir(io: std.Io, allocator: std.mem.Allocator, in_dir: []const u8, out_dir: []const u8) !u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, in_dir, .{ .iterate = true });
    defer dir.close(io);
    std.Io.Dir.cwd().createDir(io, out_dir, std.Io.File.Permissions.default_dir) catch {};

    var failures: usize = 0;
    var total: usize = 0;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".asm")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    for (names.items) |name| {
        defer allocator.free(name);
        total += 1;
        const in_path = try std.fs.path.join(allocator, &.{ in_dir, name });
        defer allocator.free(in_path);
        const stem = name[0 .. name.len - 4];
        const out_name = try std.fmt.allocPrint(allocator, "{s}.gb", .{stem});
        defer allocator.free(out_name);
        const out_path = try std.fs.path.join(allocator, &.{ out_dir, out_name });
        defer allocator.free(out_path);

        const source = readFile(io, allocator, in_path) catch |err| {
            std.debug.print("{s}: read error {s}\n", .{ name, @errorName(err) });
            failures += 1;
            continue;
        };
        defer allocator.free(source);

        const rom = assemble(allocator, source) catch |err| {
            std.debug.print("{s}: assembly error {s}\n", .{ name, @errorName(err) });
            failures += 1;
            continue;
        };
        defer allocator.free(rom);

        writeFile(io, allocator, out_path, rom) catch |err| {
            std.debug.print("{s}: write error {s}\n", .{ name, @errorName(err) });
            failures += 1;
            continue;
        };
        std.debug.print("{s}: {d} bytes\n", .{ name, rom.len });
    }

    std.debug.print("\n{d}/{d} sources assembled\n", .{ total - failures, total });
    return if (failures == 0) 0 else 1;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| try args.append(allocator, arg);
    const argv = args.items;

    if (argv.len != 3) {
        std.debug.print(
            \\gbasm - SM83 assembler
            \\Usage:
            \\  {s} <in-dir> <out-dir>
            \\
            \\Assembles every .asm file in <in-dir> into a .gb ROM image in
            \\<out-dir>.
            \\
        , .{if (argv.len != 0) argv[0] else "gbasm"});
        std.process.exit(2);
    }

    const code = assembleDir(io, allocator, argv[1], argv[2]) catch |err| {
        std.debug.print("gbasm: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}

const testing = std.testing;

test "assemble a minimal ROM with org, labels, and branches" {
    const source =
        \\    org $0100
        \\start:
        \\    ld a,$12
        \\    add a,$24
        \\    cp $36
        \\    jr nz,fail
        \\    ld bc,$1234
        \\    push bc
        \\    pop de
        \\    ld a,d
        \\    cp $12
        \\    jr nz,fail
        \\pass:
        \\    halt
        \\    jr pass
        \\fail:
        \\    jr fail
    ;
    const rom = try assemble(testing.allocator, source);
    defer testing.allocator.free(rom);
    try testing.expect(rom.len >= 0x0100 + 20);
    try testing.expectEqual(@as(u8, 0x3e), rom[0x0100]); // LD A,$12
    try testing.expectEqual(@as(u8, 0x12), rom[0x0101]);
    try testing.expectEqual(@as(u8, 0xc6), rom[0x0102]); // ADD A,$24
    try testing.expectEqual(@as(u8, 0x24), rom[0x0103]);
    try testing.expectEqual(@as(u8, 0xfe), rom[0x0104]); // CP $36
    try testing.expectEqual(@as(u8, 0x36), rom[0x0105]);
}

test "assemble loads, stack ops, and relative branches to labels" {
    const source =
        \\    org $0100
        \\    ld sp,$fffe
        \\    ld hl,msg
        \\loop:
        \\    ld a,(hl+)
        \\    or a
        \\    jr z,done
        \\    ld ($ff01),a
        \\    jr loop
        \\done:
        \\    halt
        \\msg:
        \\    db "PASS",$0a
    ;
    const rom = try assemble(testing.allocator, source);
    defer testing.allocator.free(rom);
    try testing.expectEqual(@as(u8, 0x31), rom[0x0100]); // LD SP,d16
    try testing.expectEqual(@as(u8, 0xfe), rom[0x0101]);
    try testing.expectEqual(@as(u8, 0xff), rom[0x0102]);
    try testing.expectEqual(@as(u8, 0x21), rom[0x0103]); // LD HL,d16
    try testing.expectEqual(@as(u8, 0x2a), rom[0x0106]); // LD A,(HL+)
    try testing.expectEqual(@as(u8, 0xb7), rom[0x0107]); // OR A
    try testing.expectEqual(@as(u8, 0x28), rom[0x0108]); // JR Z,e8
    try testing.expectEqual(@as(u8, 0xea), rom[0x010a]); // LD (a16),A
    try testing.expectEqual(@as(u8, 'P'), rom[0x0110]);
    try testing.expectEqual(@as(u8, 'A'), rom[0x0111]);
    try testing.expectEqual(@as(u8, 'S'), rom[0x0112]);
    try testing.expectEqual(@as(u8, 'S'), rom[0x0113]);
    try testing.expectEqual(@as(u8, 0x0a), rom[0x0114]);
}

test "assemble a full instruction set sample" {
    const source =
        \\    org $0100
        \\    nop
        \\    ld a,b
        \\    ld b,c
        \\    inc a
        \\    dec hl
        \\    add hl,bc
        \\    add a,$01
        \\    adc a,c
        \\    sub d
        \\    sbc a,$10
        \\    and e
        \\    xor a
        \\    or l
        \\    cp $80
        \\    rlca
        \\    rra
        \\    daa
        \\    cpl
        \\    scf
        \\    ccf
        \\    push af
        \\    pop bc
        \\    jp $0200
        \\    jp nz,$0300
        \\    call $0400
        \\    ret
        \\    ret z
        \\    reti
        \\    rst $38
        \\    di
        \\    ei
        \\    halt
        \\    rlc b
        \\    bit 3,(hl)
        \\    set 7,a
        \\    res 0,e
    ;
    const rom = try assemble(testing.allocator, source);
    defer testing.allocator.free(rom);
    const cases = [_]struct { addr: usize, byte: u8 }{
        .{ .addr = 0x0100, .byte = 0x00 }, .{ .addr = 0x0101, .byte = 0x78 },
        .{ .addr = 0x0102, .byte = 0x41 }, .{ .addr = 0x0103, .byte = 0x3c },
        .{ .addr = 0x0104, .byte = 0x2b }, .{ .addr = 0x0105, .byte = 0x09 },
        .{ .addr = 0x0106, .byte = 0xc6 }, .{ .addr = 0x0108, .byte = 0x89 },
        .{ .addr = 0x0109, .byte = 0x92 }, .{ .addr = 0x010a, .byte = 0xde },
        .{ .addr = 0x010c, .byte = 0xa3 }, .{ .addr = 0x010d, .byte = 0xaf },
        .{ .addr = 0x010e, .byte = 0xb5 }, .{ .addr = 0x010f, .byte = 0xfe },
        .{ .addr = 0x0111, .byte = 0x07 }, .{ .addr = 0x0112, .byte = 0x1f },
        .{ .addr = 0x0113, .byte = 0x27 }, .{ .addr = 0x0114, .byte = 0x2f },
        .{ .addr = 0x0115, .byte = 0x37 }, .{ .addr = 0x0116, .byte = 0x3f },
        .{ .addr = 0x0117, .byte = 0xf5 }, .{ .addr = 0x0118, .byte = 0xc1 },
        .{ .addr = 0x0119, .byte = 0xc3 }, .{ .addr = 0x011c, .byte = 0xc2 },
        .{ .addr = 0x011f, .byte = 0xcd }, .{ .addr = 0x0122, .byte = 0xc9 },
        .{ .addr = 0x0123, .byte = 0xc8 }, .{ .addr = 0x0124, .byte = 0xd9 },
        .{ .addr = 0x0125, .byte = 0xff }, .{ .addr = 0x0126, .byte = 0xf3 },
        .{ .addr = 0x0127, .byte = 0xfb }, .{ .addr = 0x0128, .byte = 0x76 },
        .{ .addr = 0x0129, .byte = 0xcb }, .{ .addr = 0x012a, .byte = 0x00 },
        .{ .addr = 0x012b, .byte = 0xcb }, .{ .addr = 0x012c, .byte = 0x5e },
        .{ .addr = 0x012d, .byte = 0xcb }, .{ .addr = 0x012e, .byte = 0xff },
        .{ .addr = 0x012f, .byte = 0xcb }, .{ .addr = 0x0130, .byte = 0x83 },
    };
    for (cases) |case| try testing.expectEqual(case.byte, rom[case.addr]);
}

test "rejects an undefined label" {
    const source =
        \\    org $0100
        \\    jp nowhere
    ;
    const rom = assemble(testing.allocator, source);
    try testing.expectError(error.UndefinedLabel, rom);
}
