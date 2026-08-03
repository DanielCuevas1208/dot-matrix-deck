// gbasm - a two-pass SM83 assembler for the Dot Matrix Deck test ROMs.
//
// Usage:
//   gbasm <asm-dir> <rom-dir>
//
// Each file ending in .asm in <asm-dir> is assembled into a 32 KiB ROM
// named <rom-dir>/<basename>.gb. The emulator starts executing at
// $0100, so every source must begin with `org $0100`.
//
// The assembler supports labels, EQU, DB, DW, DS, and the full SM83
// instruction set. Expressions accept $hex, 0xhex, decimal, %binary,
// labels, and `+` / `-` with parentheses.

const std = @import("std");

const rom_size = 0x8000;
const entry_point = 0x0100;

const OperandKind = enum {
    reg8,
    reg16,
    af,
    hl, // bare HL (ADD HL,r16, LD SP,HL, JP (HL))
    sp,
    ind_bc,
    ind_de,
    ind_hl,
    ind_c,
    ind_a16,
    hl_inc,
    hl_dec,
    imm8,
    imm16,
    cond,
    rst,
    sp_plus, // SP+e form for ADD SP,e / LD HL,SP+e
};

const Operand = struct {
    kind: OperandKind,
    text: []const u8,
    inner: []const u8 = "", // body of an indirect operand, e.g. "$ff44"

    fn isNone(op: Operand) bool {
        return op.text.len == 0;
    }

    fn match(op: Operand, comptime name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(op.text, name);
    }
};

const Statement = struct {
    line_no: usize,
    label: ?[]const u8 = null,
    op: []const u8 = "",
    owns_op: bool = false,
    operands: [3]Operand = .{ .{ .kind = .imm8, .text = "" }, .{ .kind = .imm8, .text = "" }, .{ .kind = .imm8, .text = "" } },
    operand_count: usize = 0,

    fn operand(self: *const Statement, index: usize) Operand {
        if (index < self.operand_count) return self.operands[index];
        return .{ .kind = .imm8, .text = "" };
    }
};

const LabelMap = std.StringHashMap(u32);

const ExprError = error{ InvalidExpression, UnknownLabel };

const Assembler = struct {
    allocator: std.mem.Allocator,
    rom: [rom_size]u8 = [_]u8{0} ** rom_size,
    labels: LabelMap,
    cursor: u32 = 0,
    failure: ?Failure = null,

    const Failure = struct {
        message: []const u8,
        line_no: usize,
    };

    fn init(allocator: std.mem.Allocator) Assembler {
        return .{ .allocator = allocator, .labels = LabelMap.init(allocator) };
    }

    pub fn deinit(self: *Assembler) void {
        var it = self.labels.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.labels.deinit();
    }

    fn fail(self: *Assembler, message: []const u8, line_no: usize) void {
        if (self.failure == null) {
            self.failure = .{ .message = message, .line_no = line_no };
        }
    }

    fn registerLabel(self: *Assembler, name: []const u8, value: u32, line_no: usize) void {
        const stored = self.allocator.dupe(u8, name) catch return;
        if (self.labels.fetchPut(stored, value) catch return) |_| {
            self.fail("duplicate label", line_no);
            self.allocator.free(stored);
        }
    }
};

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '?' or ch == '@';
}

fn splitComment(line: []const u8) []const u8 {
    const index = std.mem.indexOfScalar(u8, line, ';') orelse return line;
    return line[0..index];
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn parseNumber(token: []const u8) ?u32 {
    if (token.len == 0) return null;
    if (token[0] == '$') return std.fmt.parseInt(u32, token[1..], 16) catch null;
    if (std.mem.startsWith(u8, token, "0x")) return std.fmt.parseInt(u32, token[2..], 16) catch null;
    if (token[0] == '%') return std.fmt.parseInt(u32, token[1..], 2) catch null;
    if (std.mem.startsWith(u8, token, "0b")) return std.fmt.parseInt(u32, token[2..], 2) catch null;
    return std.fmt.parseInt(u32, token, 10) catch null;
}

fn parseTerm(text: []const u8, pos: *usize, labels: *const LabelMap) ExprError!i32 {
    const token = std.mem.trimStart(u8, text[pos.*..], " \t");
    pos.* += text.len - pos.* - token.len;
    const rest = text[pos.*..];
    if (rest.len == 0) return error.InvalidExpression;

    if (rest[0] == '+' or rest[0] == '-') {
        const sign: i32 = if (rest[0] == '-') -1 else 1;
        pos.* += 1;
        return sign * try parseTerm(text, pos, labels);
    }

    if (rest[0] == '(') {
        pos.* += 1;
        const value = try parseSum(text, pos, labels);
        const after = std.mem.trimStart(u8, text[pos.*..], " \t");
        if (after.len == 0 or after[0] != ')') return error.InvalidExpression;
        pos.* += after.len - (after.len - 1);
        return value;
    }

    if (rest[0] == '$' or rest[0] == '%' or std.ascii.isDigit(rest[0])) {
        var end = pos.*;
        while (end < text.len and (isIdentChar(text[end]) or text[end] == '$')) : (end += 1) {}
        const token_text = text[pos.*..end];
        pos.* = end;
        const value = parseNumber(token_text) orelse return error.InvalidExpression;
        return @intCast(value);
    }

    var end = pos.*;
    while (end < text.len and isIdentChar(text[end])) : (end += 1) {}
    if (end == pos.*) return error.InvalidExpression;
    const token_text = text[pos.*..end];
    pos.* = end;

    const value: u32 = labels.get(token_text) orelse return error.UnknownLabel;
    return @intCast(value);
}

fn parseSum(text: []const u8, pos: *usize, labels: *const LabelMap) ExprError!i32 {
    var value = try parseTerm(text, pos, labels);
    while (pos.* < text.len) {
        const rest = text[pos.*..];
        if (rest[0] == '+') {
            pos.* += 1;
            value += try parseTerm(text, pos, labels);
        } else if (rest[0] == '-') {
            pos.* += 1;
            value -= try parseTerm(text, pos, labels);
        } else {
            break;
        }
    }
    return value;
}

fn evalExpression(text: []const u8, labels: *const LabelMap) !i32 {
    var pos: usize = 0;
    const value = try parseSum(text, &pos, labels);
    const rest = std.mem.trimStart(u8, text[pos..], " \t");
    if (rest.len != 0) return error.InvalidExpression;
    return value;
}

fn operandValue(op: Operand, labels: *const LabelMap, assembler: *Assembler, line_no: usize) u32 {
    const expr = if (op.inner.len != 0) op.inner else op.text;
    const value = evalExpression(expr, labels) catch {
        assembler.fail("invalid operand expression", line_no);
        return 0;
    };
    if (value < 0 or value > 0xffff) {
        assembler.fail("operand value out of range", line_no);
        return 0;
    }
    return @intCast(value);
}

fn signedByteValue(text: []const u8, labels: *const LabelMap, assembler: *Assembler, line_no: usize) u8 {
    const value = evalExpression(text, labels) catch {
        assembler.fail("invalid signed offset", line_no);
        return 0;
    };
    if (value < -128 or value > 127) {
        assembler.fail("signed offset out of range", line_no);
        return 0;
    }
    return @bitCast(@as(i8, @intCast(value)));
}

fn spOffset(op: Operand, labels: *const LabelMap, assembler: *Assembler, line_no: usize) u8 {
    if (op.text.len < 3) {
        assembler.fail("SP offset must be written as SP+e", line_no);
        return 0;
    }
    const value = evalExpression(op.text[2..], labels) catch {
        assembler.fail("invalid SP offset", line_no);
        return 0;
    };
    if (value < -128 or value > 127) {
        assembler.fail("SP offset out of range", line_no);
        return 0;
    }
    return @bitCast(@as(i8, @intCast(value)));
}

fn splitOperands(statement: []const u8, out: *[3][]const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= statement.len) : (index += 1) {
        const at_end = index == statement.len;
        const ch = if (at_end) ',' else statement[index];
        if (ch == ',' or at_end) {
            if (count < out.len) {
                const part = std.mem.trim(u8, statement[start..index], " \t");
                if (part.len != 0) {
                    out[count] = part;
                    count += 1;
                }
            }
            start = index + 1;
        }
    }
    return count;
}

fn classifyOperand(text: []const u8) Operand {
    const lowered = text;
    if (text.len == 0) return .{ .kind = .imm8, .text = text };

    if (std.mem.startsWith(u8, lowered, "sp+") or std.mem.startsWith(u8, lowered, "sp-")) {
        return .{ .kind = .sp_plus, .text = text };
    }

    if (text[0] == '(') {
        const inner_close = std.mem.indexOfScalar(u8, text, ')') orelse return .{ .kind = .imm8, .text = text };
        const body = std.mem.trim(u8, text[1..inner_close], " \t");
        if (body.len == 0) return .{ .kind = .imm8, .text = text };
        if (body.len == 1 and (body[0] == 'c' or body[0] == 'C')) return .{ .kind = .ind_c, .text = text };
        if (std.ascii.eqlIgnoreCase(body, "bc")) return .{ .kind = .ind_bc, .text = text };
        if (std.ascii.eqlIgnoreCase(body, "de")) return .{ .kind = .ind_de, .text = text };
        if (std.ascii.eqlIgnoreCase(body, "hl")) return .{ .kind = .ind_hl, .text = text };
        if (std.ascii.eqlIgnoreCase(body, "hl+") or std.ascii.eqlIgnoreCase(body, "hli")) return .{ .kind = .hl_inc, .text = text };
        if (std.ascii.eqlIgnoreCase(body, "hl-") or std.ascii.eqlIgnoreCase(body, "hld")) return .{ .kind = .hl_dec, .text = text };
        return .{ .kind = .ind_a16, .text = text, .inner = body };
    }

    if (std.ascii.eqlIgnoreCase(lowered, "a")) return .{ .kind = .reg8, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "b")) return .{ .kind = .reg8, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "c")) return .{ .kind = .reg8, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "d")) return .{ .kind = .reg8, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "e")) return .{ .kind = .reg8, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "h")) return .{ .kind = .reg8, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "l")) return .{ .kind = .reg8, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "bc")) return .{ .kind = .reg16, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "de")) return .{ .kind = .reg16, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "hl")) return .{ .kind = .hl, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "sp")) return .{ .kind = .sp, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "af")) return .{ .kind = .af, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "nz")) return .{ .kind = .cond, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "z")) return .{ .kind = .cond, .text = text };
    if (std.ascii.eqlIgnoreCase(lowered, "nc")) return .{ .kind = .cond, .text = text };
    return .{ .kind = .imm8, .text = text };
}

fn parseStatement(line: []const u8, line_no: usize, allocator: std.mem.Allocator) !Statement {
    var statement = Statement{ .line_no = line_no };
    var text = trimLine(splitComment(line));

    if (text.len == 0) return statement;

    const colon = std.mem.indexOfScalar(u8, text, ':');
    if (colon) |index| {
        const before = std.mem.trim(u8, text[0..index], " \t");
        if (before.len != 0 and (isIdentChar(before[0]) or before[0] == '.')) {
            statement.label = try allocator.dupe(u8, before);
            text = trimLine(text[index + 1 ..]);
        }
    }

    if (text.len == 0) return statement;

    var end: usize = 0;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
    statement.op = try allocator.dupe(u8, text[0..end]);
    statement.owns_op = true;
    const rest = trimLine(text[end..]);

    if (rest.len != 0) {
        if (isEquForm(statement.op, rest)) {
            const after_equ = std.mem.trimStart(u8, rest["equ".len..], " \t");
            statement.label = statement.op;
            statement.op = try allocator.dupe(u8, "equ");
            const duped = try allocator.dupe(u8, after_equ);
            statement.operands[0] = classifyOperand(duped);
            statement.operand_count = 1;
            return statement;
        }

        var parts: [3][]const u8 = undefined;
        statement.operand_count = splitOperands(rest, &parts);
        var operand_index: usize = 0;
        while (operand_index < statement.operand_count) : (operand_index += 1) {
            const duped = try allocator.dupe(u8, parts[operand_index]);
            statement.operands[operand_index] = classifyOperand(duped);
        }
    }
    return statement;
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    return isIdentChar(text[0]) and !std.ascii.isDigit(text[0]);
}

fn isEquForm(op: []const u8, rest: []const u8) bool {
    if (op.len == 0 or !isIdentifier(op)) return false;
    if (rest.len < "equ".len) return false;
    const prefix = rest[0.."equ".len];
    if (!std.ascii.eqlIgnoreCase(prefix, "equ")) return false;
    if (rest.len > "equ".len and !std.ascii.isWhitespace(rest["equ".len])) return false;
    return true;
}

fn r8code(op: Operand) ?u8 {
    return switch (op.kind) {
        .reg8 => switch (op.text[0]) {
            'b', 'B' => 0,
            'c', 'C' => 1,
            'd', 'D' => 2,
            'e', 'E' => 3,
            'h', 'H' => 4,
            'l', 'L' => 5,
            'a', 'A' => 7,
            else => null,
        },
        .ind_hl => 6,
        else => null,
    };
}

fn r16code(op: Operand) ?u8 {
    return switch (op.kind) {
        .reg16 => switch (op.text[0]) {
            'b', 'B' => 0,
            'd', 'D' => 1,
            'h', 'H' => 2,
            's', 'S' => 3,
            else => null,
        },
        .hl => 2,
        .sp => 3,
        else => null,
    };
}

fn isReg16Dest(op: Operand) bool {
    return switch (op.kind) {
        .reg16, .hl, .sp => true,
        else => false,
    };
}

fn condCode(op: Operand) ?u8 {
    if (op.kind != .cond) return null;
    if (op.match("nz")) return 0;
    if (op.match("z")) return 1;
    if (op.match("nc")) return 2;
    if (op.match("c")) return 3;
    return null;
}

fn emit8(assembler: *Assembler, value: u8, line_no: usize) void {
    if (assembler.failure != null) return;
    if (assembler.cursor >= rom_size) {
        assembler.fail("ROM overflow", line_no);
        return;
    }
    assembler.rom[assembler.cursor] = value;
    assembler.cursor += 1;
}

fn emit16(assembler: *Assembler, value: u16, line_no: usize) void {
    emit8(assembler, @truncate(value), line_no);
    emit8(assembler, @truncate(value >> 8), line_no);
}

fn emitCb(assembler: *Assembler, opcode: u8, r: u8, line_no: usize) void {
    emit8(assembler, 0xcb, line_no);
    emit8(assembler, opcode | r, line_no);
}

fn rstValue(op: Operand, assembler: *Assembler, line_no: usize) u8 {
    const value = operandValue(op, &assembler.labels, assembler, line_no);
    return switch (value) {
        0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38 => @intCast(value),
        else => {
            assembler.fail("RST requires a value of $00, $08, ... $38", line_no);
            return 0;
        },
    };
}

fn assembleInstruction(assembler: *Assembler, statement: *const Statement) void {
    const op = statement.op;
    const line_no = statement.line_no;
    const labels = &assembler.labels;

    if (assembler.failure != null) return;

    if (std.mem.eql(u8, op, "nop")) {
        emit8(assembler, 0x00, line_no);
    } else if (std.mem.eql(u8, op, "halt")) {
        emit8(assembler, 0x76, line_no);
    } else if (std.mem.eql(u8, op, "stop")) {
        emit8(assembler, 0x10, line_no);
        emit8(assembler, 0x00, line_no);
    } else if (std.mem.eql(u8, op, "di")) {
        emit8(assembler, 0xf3, line_no);
    } else if (std.mem.eql(u8, op, "ei")) {
        emit8(assembler, 0xfb, line_no);
    } else if (std.mem.eql(u8, op, "daa")) {
        emit8(assembler, 0x27, line_no);
    } else if (std.mem.eql(u8, op, "cpl")) {
        emit8(assembler, 0x2f, line_no);
    } else if (std.mem.eql(u8, op, "scf")) {
        emit8(assembler, 0x37, line_no);
    } else if (std.mem.eql(u8, op, "ccf")) {
        emit8(assembler, 0x3f, line_no);
    } else if (std.mem.eql(u8, op, "rlca")) {
        emit8(assembler, 0x07, line_no);
    } else if (std.mem.eql(u8, op, "rrca")) {
        emit8(assembler, 0x0f, line_no);
    } else if (std.mem.eql(u8, op, "rla")) {
        emit8(assembler, 0x17, line_no);
    } else if (std.mem.eql(u8, op, "rra")) {
        emit8(assembler, 0x1f, line_no);
    } else if (std.mem.eql(u8, op, "ld")) {
        assembleLd(assembler, statement);
    } else if (std.mem.eql(u8, op, "ldh")) {
        assembleLdh(assembler, statement);
    } else if (std.mem.eql(u8, op, "ldi")) {
        assembleLdi(assembler, statement);
    } else if (std.mem.eql(u8, op, "ldd")) {
        assembleLdd(assembler, statement);
    } else if (std.mem.eql(u8, op, "inc")) {
        const a = statement.operand(0);
        if (r8code(a)) |r| {
            emit8(assembler, if (r == 6) 0x34 else 0x04 | (r << 3), line_no);
        } else if (r16code(a)) |r| {
            emit8(assembler, 0x03 | (r << 4), line_no);
        } else {
            assembler.fail("INC requires a register", line_no);
        }
    } else if (std.mem.eql(u8, op, "dec")) {
        const a = statement.operand(0);
        if (r8code(a)) |r| {
            emit8(assembler, if (r == 6) 0x35 else 0x05 | (r << 3), line_no);
        } else if (r16code(a)) |r| {
            emit8(assembler, 0x0b | (r << 4), line_no);
        } else {
            assembler.fail("DEC requires a register", line_no);
        }
    } else if (std.mem.eql(u8, op, "add")) {
        assembleAdd(assembler, statement);
    } else if (std.mem.eql(u8, op, "adc") or std.mem.eql(u8, op, "sub") or std.mem.eql(u8, op, "sbc") or std.mem.eql(u8, op, "and") or std.mem.eql(u8, op, "xor") or std.mem.eql(u8, op, "or") or std.mem.eql(u8, op, "cp")) {
        const alu_base: u8 = if (std.mem.eql(u8, op, "adc")) 0x88 else if (std.mem.eql(u8, op, "sub")) 0x90 else if (std.mem.eql(u8, op, "sbc")) 0x98 else if (std.mem.eql(u8, op, "and")) 0xa0 else if (std.mem.eql(u8, op, "xor")) 0xa8 else if (std.mem.eql(u8, op, "or")) 0xb0 else 0xb8;
        const a = statement.operand(0);
        const b = statement.operand(1);
        const target = if (a.kind == .reg8 and a.match("a") and !b.isNone()) b else a;
        if (r8code(target)) |r| {
            emit8(assembler, alu_base | r, line_no);
        } else if (target.kind == .imm8) {
            emit8(assembler, alu_base + 0x46, line_no);
            emit8(assembler, @truncate(operandValue(target, labels, assembler, line_no)), line_no);
        } else {
            assembler.fail("invalid ALU operand", line_no);
        }
    } else if (std.mem.eql(u8, op, "jr")) {
        assembleJr(assembler, statement);
    } else if (std.mem.eql(u8, op, "jp")) {
        assembleJp(assembler, statement);
    } else if (std.mem.eql(u8, op, "call")) {
        assembleCall(assembler, statement);
    } else if (std.mem.eql(u8, op, "ret")) {
        const a = statement.operand(0);
        if (a.isNone()) {
            emit8(assembler, 0xc9, line_no);
        } else if (condCode(a)) |cc| {
            emit8(assembler, 0xc0 | (cc << 3), line_no);
        } else {
            assembler.fail("invalid RET operand", line_no);
        }
    } else if (std.mem.eql(u8, op, "reti")) {
        emit8(assembler, 0xd9, line_no);
    } else if (std.mem.eql(u8, op, "push")) {
        const a = statement.operand(0);
        if (a.kind == .af) {
            emit8(assembler, 0xf5, line_no);
        } else if (r16code(a)) |r| {
            emit8(assembler, 0xc5 | (r << 4), line_no);
        } else {
            assembler.fail("PUSH requires BC, DE, HL, or AF", line_no);
        }
    } else if (std.mem.eql(u8, op, "pop")) {
        const a = statement.operand(0);
        if (a.kind == .af) {
            emit8(assembler, 0xf1, line_no);
        } else if (r16code(a)) |r| {
            emit8(assembler, 0xc1 | (r << 4), line_no);
        } else {
            assembler.fail("POP requires BC, DE, HL, or AF", line_no);
        }
    } else if (std.mem.eql(u8, op, "rst")) {
        const value = rstValue(statement.operand(0), assembler, line_no);
        emit8(assembler, 0xc7 | value, line_no);
    } else if (std.mem.eql(u8, op, "rlc") or std.mem.eql(u8, op, "rrc") or std.mem.eql(u8, op, "rl") or std.mem.eql(u8, op, "rr") or std.mem.eql(u8, op, "sla") or std.mem.eql(u8, op, "sra") or std.mem.eql(u8, op, "swap") or std.mem.eql(u8, op, "srl")) {
        const base: u8 = if (std.mem.eql(u8, op, "rrc")) 0x08 else if (std.mem.eql(u8, op, "rl")) 0x10 else if (std.mem.eql(u8, op, "rr")) 0x18 else if (std.mem.eql(u8, op, "sla")) 0x20 else if (std.mem.eql(u8, op, "sra")) 0x28 else if (std.mem.eql(u8, op, "swap")) 0x30 else if (std.mem.eql(u8, op, "srl")) 0x38 else 0x00;
        if (r8code(statement.operand(0))) |r| {
            emitCb(assembler, base, r, line_no);
        } else {
            assembler.fail("invalid shift/rotate operand", line_no);
        }
    } else if (std.mem.eql(u8, op, "bit") or std.mem.eql(u8, op, "res") or std.mem.eql(u8, op, "set")) {
        const cb_base: u8 = if (std.mem.eql(u8, op, "res")) 0x80 else if (std.mem.eql(u8, op, "set")) 0xc0 else 0x40;
        const bit_op = statement.operand(0);
        const reg_op = statement.operand(1);
        if (r8code(reg_op)) |r| {
            const bit_value = operandValue(bit_op, labels, assembler, line_no);
            if (bit_value > 7) {
                assembler.fail("bit number must be 0-7", line_no);
                return;
            }
            emitCb(assembler, cb_base | (@as(u8, @intCast(bit_value)) << 3), r, line_no);
        } else {
            assembler.fail("invalid bit operand", line_no);
        }
    } else {
        assembler.fail("unknown mnemonic", line_no);
    }
}

fn assembleLd(assembler: *Assembler, statement: *const Statement) void {
    const a = statement.operand(0);
    const b = statement.operand(1);
    const line_no = statement.line_no;
    const labels = &assembler.labels;

    if (a.isNone() or b.isNone()) {
        assembler.fail("LD requires two operands", line_no);
        return;
    }

    const dst_r8 = r8code(a);
    const src_r8 = r8code(b);

    if (dst_r8 != null and src_r8 != null) {
        if (dst_r8.? == 6 and src_r8.? == 6) {
            assembler.fail("LD (HL),(HL) is not a valid instruction", line_no);
            return;
        }
        emit8(assembler, 0x40 | (dst_r8.? << 3) | src_r8.?, line_no);
        return;
    }

    if (dst_r8) |r| {
        if (b.kind == .imm8) {
            emit8(assembler, if (r == 6) 0x36 else 0x06 | (r << 3), line_no);
            emit8(assembler, @truncate(operandValue(b, labels, assembler, line_no)), line_no);
            return;
        }
        if (r == 7 and b.kind == .ind_a16) {
            emit8(assembler, 0xfa, line_no);
            emit16(assembler, @truncate(operandValue(b, labels, assembler, line_no)), line_no);
            return;
        }
    }

    if (src_r8) |r| {
        if (r == 7 and a.kind == .ind_a16) {
            emit8(assembler, 0xea, line_no);
            emit16(assembler, @truncate(operandValue(a, labels, assembler, line_no)), line_no);
            return;
        }
    }

    switch (a.kind) {
        .ind_bc => {
            emit8(assembler, 0x02, line_no);
            return;
        },
        .ind_de => {
            emit8(assembler, 0x12, line_no);
            return;
        },
        .hl_inc => {
            emit8(assembler, 0x22, line_no);
            return;
        },
        .hl_dec => {
            emit8(assembler, 0x32, line_no);
            return;
        },
        .ind_c => {
            emit8(assembler, 0xe2, line_no);
            return;
        },
        else => {},
    }

    switch (b.kind) {
        .ind_bc => {
            emit8(assembler, 0x0a, line_no);
            return;
        },
        .ind_de => {
            emit8(assembler, 0x1a, line_no);
            return;
        },
        .hl_inc => {
            emit8(assembler, 0x2a, line_no);
            return;
        },
        .hl_dec => {
            emit8(assembler, 0x3a, line_no);
            return;
        },
        .ind_c => {
            emit8(assembler, 0xf2, line_no);
            return;
        },
        else => {},
    }

    if (a.kind == .hl and b.kind == .sp_plus) {
        emit8(assembler, 0xf8, line_no); // LD HL,SP+e
        emit8(assembler, spOffset(b, labels, assembler, line_no), line_no);
        return;
    }

    if (a.kind == .sp and b.kind == .hl) {
        emit8(assembler, 0xf9, line_no); // LD SP,HL
        return;
    }

    if (isReg16Dest(a) and b.kind == .imm8) {
        const r16 = r16code(a) orelse unreachable;
        emit8(assembler, 0x01 | (r16 << 4), line_no);
        emit16(assembler, @truncate(operandValue(b, labels, assembler, line_no)), line_no);
        return;
    }

    if (a.kind == .ind_a16) {
        emit8(assembler, 0x08, line_no); // LD (a16),SP
        emit16(assembler, @truncate(operandValue(a, labels, assembler, line_no)), line_no);
        return;
    }

    if (dst_r8) |r| {
        _ = r;
    }

    if (b.kind == .ind_a16) {
        emit8(assembler, 0xfa, line_no); // LD A,(a16)
        emit16(assembler, @truncate(operandValue(b, labels, assembler, line_no)), line_no);
        return;
    }

    assembler.fail("invalid LD form", line_no);
}

fn assembleLdh(assembler: *Assembler, statement: *const Statement) void {
    const a = statement.operand(0);
    const b = statement.operand(1);
    const line_no = statement.line_no;
    const labels = &assembler.labels;

    const a_reg = r8code(a);
    const b_reg = r8code(b);

    if (b_reg != null and b_reg.? == 7 and (a.kind == .imm8 or a.kind == .ind_a16)) {
        emit8(assembler, 0xe0, line_no); // LDH (a8),A
        emit8(assembler, @truncate(operandValue(a, labels, assembler, line_no)), line_no);
        return;
    }
    if (a_reg != null and a_reg.? == 7 and (b.kind == .imm8 or b.kind == .ind_a16)) {
        emit8(assembler, 0xf0, line_no); // LDH A,(a8)
        emit8(assembler, @truncate(operandValue(b, labels, assembler, line_no)), line_no);
        return;
    }
    assembler.fail("invalid LDH form", line_no);
}

fn assembleLdi(assembler: *Assembler, statement: *const Statement) void {
    const a = statement.operand(0);
    const b = statement.operand(1);
    const line_no = statement.line_no;
    if (a.kind == .ind_hl and b.match("a")) {
        emit8(assembler, 0x22, line_no); // LDI (HL),A
        return;
    }
    if (a.match("a") and b.kind == .ind_hl) {
        emit8(assembler, 0x2a, line_no); // LDI A,(HL)
        return;
    }
    assembler.fail("invalid LDI form", line_no);
}

fn assembleLdd(assembler: *Assembler, statement: *const Statement) void {
    const a = statement.operand(0);
    const b = statement.operand(1);
    const line_no = statement.line_no;
    if (a.kind == .ind_hl and b.match("a")) {
        emit8(assembler, 0x32, line_no); // LDD (HL),A
        return;
    }
    if (a.match("a") and b.kind == .ind_hl) {
        emit8(assembler, 0x3a, line_no); // LDD A,(HL)
        return;
    }
    assembler.fail("invalid LDD form", line_no);
}

fn assembleAdd(assembler: *Assembler, statement: *const Statement) void {
    const a = statement.operand(0);
    const b = statement.operand(1);
    const line_no = statement.line_no;
    const labels = &assembler.labels;

    if (a.kind == .hl) {
        if (r16code(b)) |r| {
            emit8(assembler, 0x09 | (r << 4), line_no); // ADD HL,r16
            return;
        }
        assembler.fail("ADD HL requires a 16-bit register", line_no);
        return;
    }
    if (a.kind == .sp) {
        if (b.kind == .sp_plus or b.kind == .imm8) {
            emit8(assembler, 0xe8, line_no); // ADD SP,e
            const offset: u8 = if (b.kind == .sp_plus) spOffset(b, labels, assembler, line_no) else signedByteValue(b.text, labels, assembler, line_no);
            emit8(assembler, offset, line_no);
            return;
        }
        assembler.fail("ADD SP requires an immediate offset", line_no);
        return;
    }
    const target = if (a.kind == .reg8 and a.match("a") and !b.isNone()) b else a;
    if (r8code(target)) |r| {
        emit8(assembler, 0x80 | r, line_no);
        return;
    }
    if (target.kind == .imm8) {
        emit8(assembler, 0xc6, line_no);
        emit8(assembler, @truncate(operandValue(target, labels, assembler, line_no)), line_no);
        return;
    }
    assembler.fail("invalid ADD form", line_no);
}

fn assembleJr(assembler: *Assembler, statement: *const Statement) void {
    const a = statement.operand(0);
    const b = statement.operand(1);
    const line_no = statement.line_no;
    const labels = &assembler.labels;

    var cc: ?u8 = null;
    var target = a;
    if (condCode(a)) |code| {
        cc = code;
        target = b;
    }
    if (target.isNone()) {
        assembler.fail("JR requires a target", line_no);
        return;
    }
    if (cc) |code| {
        emit8(assembler, 0x20 | (code << 3), line_no);
    } else {
        emit8(assembler, 0x18, line_no);
    }

    const absolute = operandValue(target, labels, assembler, line_no);
    const from: u32 = assembler.cursor + 1;
    const offset: i32 = @as(i32, @intCast(absolute)) - @as(i32, @intCast(from));
    if (offset < -128 or offset > 127) {
        assembler.fail("JR target out of range", line_no);
        return;
    }
    emit8(assembler, @bitCast(@as(i8, @intCast(offset))), line_no);
}

fn assembleJp(assembler: *Assembler, statement: *const Statement) void {
    const a = statement.operand(0);
    const b = statement.operand(1);
    const line_no = statement.line_no;
    const labels = &assembler.labels;

    if (a.kind == .hl or a.kind == .ind_hl) {
        emit8(assembler, 0xe9, line_no); // JP (HL)
        return;
    }
    if (condCode(a)) |cc| {
        emit8(assembler, 0xc2 | (cc << 3), line_no);
        emit16(assembler, @truncate(operandValue(b, labels, assembler, line_no)), line_no);
        return;
    }
    if (b.isNone()) {
        emit8(assembler, 0xc3, line_no);
        emit16(assembler, @truncate(operandValue(a, labels, assembler, line_no)), line_no);
        return;
    }
    assembler.fail("invalid JP form", line_no);
}

fn assembleCall(assembler: *Assembler, statement: *const Statement) void {
    const a = statement.operand(0);
    const b = statement.operand(1);
    const line_no = statement.line_no;
    const labels = &assembler.labels;

    if (condCode(a)) |cc| {
        emit8(assembler, 0xc4 | (cc << 3), line_no);
        emit16(assembler, @truncate(operandValue(b, labels, assembler, line_no)), line_no);
        return;
    }
    if (b.isNone()) {
        emit8(assembler, 0xcd, line_no);
        emit16(assembler, @truncate(operandValue(a, labels, assembler, line_no)), line_no);
        return;
    }
    assembler.fail("invalid CALL form", line_no);
}

fn assembleData(assembler: *Assembler, statement: *const Statement, op: []const u8) void {
    const line_no = statement.line_no;
    const labels = &assembler.labels;

    if (std.mem.eql(u8, op, "org")) {
        const value = operandValue(statement.operand(0), labels, assembler, line_no);
        if (value > rom_size) {
            assembler.fail("ORG out of range", line_no);
            return;
        }
        assembler.cursor = value;
        return;
    }
    if (std.mem.eql(u8, op, "equ")) {
        _ = operandValue(statement.operand(0), labels, assembler, line_no);
        return;
    }
    if (std.mem.eql(u8, op, "db")) {
        for (statement.operands[0..statement.operand_count]) |operand| {
            const text = operand.text;
            if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                for (text[1 .. text.len - 1]) |ch| emit8(assembler, ch, line_no);
            } else {
                emit8(assembler, @truncate(operandValue(operand, labels, assembler, line_no)), line_no);
            }
        }
        return;
    }
    if (std.mem.eql(u8, op, "dw")) {
        for (statement.operands[0..statement.operand_count]) |operand| {
            emit16(assembler, @truncate(operandValue(operand, labels, assembler, line_no)), line_no);
        }
        return;
    }
    if (std.mem.eql(u8, op, "ds")) {
        const count = operandValue(statement.operand(0), labels, assembler, line_no);
        var index: u32 = 0;
        while (index < count) : (index += 1) emit8(assembler, 0, line_no);
        return;
    }
}

fn instructionSize(statement: *const Statement) u32 {
    const op = statement.op;
    const a = statement.operand(0);
    const b = statement.operand(1);

    if (std.mem.eql(u8, op, "stop")) return 2;
    if (std.mem.eql(u8, op, "ld")) {
        if (b.kind == .imm8 and isReg16Dest(a)) return 3;
        if (b.kind == .imm8) return 2;
        if (b.kind == .sp_plus) return 2;
        if (a.kind == .ind_a16) return 3;
        if (b.kind == .ind_a16) return 3;
        return 1;
    }
    if (std.mem.eql(u8, op, "ldh")) return 2;
    if (std.mem.eql(u8, op, "ldi") or std.mem.eql(u8, op, "ldd")) return 1;
    if (std.mem.eql(u8, op, "add")) {
        if (a.kind == .hl) return 1;
        if (a.kind == .sp) return 2;
        if (b.kind == .imm8) return 2;
        return 1;
    }
    if (std.mem.eql(u8, op, "adc") or std.mem.eql(u8, op, "sub") or std.mem.eql(u8, op, "sbc") or std.mem.eql(u8, op, "and") or std.mem.eql(u8, op, "xor") or std.mem.eql(u8, op, "or") or std.mem.eql(u8, op, "cp")) {
        const target = if (a.kind == .reg8 and a.match("a") and !b.isNone()) b else a;
        if (target.kind == .imm8) return 2;
        return 1;
    }
    if (std.mem.eql(u8, op, "jr")) return 2;
    if (std.mem.eql(u8, op, "jp")) {
        if (a.kind == .hl or a.kind == .ind_hl) return 1;
        return 3;
    }
    if (std.mem.eql(u8, op, "call")) return 3;
    if (std.mem.eql(u8, op, "rlc") or std.mem.eql(u8, op, "rrc") or std.mem.eql(u8, op, "rl") or std.mem.eql(u8, op, "rr") or std.mem.eql(u8, op, "sla") or std.mem.eql(u8, op, "sra") or std.mem.eql(u8, op, "swap") or std.mem.eql(u8, op, "srl") or std.mem.eql(u8, op, "bit") or std.mem.eql(u8, op, "res") or std.mem.eql(u8, op, "set")) return 2;
    return 1;
}

pub fn assembleSource(allocator: std.mem.Allocator, source: []const u8) !Assembler {
    var assembler = Assembler.init(allocator);
    errdefer assembler.deinit();

    var statements: std.ArrayListUnmanaged(Statement) = .empty;
    defer {
        for (statements.items) |st| {
            if (st.label) |name| allocator.free(name);
            if (st.owns_op) allocator.free(st.op);
            for (st.operands[0..st.operand_count]) |op| {
                if (op.text.len != 0) allocator.free(op.text);
            }
        }
        statements.deinit(allocator);
    }

    var line_no: usize = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const statement = parseStatement(raw_line, line_no, allocator) catch return error.OutOfMemory;
        statements.append(allocator, statement) catch return error.OutOfMemory;
        line_no += 1;
    }

    if (assembler.failure != null) return error.AssembleFailed;

    var pass1 = Assembler.init(allocator);
    defer pass1.deinit();

    for (statements.items) |*statement| {
        if (pass1.failure != null) break;
        const op = statement.op;
        if (op.len == 0) {
            if (statement.label) |name| pass1.registerLabel(name, pass1.cursor, statement.line_no);
            continue;
        }
        if (std.mem.eql(u8, op, "org")) {
            pass1.cursor = operandValue(statement.operand(0), &pass1.labels, &pass1, statement.line_no);
            continue;
        }
        if (std.mem.eql(u8, op, "equ")) {
            if (statement.label) |name| {
                const value = operandValue(statement.operand(0), &pass1.labels, &pass1, statement.line_no);
                pass1.registerLabel(name, value, statement.line_no);
            }
            continue;
        }
        if (statement.label) |name| {
            pass1.registerLabel(name, pass1.cursor, statement.line_no);
        }
        if (std.mem.eql(u8, op, "db")) {
            for (statement.operands[0..statement.operand_count]) |operand| {
                const text = operand.text;
                if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                    pass1.cursor += @intCast(text.len - 2);
                } else {
                    pass1.cursor += 1;
                }
            }
            continue;
        }
        if (std.mem.eql(u8, op, "dw")) {
            pass1.cursor += @as(u32, @intCast(2 * statement.operand_count));
            continue;
        }
        if (std.mem.eql(u8, op, "ds")) {
            pass1.cursor += operandValue(statement.operand(0), &pass1.labels, &pass1, statement.line_no);
            continue;
        }
        pass1.cursor += instructionSize(statement);
    }

    if (pass1.failure != null) {
        assembler.failure = pass1.failure;
        return error.AssembleFailed;
    }

    assembler.labels = pass1.labels;
    pass1.labels = LabelMap.init(allocator);

    for (statements.items) |statement| {
        if (assembler.failure != null) break;
        const op = statement.op;
        if (op.len == 0) continue;
        if (std.mem.eql(u8, op, "org") or std.mem.eql(u8, op, "equ") or std.mem.eql(u8, op, "db") or std.mem.eql(u8, op, "dw") or std.mem.eql(u8, op, "ds")) {
            assembleData(&assembler, &statement, op);
        } else {
            assembleInstruction(&assembler, &statement);
        }
    }

    return assembler;
}

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
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| {
        try args.append(allocator, arg);
    }
    const argv = args.items;

    if (argv.len < 3) {
        std.debug.print("Usage: {s} <asm-dir> <rom-dir>\n", .{argv[0]});
        std.process.exit(2);
    }

    var asm_dir = try std.Io.Dir.cwd().openDir(io, argv[1], .{ .iterate = true });
    defer asm_dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var iter = asm_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".asm")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    var failures: usize = 0;
    for (names.items) |name| {
        const path = try std.fs.path.join(allocator, &.{ argv[1], name });
        defer allocator.free(path);

        const source = readFile(io, allocator, path) catch |err| {
            std.debug.print("{s}: cannot read: {s}\n", .{ name, @errorName(err) });
            failures += 1;
            allocator.free(name);
            continue;
        };
        defer allocator.free(source);

        var result = assembleSource(allocator, source) catch |err| {
            std.debug.print("{s}: assembly failed: {s}\n", .{ name, @errorName(err) });
            failures += 1;
            allocator.free(name);
            continue;
        };
        defer result.deinit();

        if (result.failure) |failure| {
            std.debug.print("{s}:{d}: error: {s}\n", .{ name, failure.line_no, failure.message });
            failures += 1;
            allocator.free(name);
            continue;
        }

        const output_name = try std.fmt.allocPrint(allocator, "{s}.gb", .{name[0 .. name.len - 4]});
        defer allocator.free(output_name);
        const output_path = try std.fs.path.join(allocator, &.{ argv[2], output_name });
        defer allocator.free(output_path);

        writeFile(io, allocator, output_path, result.rom[0..]) catch |err| {
            std.debug.print("{s}: cannot write: {s}\n", .{ output_name, @errorName(err) });
            failures += 1;
            allocator.free(name);
            continue;
        };
        allocator.free(name);
    }

    if (failures != 0) std.process.exit(1);
}

test "assembles a minimal ROM and encodes core instructions" {
    const source =
        \\org $0100
        \\  ld a,$3c
        \\  ld b,a
        \\  add a,b
        \\  jp done
        \\done:
        \\  halt
    ;
    var assembler = try assembleSource(std.testing.allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.failure == null);
    try std.testing.expectEqual(@as(u8, 0x3e), assembler.rom[0x0100]);
    try std.testing.expectEqual(@as(u8, 0x3c), assembler.rom[0x0101]);
    try std.testing.expectEqual(@as(u8, 0x47), assembler.rom[0x0102]);
    try std.testing.expectEqual(@as(u8, 0x80), assembler.rom[0x0103]);
    try std.testing.expectEqual(@as(u8, 0xc3), assembler.rom[0x0104]);
    try std.testing.expectEqual(@as(u8, 0x07), assembler.rom[0x0105]);
    try std.testing.expectEqual(@as(u8, 0x01), assembler.rom[0x0106]);
    try std.testing.expectEqual(@as(u8, 0x76), assembler.rom[0x0107]);
}

test "encodes 16-bit, stack, and relative jump instructions" {
    const source =
        \\org $0100
        \\  ld sp,$dff0
        \\  push hl
        \\  pop af
        \\  call routine
        \\  jr loop
        \\loop:
        \\  jr loop
        \\routine:
        \\  ret
    ;
    var assembler = try assembleSource(std.testing.allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.failure == null);
    try std.testing.expectEqual(@as(u8, 0x31), assembler.rom[0x0100]);
    try std.testing.expectEqual(@as(u8, 0xf0), assembler.rom[0x0101]);
    try std.testing.expectEqual(@as(u8, 0xdf), assembler.rom[0x0102]);
    try std.testing.expectEqual(@as(u8, 0xe5), assembler.rom[0x0103]);
    try std.testing.expectEqual(@as(u8, 0xf1), assembler.rom[0x0104]);
    try std.testing.expectEqual(@as(u8, 0xcd), assembler.rom[0x0105]);
    try std.testing.expectEqual(@as(u8, 0x0c), assembler.rom[0x0106]);
    try std.testing.expectEqual(@as(u8, 0x01), assembler.rom[0x0107]);
    try std.testing.expectEqual(@as(u8, 0x18), assembler.rom[0x0108]);
    try std.testing.expectEqual(@as(u8, 0x00), assembler.rom[0x0109]);
    try std.testing.expectEqual(@as(u8, 0x18), assembler.rom[0x010a]);
    try std.testing.expectEqual(@as(u8, 0xfe), assembler.rom[0x010b]);
    try std.testing.expectEqual(@as(u8, 0xc9), assembler.rom[0x010c]);
}

test "encodes CB-prefixed instructions" {
    const source =
        \\org $0100
        \\  sla b
        \\  bit 3,(hl)
        \\  set 7,a
        \\  rlc c
    ;
    var assembler = try assembleSource(std.testing.allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.failure == null);
    try std.testing.expectEqual(@as(u8, 0xcb), assembler.rom[0x0100]);
    try std.testing.expectEqual(@as(u8, 0x20), assembler.rom[0x0101]);
    try std.testing.expectEqual(@as(u8, 0xcb), assembler.rom[0x0102]);
    try std.testing.expectEqual(@as(u8, 0x5e), assembler.rom[0x0103]);
    try std.testing.expectEqual(@as(u8, 0xcb), assembler.rom[0x0104]);
    try std.testing.expectEqual(@as(u8, 0xff), assembler.rom[0x0105]);
    try std.testing.expectEqual(@as(u8, 0xcb), assembler.rom[0x0106]);
    try std.testing.expectEqual(@as(u8, 0x01), assembler.rom[0x0107]);
}

test "encodes ALU immediate and register instructions" {
    const source =
        \\org $0100
        \\  adc a,$12
        \\  sub $13
        \\  sbc $14
        \\  and $15
        \\  xor $16
        \\  or $17
        \\  cp $18
        \\  adc a,b
        \\  or (hl)
    ;
    var assembler = try assembleSource(std.testing.allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.failure == null);
    try std.testing.expectEqual(@as(u8, 0xce), assembler.rom[0x0100]);
    try std.testing.expectEqual(@as(u8, 0x12), assembler.rom[0x0101]);
    try std.testing.expectEqual(@as(u8, 0xd6), assembler.rom[0x0102]);
    try std.testing.expectEqual(@as(u8, 0x13), assembler.rom[0x0103]);
    try std.testing.expectEqual(@as(u8, 0xde), assembler.rom[0x0104]);
    try std.testing.expectEqual(@as(u8, 0x14), assembler.rom[0x0105]);
    try std.testing.expectEqual(@as(u8, 0xe6), assembler.rom[0x0106]);
    try std.testing.expectEqual(@as(u8, 0x15), assembler.rom[0x0107]);
    try std.testing.expectEqual(@as(u8, 0xee), assembler.rom[0x0108]);
    try std.testing.expectEqual(@as(u8, 0x16), assembler.rom[0x0109]);
    try std.testing.expectEqual(@as(u8, 0xf6), assembler.rom[0x010a]);
    try std.testing.expectEqual(@as(u8, 0x17), assembler.rom[0x010b]);
    try std.testing.expectEqual(@as(u8, 0xfe), assembler.rom[0x010c]);
    try std.testing.expectEqual(@as(u8, 0x18), assembler.rom[0x010d]);
    try std.testing.expectEqual(@as(u8, 0x88), assembler.rom[0x010e]);
    try std.testing.expectEqual(@as(u8, 0xb6), assembler.rom[0x010f]);
}

test "resolves forward label references in expressions" {
    const source =
        \\org $0100
        \\  jp target
        \\  ds $20
        \\target:
        \\  nop
    ;
    var assembler = try assembleSource(std.testing.allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.failure == null);
    try std.testing.expectEqual(@as(u8, 0xc3), assembler.rom[0x0100]);
    try std.testing.expectEqual(@as(u8, 0x23), assembler.rom[0x0101]);
    try std.testing.expectEqual(@as(u8, 0x01), assembler.rom[0x0102]);
}

test "assembles high-memory and SP-offset instructions" {
    const source =
        \\org $0100
        \\  ldh ($ff44),a
        \\  ldh a,($ff00+$44)
        \\  add sp,-$08
        \\  ld hl,sp+$10
        \\  ld (hl+),a
    ;
    var assembler = try assembleSource(std.testing.allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.failure == null);
    try std.testing.expectEqual(@as(u8, 0xe0), assembler.rom[0x0100]);
    try std.testing.expectEqual(@as(u8, 0x44), assembler.rom[0x0101]);
    try std.testing.expectEqual(@as(u8, 0xf0), assembler.rom[0x0102]);
    try std.testing.expectEqual(@as(u8, 0x44), assembler.rom[0x0103]);
    try std.testing.expectEqual(@as(u8, 0xe8), assembler.rom[0x0104]);
    try std.testing.expectEqual(@as(u8, 0xf8), assembler.rom[0x0105]);
    try std.testing.expectEqual(@as(u8, 0xf8), assembler.rom[0x0106]);
    try std.testing.expectEqual(@as(u8, 0x10), assembler.rom[0x0107]);
    try std.testing.expectEqual(@as(u8, 0x22), assembler.rom[0x0108]);
}

test "emits data directives and equ constants" {
    const source =
        \\start equ $0100
        \\org start
        \\  db "Hi", $0a, $0d
        \\  dw start
        \\  ds $04
    ;
    var assembler = try assembleSource(std.testing.allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.failure == null);
    try std.testing.expectEqual(@as(u8, 'H'), assembler.rom[0x0100]);
    try std.testing.expectEqual(@as(u8, 'i'), assembler.rom[0x0101]);
    try std.testing.expectEqual(@as(u8, 0x0a), assembler.rom[0x0102]);
    try std.testing.expectEqual(@as(u8, 0x0d), assembler.rom[0x0103]);
    try std.testing.expectEqual(@as(u8, 0x00), assembler.rom[0x0104]);
    try std.testing.expectEqual(@as(u8, 0x01), assembler.rom[0x0105]);
}

test "reports unknown mnemonic as a failure" {
    const source =
        \\org $0100
        \\  frobnicate a
    ;
    var assembler = try assembleSource(std.testing.allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.failure != null);
}
