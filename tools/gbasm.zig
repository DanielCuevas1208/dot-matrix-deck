// A small, deterministic assembler for SM83 test ROMs.
//
// It reads `.asm` files from a source directory and writes a ROM image
// for each one into an output directory. The assembler is deliberately
// small. It covers the instruction set and directives that bundled
// fixtures need. The output is byte-for-byte deterministic: the same
// source always produces the same ROM.
//
// The GB boot ROM is not emulated, so an image starts at address $0100.
// The Nintendo logo and header checksums are not validated by the
// emulator, so fixtures set only the fields they actually use, such as
// the title at $0134.

const std = @import("std");

const Operand = []const u8;

const ParsedLine = union(enum) {
    label: []const u8,
    org: []const u8,
    db: []Operand,
    dw: []Operand,
    ds: struct { count: []const u8, fill: ?[]const u8 },
    instruction: struct { mnemonic: []const u8, operands: []Operand },
};

const Symbol = struct {
    name: []const u8,
    value: i32,
};

const Form = enum {
    nop,
    halt,
    stop,
    di,
    ei,
    daa,
    cpl,
    scf,
    ccf,
    rlca,
    rrca,
    rla,
    rra,
    ld_r8_r8,
    ld_r8_imm8,
    ld_r8_hl,
    ld_hl_r8,
    ld_hl_imm8,
    ld_a_bc,
    ld_a_de,
    ld_a_a16,
    ld_bc_a,
    ld_de_a,
    ld_a16_a,
    ld_r16_imm16,
    ld_a16_sp,
    ld_sp_hl,
    ld_hl_sp_e8,
    ld_hl_inc_a,
    ld_hl_dec_a,
    ld_a_hl_inc,
    ld_a_hl_dec,
    ldh_a8_a,
    ldh_a_a8,
    ld_c_a,
    ld_a_c,
    inc_r8,
    dec_r8,
    inc_hl,
    dec_hl,
    inc_r16,
    dec_r16,
    alu_a_r8,
    alu_a_imm8,
    add_hl_r16,
    add_sp_e8,
    jp_a16,
    jp_cc_a16,
    jp_hl,
    jr_e8,
    jr_cc_e8,
    call_a16,
    call_cc_a16,
    ret,
    ret_cc,
    reti,
    push_r16,
    pop_r16,
    rst_vec,
    cb_shift,
    cb_bit,
    cb_res,
    cb_set,
};

const OpClass = enum {
    reg8,
    reg16,
    af,
    mem_bc,
    mem_de,
    mem_hl,
    mem_hl_inc,
    mem_hl_dec,
    mem_c,
    mem_a16,
    cond,
    other,
};

pub const Assembler = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayList(Symbol) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    error_line: usize = 0,
    error_message: []const u8 = "",

    pub fn deinit(self: *Assembler) void {
        self.symbols.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
    }

    fn fail(self: *Assembler, message: []const u8) anyerror {
        self.error_message = message;
        return error.AssemblyFailed;
    }

    fn resolve(self: *Assembler, name: []const u8) ?i32 {
        for (self.symbols.items) |symbol| {
            if (std.mem.eql(u8, symbol.name, name)) return symbol.value;
        }
        return null;
    }

    fn define(self: *Assembler, name: []const u8, value: i32) !void {
        if (self.resolve(name) != null) return self.fail("duplicate label");
        try self.symbols.append(self.allocator, .{ .name = name, .value = value });
    }

    fn ensureSize(self: *Assembler, size: usize) !void {
        if (size < self.bytes.items.len) return self.fail("origin overlaps earlier code");
        try self.bytes.appendNTimes(self.allocator, 0, size - self.bytes.items.len);
    }

    fn byte(self: *Assembler, value: u8) !void {
        try self.bytes.append(self.allocator, value);
    }

    fn word(self: *Assembler, value: u32) !void {
        try self.bytes.append(self.allocator, @intCast(value & 0xff));
        try self.bytes.append(self.allocator, @intCast((value >> 8) & 0xff));
    }

    fn signedByte(self: *Assembler, value: i32) !void {
        if (value < -128 or value > 127) return self.fail("signed value out of range");
        try self.byte(@bitCast(@as(i8, @intCast(value))));
    }

    pub fn assemble(self: *Assembler, source: []const u8) ![]u8 {
        const lines = try parseSource(self.allocator, source);
        defer freeLines(self.allocator, lines);

        try self.layout(lines);
        self.bytes.clearRetainingCapacity();

        var index: usize = 0;
        while (index < lines.len) : (index += 1) {
            self.error_line = index + 1;
            const line = lines[index];
            switch (line) {
                .label => {},
                .org => |expr| {
                    const target = try self.evalExpr(expr, self.bytes.items.len);
                    try self.ensureSize(@intCast(target));
                },
                .db => |operands| {
                    for (operands) |operand| try self.emitDbOperand(operand);
                },
                .dw => |operands| {
                    for (operands) |operand| {
                        const value = try self.evalOperand(operand);
                        if (value < 0 or value > 0xffff) return self.fail("word value out of range");
                        try self.word(@intCast(value));
                    }
                },
                .ds => |directive| {
                    const count = try self.evalExpr(directive.count, self.bytes.items.len);
                    if (count < 0) return self.fail("negative ds count");
                    const fill: u8 = if (directive.fill) |text| blk: {
                        const value = try self.evalOperand(text);
                        if (value < 0 or value > 0xff) return self.fail("fill value out of range");
                        break :blk @intCast(value);
                    } else 0;
                    try self.bytes.appendNTimes(self.allocator, fill, @intCast(count));
                },
                .instruction => |ins| {
                    const before = self.bytes.items.len;
                    try self.emitInstruction(ins.mnemonic, ins.operands, before);
                },
            }
        }

        const size = romSize(self.bytes.items.len);
        try self.bytes.appendNTimes(self.allocator, 0, size - self.bytes.items.len);
        return self.bytes.toOwnedSlice(self.allocator);
    }

    fn layout(self: *Assembler, lines: []const ParsedLine) !void {
        var pc: usize = 0;
        var index: usize = 0;
        while (index < lines.len) : (index += 1) {
            self.error_line = index + 1;
            const line = lines[index];
            switch (line) {
                .label => |name| try self.define(name, @intCast(pc)),
                .org => |expr| pc = @intCast(try self.evalExpr(expr, pc)),
                .db => |operands| {
                    for (operands) |operand| pc += try self.dbItemLength(operand);
                },
                .dw => |operands| pc += operands.len * 2,
                .ds => |directive| pc += @intCast(try self.evalExpr(directive.count, pc)),
                .instruction => |ins| pc += try self.layoutInstruction(ins.mnemonic, ins.operands),
            }
        }
    }

    fn dbItemLength(self: *Assembler, operand: []const u8) !usize {
        const text = std.mem.trim(u8, operand, " \t");
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            return scanStringLength(text[1 .. text.len - 1]) catch return self.fail("bad string literal");
        }
        return 1;
    }

    fn emitDbOperand(self: *Assembler, operand: []const u8) !void {
        const text = std.mem.trim(u8, operand, " \t");
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            var buffer: [256]u8 = undefined;
            const decoded = try self.decodeString(text[1 .. text.len - 1], &buffer);
            try self.bytes.appendSlice(self.allocator, decoded);
            return;
        }
        const value = try self.evalOperand(text);
        if (value < 0 or value > 0xff) return self.fail("byte value out of range");
        try self.byte(@intCast(value));
    }

    fn decodeString(self: *Assembler, text: []const u8, buffer: []u8) ![]u8 {
        var out: usize = 0;
        var index: usize = 0;
        while (index < text.len) {
            const ch = text[index];
            index += 1;
            if (ch != '\\') {
                if (out == buffer.len) return self.fail("string literal too long");
                buffer[out] = ch;
                out += 1;
                continue;
            }
            if (index >= text.len) return self.fail("unterminated escape sequence");
            const escaped = text[index];
            index += 1;
            const value: u8 = switch (escaped) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '0' => 0,
                '\\' => '\\',
                '\'' => '\'',
                '"' => '"',
                else => return self.fail("unknown escape sequence"),
            };
            if (out == buffer.len) return self.fail("string literal too long");
            buffer[out] = value;
            out += 1;
        }
        return buffer[0..out];
    }

    fn scanStringLength(text: []const u8) error{BadEscape}!usize {
        var length: usize = 0;
        var index: usize = 0;
        while (index < text.len) {
            const ch = text[index];
            index += 1;
            if (ch == '\\') {
                if (index >= text.len) return error.BadEscape;
                index += 1;
            }
            length += 1;
        }
        return length;
    }

    fn evalOperand(self: *Assembler, operand: []const u8) !i32 {
        const text = std.mem.trim(u8, operand, " \t");
        if (text.len == 0) return self.fail("missing value");
        return self.evalExpr(text, self.bytes.items.len);
    }

    // Evaluates a simple expression made of + and - terms.
    fn evalExpr(self: *Assembler, text: []const u8, pc: usize) !i32 {
        var index: usize = 0;
        self.skipWs(text, &index);
        if (index >= text.len) return self.fail("expected a value");

        var sign: i32 = 1;
        if (text[index] == '+' or text[index] == '-') {
            if (text[index] == '-') sign = -1;
            index += 1;
            self.skipWs(text, &index);
        }
        var value = sign * (try self.parseTerm(text, &index, pc));
        while (true) {
            self.skipWs(text, &index);
            if (index >= text.len) break;
            const op = text[index];
            if (op != '+' and op != '-') return self.fail("unsupported operator");
            index += 1;
            self.skipWs(text, &index);
            const term = try self.parseTerm(text, &index, pc);
            value = if (op == '+') value + term else value - term;
        }
        self.skipWs(text, &index);
        if (index != text.len) return self.fail("unexpected characters in expression");
        return value;
    }

    fn parseTerm(self: *Assembler, text: []const u8, index: *usize, pc: usize) !i32 {
        const start = index.*;
        if (index.* >= text.len) return self.fail("expected a value");
        const ch = text[index.*];

        if (ch == '$') {
            index.* += 1;
            if (index.* < text.len and std.ascii.isHex(text[index.*])) {
                var value: i32 = 0;
                while (index.* < text.len and std.ascii.isHex(text[index.*])) : (index.* += 1) {
                    value = value * 16 + (std.fmt.charToDigit(text[index.*], 16) catch return self.fail("bad hex digit"));
                }
                return value;
            }
            if (index.* == start + 1) return @intCast(pc);
            return self.fail("bad hex literal");
        }

        if (ch == '%') {
            index.* += 1;
            var value: i32 = 0;
            while (index.* < text.len and (text[index.*] == '0' or text[index.*] == '1')) : (index.* += 1) {
                value = value * 2 + (text[index.*] - '0');
            }
            if (index.* == start + 1) return self.fail("bad binary literal");
            return value;
        }

        if (ch == '0' and index.* + 1 < text.len and (text[index.* + 1] == 'x' or text[index.* + 1] == 'X')) {
            index.* += 2;
            var value: i32 = 0;
            while (index.* < text.len and std.ascii.isHex(text[index.*])) : (index.* += 1) {
                value = value * 16 + (std.fmt.charToDigit(text[index.*], 16) catch return self.fail("bad hex digit"));
            }
            return value;
        }

        if (ch == '\'') {
            index.* += 1;
            if (index.* >= text.len) return self.fail("unterminated character literal");
            const value: i32 = text[index.*];
            index.* += 1;
            if (index.* >= text.len or text[index.*] != '\'') return self.fail("unterminated character literal");
            index.* += 1;
            return value;
        }

        if (std.ascii.isAlphabetic(ch) or ch == '_' or ch == '.') {
            const name_start = index.*;
            while (index.* < text.len and (std.ascii.isAlphanumeric(text[index.*]) or text[index.*] == '_' or text[index.*] == '.')) : (index.* += 1) {}
            const name = text[name_start..index.*];
            return self.resolve(name) orelse return self.fail("undefined label");
        }

        if (std.ascii.isDigit(ch)) {
            var value: i32 = 0;
            while (index.* < text.len and std.ascii.isDigit(text[index.*])) : (index.* += 1) {
                value = value * 10 + (text[index.*] - '0');
            }
            return value;
        }

        return self.fail("expected a value");
    }

    fn skipWs(_: *Assembler, text: []const u8, index: *usize) void {
        while (index.* < text.len and (text[index.*] == ' ' or text[index.*] == '\t')) index.* += 1;
    }

    fn layoutInstruction(self: *Assembler, mnemonic: []const u8, operands: []const Operand) !usize {
        const form = try self.formOf(mnemonic, operands);
        return formLength(form);
    }

    fn emitInstruction(self: *Assembler, mnemonic: []const u8, operands: []const Operand, pc: usize) !void {
        const form = try self.formOf(mnemonic, operands);
        const expected = formLength(form);
        const before = self.bytes.items.len;
        try self.emitForm(mnemonic, form, operands, pc);
        if (self.bytes.items.len - before != expected) return self.fail("internal layout mismatch");
    }

    fn formOf(self: *Assembler, mnemonic: []const u8, operands: []const Operand) !Form {
        const count = operands.len;
        const first: []const u8 = if (count > 0) std.mem.trim(u8, operands[0], " \t") else "";
        const second: []const u8 = if (count > 1) std.mem.trim(u8, operands[1], " \t") else "";

        if (std.ascii.eqlIgnoreCase(mnemonic, "nop")) {
            if (count != 0) return self.fail("NOP takes no operands");
            return .nop;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "halt")) {
            if (count != 0) return self.fail("HALT takes no operands");
            return .halt;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "stop")) {
            if (count != 0) return self.fail("STOP takes no operands");
            return .stop;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "di")) {
            if (count != 0) return self.fail("DI takes no operands");
            return .di;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "ei")) {
            if (count != 0) return self.fail("EI takes no operands");
            return .ei;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "daa")) {
            if (count != 0) return self.fail("DAA takes no operands");
            return .daa;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "cpl")) {
            if (count != 0) return self.fail("CPL takes no operands");
            return .cpl;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "scf")) {
            if (count != 0) return self.fail("SCF takes no operands");
            return .scf;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "ccf")) {
            if (count != 0) return self.fail("CCF takes no operands");
            return .ccf;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "rlca")) {
            if (count != 0) return self.fail("RLCA takes no operands");
            return .rlca;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "rrca")) {
            if (count != 0) return self.fail("RRCA takes no operands");
            return .rrca;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "rla")) {
            if (count != 0) return self.fail("RLA takes no operands");
            return .rla;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "rra")) {
            if (count != 0) return self.fail("RRA takes no operands");
            return .rra;
        }
        if (std.ascii.eqlIgnoreCase(mnemonic, "reti")) {
            if (count != 0) return self.fail("RETI takes no operands");
            return .reti;
        }

        if (std.ascii.eqlIgnoreCase(mnemonic, "ld") or std.ascii.eqlIgnoreCase(mnemonic, "ldh")) {
            if (count != 2) return self.fail("LD takes two operands");
            const is_ldh = std.ascii.eqlIgnoreCase(mnemonic, "ldh");
            const first_class = classifyOperand(first);
            const second_class = classifyOperand(second);
            if (is_ldh) {
                if (first_class == .mem_a16 and second_class == .reg8) return .ldh_a8_a;
                if (first_class == .reg8 and second_class == .mem_a16) return .ldh_a_a8;
                return self.fail("invalid LDH operands");
            }
            switch (first_class) {
                .reg8 => switch (second_class) {
                    .reg8 => return .ld_r8_r8,
                    .mem_hl => return .ld_r8_hl,
                    .mem_bc => if (isRegA(first)) return .ld_a_bc else return self.fail("only A can load from (BC)"),
                    .mem_de => if (isRegA(first)) return .ld_a_de else return self.fail("only A can load from (DE)"),
                    .mem_a16 => if (isRegA(first)) return .ld_a_a16 else return self.fail("only A can load from (a16)"),
                    .mem_hl_inc => if (isRegA(first)) return .ld_a_hl_inc else return self.fail("only A can load from (HL+)"),
                    .mem_hl_dec => if (isRegA(first)) return .ld_a_hl_dec else return self.fail("only A can load from (HL-)"),
                    .mem_c => if (isRegA(first)) return .ld_a_c else return self.fail("only A can load from (C)"),
                    .other => return .ld_r8_imm8,
                    else => return self.fail("invalid LD operands"),
                },
                .mem_hl => switch (second_class) {
                    .reg8 => return .ld_hl_r8,
                    .other => return .ld_hl_imm8,
                    else => return self.fail("invalid LD (HL) operands"),
                },
                .mem_bc => if (second_class == .reg8 and isRegA(second)) return .ld_bc_a else return self.fail("only A can store to (BC)"),
                .mem_de => if (second_class == .reg8 and isRegA(second)) return .ld_de_a else return self.fail("only A can store to (DE)"),
                .mem_a16 => switch (second_class) {
                    .reg8 => if (isRegA(second)) return .ld_a16_a else return self.fail("only A can store to (a16)"),
                    .reg16 => if (isRegSP(second)) return .ld_a16_sp else return self.fail("only SP can store to (a16)"),
                    else => return self.fail("invalid LD (a16) operands"),
                },
                .mem_hl_inc => if (second_class == .reg8 and isRegA(second)) return .ld_hl_inc_a else return self.fail("only A can store to (HL+)"),
                .mem_hl_dec => if (second_class == .reg8 and isRegA(second)) return .ld_hl_dec_a else return self.fail("only A can store to (HL-)"),
                .mem_c => if (second_class == .reg8 and isRegA(second)) return .ld_c_a else return self.fail("only A can store to (C)"),
                .reg16 => switch (second_class) {
                    .reg16 => {
                        if (isRegSP(first) and isRegHL(second)) return .ld_sp_hl;
                        if (isRegHL(first) and startsWithSp(second)) return .ld_hl_sp_e8;
                        return self.fail("invalid LD register pair");
                    },
                    .other => return .ld_r16_imm16,
                    else => return self.fail("invalid LD register pair"),
                },
                else => return self.fail("invalid LD operands"),
            }
        }

        if (aluIndex(mnemonic) != null) {
            const first_class = classifyOperand(first);
            const is_add = std.ascii.eqlIgnoreCase(mnemonic, "add");
            if (count == 2) {
                const second_class = classifyOperand(second);
                if (first_class == .reg8 and isRegA(first)) {
                    if (second_class == .reg8) return .alu_a_r8;
                    if (second_class == .other) return .alu_a_imm8;
                    return self.fail("invalid ALU operands");
                }
                if (is_add and first_class == .reg16 and isRegHL(first) and second_class == .reg16) return .add_hl_r16;
                if (is_add and first_class == .reg16 and isRegSP(first) and second_class == .other) return .add_sp_e8;
                return self.fail("invalid ALU operands");
            }
            if (count == 1) {
                if (first_class == .reg8) return .alu_a_r8;
                if (first_class == .other) return .alu_a_imm8;
                return self.fail("invalid ALU operands");
            }
            return self.fail("ALU instruction takes one or two operands");
        }

        if (std.ascii.eqlIgnoreCase(mnemonic, "inc") or std.ascii.eqlIgnoreCase(mnemonic, "dec")) {
            if (count != 1) return self.fail("INC/DEC takes one operand");
            const is_inc = std.ascii.eqlIgnoreCase(mnemonic, "inc");
            switch (classifyOperand(first)) {
                .reg8 => return if (is_inc) .inc_r8 else .dec_r8,
                .mem_hl => return if (is_inc) .inc_hl else .dec_hl,
                .reg16 => return if (is_inc) .inc_r16 else .dec_r16,
                else => return self.fail("invalid INC/DEC operand"),
            }
        }

        if (std.ascii.eqlIgnoreCase(mnemonic, "jp")) {
            if (count == 1 and classifyOperand(first) == .mem_hl) return .jp_hl;
            if (count == 1 and classifyOperand(first) == .other) return .jp_a16;
            if (count == 2 and condIndex(first) != null and classifyOperand(second) == .other) return .jp_cc_a16;
            return self.fail("invalid JP operands");
        }

        if (std.ascii.eqlIgnoreCase(mnemonic, "jr")) {
            if (count == 1 and classifyOperand(first) == .other) return .jr_e8;
            if (count == 2 and condIndex(first) != null and classifyOperand(second) == .other) return .jr_cc_e8;
            return self.fail("invalid JR operands");
        }

        if (std.ascii.eqlIgnoreCase(mnemonic, "call")) {
            if (count == 1 and classifyOperand(first) == .other) return .call_a16;
            if (count == 2 and condIndex(first) != null and classifyOperand(second) == .other) return .call_cc_a16;
            return self.fail("invalid CALL operands");
        }

        if (std.ascii.eqlIgnoreCase(mnemonic, "ret")) {
            if (count == 0) return .ret;
            if (count == 1 and condIndex(first) != null) return .ret_cc;
            return self.fail("invalid RET operands");
        }

        if (std.ascii.eqlIgnoreCase(mnemonic, "push") or std.ascii.eqlIgnoreCase(mnemonic, "pop")) {
            if (count != 1) return self.fail("PUSH/POP takes one operand");
            const is_push = std.ascii.eqlIgnoreCase(mnemonic, "push");
            const c = classifyOperand(first);
            if (c == .reg16 or c == .af) return if (is_push) .push_r16 else .pop_r16;
            return self.fail("invalid PUSH/POP operand");
        }

        if (std.ascii.eqlIgnoreCase(mnemonic, "rst")) {
            if (count != 1 or classifyOperand(first) != .other) return self.fail("invalid RST operand");
            return .rst_vec;
        }

        if (shiftIndex(mnemonic)) |_| {
            if (count != 1) return self.fail("rotate and shift takes one operand");
            const c = classifyOperand(first);
            if (c == .reg8 or c == .mem_hl) return .cb_shift;
            return self.fail("invalid rotate and shift operand");
        }

        if (std.ascii.eqlIgnoreCase(mnemonic, "bit") or
            std.ascii.eqlIgnoreCase(mnemonic, "res") or
            std.ascii.eqlIgnoreCase(mnemonic, "set"))
        {
            if (count != 2 or classifyOperand(first) != .other) return self.fail("invalid BIT/RES/SET operands");
            const c = classifyOperand(second);
            if (c == .reg8 or c == .mem_hl) {
                if (std.ascii.eqlIgnoreCase(mnemonic, "bit")) return .cb_bit;
                if (std.ascii.eqlIgnoreCase(mnemonic, "res")) return .cb_res;
                return .cb_set;
            }
            return self.fail("invalid BIT/RES/SET target");
        }

        return self.fail("unknown mnemonic");
    }

    fn emitForm(self: *Assembler, mnemonic: []const u8, form: Form, operands: []const Operand, pc: usize) !void {
        const first: []const u8 = if (operands.len > 0) std.mem.trim(u8, operands[0], " \t") else "";
        const second: []const u8 = if (operands.len > 1) std.mem.trim(u8, operands[1], " \t") else "";

        switch (form) {
            .nop => try self.byte(0x00),
            .halt => try self.byte(0x76),
            .stop => {
                try self.byte(0x10);
                try self.byte(0x00);
            },
            .di => try self.byte(0xf3),
            .ei => try self.byte(0xfb),
            .daa => try self.byte(0x27),
            .cpl => try self.byte(0x2f),
            .scf => try self.byte(0x37),
            .ccf => try self.byte(0x3f),
            .rlca => try self.byte(0x07),
            .rrca => try self.byte(0x0f),
            .rla => try self.byte(0x17),
            .rra => try self.byte(0x1f),
            .reti => try self.byte(0xd9),

            .ld_r8_r8 => try self.byte(0x40 | (@as(u8, reg8Index(first).?) << 3) | @as(u8, reg8Index(second).?)),
            .ld_r8_imm8 => {
                try self.byte(0x06 | (@as(u8, reg8Index(first).?) << 3));
                try self.emitImm8(second);
            },
            .ld_r8_hl => try self.byte(0x46 | (@as(u8, reg8Index(first).?) << 3)),
            .ld_hl_r8 => try self.byte(0x70 | @as(u8, reg8Index(second).?)),
            .ld_hl_imm8 => {
                try self.byte(0x36);
                try self.emitImm8(second);
            },
            .ld_a_bc => try self.byte(0x0a),
            .ld_a_de => try self.byte(0x1a),
            .ld_a_a16 => {
                try self.byte(0xfa);
                try self.emitImm16(self.stripParens(second));
            },
            .ld_bc_a => try self.byte(0x02),
            .ld_de_a => try self.byte(0x12),
            .ld_a16_a => {
                try self.byte(0xea);
                try self.emitImm16(self.stripParens(first));
            },
            .ld_r16_imm16 => {
                try self.byte(0x01 | (@as(u8, reg16Index(first).?) << 4));
                try self.emitImm16(second);
            },
            .ld_a16_sp => {
                try self.byte(0x08);
                try self.emitImm16(self.stripParens(first));
            },
            .ld_sp_hl => try self.byte(0xf9),
            .ld_hl_sp_e8 => {
                try self.byte(0xf8);
                try self.emitSigned(second, pc);
            },
            .ld_hl_inc_a => try self.byte(0x22),
            .ld_hl_dec_a => try self.byte(0x32),
            .ld_a_hl_inc => try self.byte(0x2a),
            .ld_a_hl_dec => try self.byte(0x3a),
            .ldh_a8_a => {
                try self.byte(0xe0);
                try self.emitImm8(self.stripParens(first));
            },
            .ldh_a_a8 => {
                try self.byte(0xf0);
                try self.emitImm8(self.stripParens(second));
            },
            .ld_c_a => try self.byte(0xe2),
            .ld_a_c => try self.byte(0xf2),

            .inc_r8 => try self.byte(0x04 | (@as(u8, reg8Index(first).?) << 3)),
            .dec_r8 => try self.byte(0x05 | (@as(u8, reg8Index(first).?) << 3)),
            .inc_hl => try self.byte(0x34),
            .dec_hl => try self.byte(0x35),
            .inc_r16 => try self.byte(0x03 | (@as(u8, reg16Index(first).?) << 4)),
            .dec_r16 => try self.byte(0x0b | (@as(u8, reg16Index(first).?) << 4)),

            .alu_a_r8 => try self.byte(0x80 | (@as(u8, aluIndex(mnemonic).?) << 3) | @as(u8, reg8Index(self.lastOperand(operands)).?)),
            .alu_a_imm8 => {
                try self.byte(0xc6 | (@as(u8, aluIndex(mnemonic).?) << 3));
                try self.emitImm8(self.lastOperand(operands));
            },
            .add_hl_r16 => try self.byte(0x09 | (@as(u8, reg16Index(second).?) << 4)),
            .add_sp_e8 => {
                try self.byte(0xe8);
                try self.emitSigned(second, pc);
            },

            .jp_a16 => {
                try self.byte(0xc3);
                try self.emitImm16(first);
            },
            .jp_cc_a16 => {
                try self.byte(0xc2 | (@as(u8, condIndex(first).?) << 3));
                try self.emitImm16(second);
            },
            .jp_hl => try self.byte(0xe9),
            .jr_e8 => {
                try self.byte(0x18);
                try self.emitJumpOffset(first, pc);
            },
            .jr_cc_e8 => {
                try self.byte(0x20 | (@as(u8, condIndex(first).?) << 3));
                try self.emitJumpOffset(second, pc);
            },
            .call_a16 => {
                try self.byte(0xcd);
                try self.emitImm16(first);
            },
            .call_cc_a16 => {
                try self.byte(0xc4 | (@as(u8, condIndex(first).?) << 3));
                try self.emitImm16(second);
            },
            .ret => try self.byte(0xc9),
            .ret_cc => try self.byte(0xc0 | (@as(u8, condIndex(first).?) << 3)),
            .push_r16 => try self.byte(0xc5 | (@as(u8, pairIndex(first).?) << 4)),
            .pop_r16 => try self.byte(0xc1 | (@as(u8, pairIndex(first).?) << 4)),
            .rst_vec => {
                const value = try self.evalOperand(first);
                if (value != 0x00 and value != 0x08 and value != 0x10 and value != 0x18 and
                    value != 0x20 and value != 0x28 and value != 0x30 and value != 0x38)
                    return self.fail("RST vector must be a multiple of 8 up to $38");
                try self.byte(0xc7 | @as(u8, @intCast(value)));
            },

            .cb_shift => {
                const shift: u8 = shiftIndex(mnemonic).?;
                const target = regIndexOrMem(first);
                try self.byte(0xcb);
                try self.byte((shift << 3) | target);
            },
            .cb_bit => {
                const bit = try self.evalOperand(first);
                if (bit < 0 or bit > 7) return self.fail("bit number must be 0-7");
                const target = regIndexOrMem(second);
                try self.byte(0xcb);
                try self.byte(0x40 | (@as(u8, @intCast(bit)) << 3) | target);
            },
            .cb_res => {
                const bit = try self.evalOperand(first);
                if (bit < 0 or bit > 7) return self.fail("bit number must be 0-7");
                const target = regIndexOrMem(second);
                try self.byte(0xcb);
                try self.byte(0x80 | (@as(u8, @intCast(bit)) << 3) | target);
            },
            .cb_set => {
                const bit = try self.evalOperand(first);
                if (bit < 0 or bit > 7) return self.fail("bit number must be 0-7");
                const target = regIndexOrMem(second);
                try self.byte(0xcb);
                try self.byte(0xc0 | (@as(u8, @intCast(bit)) << 3) | target);
            },
        }
    }

    // The last operand is the source when an ALU instruction omits the
    // accumulator, such as "xor $ff" instead of "xor a, $ff".
    fn lastOperand(_: *Assembler, operands: []const Operand) []const u8 {
        return std.mem.trim(u8, operands[operands.len - 1], " \t");
    }

    fn stripParens(_: *Assembler, operand: []const u8) []const u8 {
        const text = std.mem.trim(u8, operand, " \t");
        if (text.len >= 2 and text[0] == '(' and text[text.len - 1] == ')') {
            return std.mem.trim(u8, text[1 .. text.len - 1], " \t");
        }
        return text;
    }

    fn emitImm8(self: *Assembler, operand: []const u8) !void {
        const value = try self.evalOperand(operand);
        if (value < 0 or value > 0xff) return self.fail("byte value out of range");
        try self.byte(@intCast(value));
    }

    fn emitImm16(self: *Assembler, operand: []const u8) !void {
        const value = try self.evalOperand(operand);
        if (value < 0 or value > 0xffff) return self.fail("word value out of range");
        try self.word(@intCast(value));
    }

    fn emitJumpOffset(self: *Assembler, operand: []const u8, pc: usize) !void {
        const target = try self.evalOperand(operand);
        const offset = @as(i64, target) - @as(i64, @intCast(pc)) - 2;
        if (offset < -128 or offset > 127) return self.fail("jump target out of range");
        try self.byte(@bitCast(@as(i8, @intCast(offset))));
    }

    // Parses "sp+expr" or "sp-expr" as well as a plain signed expression.
    fn emitSigned(self: *Assembler, operand: []const u8, pc: usize) !void {
        const text = std.mem.trim(u8, operand, " \t");
        var value: i32 = 0;
        if (std.ascii.startsWithIgnoreCase(text, "sp")) {
            const rest = text[2..];
            const rest_trimmed = std.mem.trim(u8, rest, " \t");
            if (rest_trimmed.len == 0) return self.fail("missing signed offset");
            var index: usize = 0;
            var sign: i32 = 1;
            if (rest_trimmed[index] == '+' or rest_trimmed[index] == '-') {
                if (rest_trimmed[index] == '-') sign = -1;
                index += 1;
            }
            const body = rest_trimmed[index..];
            value = sign * (try self.evalExpr(body, pc));
        } else {
            value = try self.evalExpr(text, pc);
        }
        try self.signedByte(value);
    }
};

fn romSize(length: usize) usize {
    var size: usize = 0x8000;
    while (size < length) size *= 2;
    return size;
}

fn parseSource(allocator: std.mem.Allocator, source: []const u8) ![]ParsedLine {
    var lines: std.ArrayList(ParsedLine) = .empty;
    errdefer freeLines(allocator, lines.items);

    var iterator = std.mem.splitScalar(u8, source, '\n');
    while (iterator.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;

        var body = line;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (name.len != 0) {
                try lines.append(allocator, .{ .label = name });
                body = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (body.len == 0 or body[0] == ';') continue;
            }
        }

        const whitespace = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
        var token = body[0..whitespace];
        const rest = std.mem.trim(u8, body[whitespace..], " \t");
        if (token.len > 0 and token[0] == '.') token = token[1..];

        if (std.ascii.eqlIgnoreCase(token, "org")) {
            if (rest.len == 0) return error.BadDirective;
            try lines.append(allocator, .{ .org = rest });
        } else if (std.ascii.eqlIgnoreCase(token, "db") or std.ascii.eqlIgnoreCase(token, "dw")) {
            const operands = try splitOperands(allocator, rest);
            if (operands.len == 0) return error.BadDirective;
            if (std.ascii.eqlIgnoreCase(token, "db")) {
                try lines.append(allocator, .{ .db = operands });
            } else {
                try lines.append(allocator, .{ .dw = operands });
            }
        } else if (std.ascii.eqlIgnoreCase(token, "ds")) {
            if (rest.len == 0) return error.BadDirective;
            var directive: ParsedLine = undefined;
            if (std.mem.indexOfScalar(u8, rest, ',')) |comma| {
                const count = std.mem.trim(u8, rest[0..comma], " \t");
                const fill = std.mem.trim(u8, rest[comma + 1 ..], " \t");
                if (count.len == 0 or fill.len == 0) return error.BadDirective;
                directive = .{ .ds = .{ .count = count, .fill = fill } };
            } else {
                directive = .{ .ds = .{ .count = rest, .fill = null } };
            }
            try lines.append(allocator, directive);
        } else {
            if (token.len == 0) return error.BadDirective;
            const operands = try splitOperands(allocator, rest);
            try lines.append(allocator, .{ .instruction = .{ .mnemonic = token, .operands = operands } });
        }
    }

    return lines.toOwnedSlice(allocator);
}

fn freeLines(allocator: std.mem.Allocator, lines: []const ParsedLine) void {
    for (lines) |line| {
        switch (line) {
            .db, .dw => |operands| allocator.free(operands),
            .instruction => |instruction| allocator.free(instruction.operands),
            else => {},
        }
    }
    allocator.free(lines);
}

fn splitOperands(allocator: std.mem.Allocator, text: []const u8) ![]Operand {
    var operands: std.ArrayList(Operand) = .empty;
    errdefer operands.deinit(allocator);

    var start: usize = 0;
    var index: usize = 0;
    var quote: ?u8 = null;
    while (index < text.len) : (index += 1) {
        const ch = text[index];
        if (quote) |q| {
            if (ch == '\\' and q == '"') {
                index += 1;
                continue;
            }
            if (ch == q) quote = null;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == ',') {
            const operand = std.mem.trim(u8, text[start..index], " \t");
            if (operand.len == 0) return error.BadOperand;
            try operands.append(allocator, operand);
            start = index + 1;
        }
    }
    const last = std.mem.trim(u8, text[start..], " \t");
    if (last.len != 0) try operands.append(allocator, last);

    return operands.toOwnedSlice(allocator);
}

fn classifyOperand(operand: []const u8) OpClass {
    if (reg8Index(operand) != null) return .reg8;
    if (reg16Index(operand) != null) return .reg16;
    if (std.ascii.eqlIgnoreCase(operand, "af")) return .af;
    if (std.ascii.eqlIgnoreCase(operand, "(bc)")) return .mem_bc;
    if (std.ascii.eqlIgnoreCase(operand, "(de)")) return .mem_de;
    if (std.ascii.eqlIgnoreCase(operand, "(hl)")) return .mem_hl;
    if (std.ascii.eqlIgnoreCase(operand, "(hl+)")) return .mem_hl_inc;
    if (std.ascii.eqlIgnoreCase(operand, "(hl-)")) return .mem_hl_dec;
    if (std.ascii.eqlIgnoreCase(operand, "(c)")) return .mem_c;
    if (operand.len >= 2 and operand[0] == '(' and operand[operand.len - 1] == ')') return .mem_a16;
    if (condIndex(operand) != null) return .cond;
    return .other;
}

fn isRegA(operand: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, operand, " \t"), "a");
}

fn isRegHL(operand: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, operand, " \t"), "hl");
}

fn isRegSP(operand: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, operand, " \t"), "sp");
}

fn startsWithSp(operand: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(std.mem.trim(u8, operand, " \t"), "sp");
}

fn regIndexOrMem(operand: []const u8) u8 {
    if (classifyOperand(operand) == .mem_hl) return 6;
    return reg8Index(operand) orelse 0;
}

fn reg8Index(operand: []const u8) ?u3 {
    const t = std.mem.trim(u8, operand, " \t");
    if (std.ascii.eqlIgnoreCase(t, "b")) return 0;
    if (std.ascii.eqlIgnoreCase(t, "c")) return 1;
    if (std.ascii.eqlIgnoreCase(t, "d")) return 2;
    if (std.ascii.eqlIgnoreCase(t, "e")) return 3;
    if (std.ascii.eqlIgnoreCase(t, "h")) return 4;
    if (std.ascii.eqlIgnoreCase(t, "l")) return 5;
    if (std.ascii.eqlIgnoreCase(t, "a")) return 7;
    return null;
}

fn reg16Index(operand: []const u8) ?u2 {
    const t = std.mem.trim(u8, operand, " \t");
    if (std.ascii.eqlIgnoreCase(t, "bc")) return 0;
    if (std.ascii.eqlIgnoreCase(t, "de")) return 1;
    if (std.ascii.eqlIgnoreCase(t, "hl")) return 2;
    if (std.ascii.eqlIgnoreCase(t, "sp")) return 3;
    return null;
}

fn pairIndex(operand: []const u8) ?u2 {
    const t = std.mem.trim(u8, operand, " \t");
    if (std.ascii.eqlIgnoreCase(t, "bc")) return 0;
    if (std.ascii.eqlIgnoreCase(t, "de")) return 1;
    if (std.ascii.eqlIgnoreCase(t, "hl")) return 2;
    if (std.ascii.eqlIgnoreCase(t, "af")) return 3;
    return null;
}

fn condIndex(operand: []const u8) ?u2 {
    const t = std.mem.trim(u8, operand, " \t");
    if (std.ascii.eqlIgnoreCase(t, "nz")) return 0;
    if (std.ascii.eqlIgnoreCase(t, "z")) return 1;
    if (std.ascii.eqlIgnoreCase(t, "nc")) return 2;
    if (std.ascii.eqlIgnoreCase(t, "c")) return 3;
    return null;
}

fn aluIndex(mnemonic: []const u8) ?u3 {
    if (std.ascii.eqlIgnoreCase(mnemonic, "add")) return 0;
    if (std.ascii.eqlIgnoreCase(mnemonic, "adc")) return 1;
    if (std.ascii.eqlIgnoreCase(mnemonic, "sub")) return 2;
    if (std.ascii.eqlIgnoreCase(mnemonic, "sbc")) return 3;
    if (std.ascii.eqlIgnoreCase(mnemonic, "and")) return 4;
    if (std.ascii.eqlIgnoreCase(mnemonic, "xor")) return 5;
    if (std.ascii.eqlIgnoreCase(mnemonic, "or")) return 6;
    if (std.ascii.eqlIgnoreCase(mnemonic, "cp")) return 7;
    return null;
}

fn shiftIndex(mnemonic: []const u8) ?u3 {
    if (std.ascii.eqlIgnoreCase(mnemonic, "rlc")) return 0;
    if (std.ascii.eqlIgnoreCase(mnemonic, "rrc")) return 1;
    if (std.ascii.eqlIgnoreCase(mnemonic, "rl")) return 2;
    if (std.ascii.eqlIgnoreCase(mnemonic, "rr")) return 3;
    if (std.ascii.eqlIgnoreCase(mnemonic, "sla")) return 4;
    if (std.ascii.eqlIgnoreCase(mnemonic, "sra")) return 5;
    if (std.ascii.eqlIgnoreCase(mnemonic, "swap")) return 6;
    if (std.ascii.eqlIgnoreCase(mnemonic, "srl")) return 7;
    return null;
}

fn formLength(form: Form) usize {
    return switch (form) {
        .nop, .halt, .di, .ei, .daa, .cpl, .scf, .ccf, .rlca, .rrca, .rla, .rra, .reti, .ret, .ld_r8_r8, .ld_r8_hl, .ld_hl_r8, .ld_a_bc, .ld_a_de, .ld_bc_a, .ld_de_a, .ld_sp_hl, .ld_hl_inc_a, .ld_hl_dec_a, .ld_a_hl_inc, .ld_a_hl_dec, .ld_c_a, .ld_a_c, .inc_r8, .dec_r8, .inc_hl, .dec_hl, .inc_r16, .dec_r16, .add_hl_r16, .jp_hl, .ret_cc, .push_r16, .pop_r16, .rst_vec, .alu_a_r8 => 1,
        .stop, .ld_r8_imm8, .ld_hl_imm8, .ldh_a8_a, .ldh_a_a8, .add_sp_e8, .ld_hl_sp_e8, .alu_a_imm8, .cb_shift, .cb_bit, .cb_res, .cb_set, .jr_e8, .jr_cc_e8 => 2,
        .ld_a_a16, .ld_a16_a, .ld_r16_imm16, .ld_a16_sp, .jp_a16, .jp_cc_a16, .call_a16, .call_cc_a16 => 3,
    };
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

fn usage(program: []const u8) void {
    std.debug.print(
        \\gbasm - SM83 assembler for test ROMs
        \\Usage:
        \\  {s} <asm-directory> <output-directory>
        \\
        \\Assembles every .asm file in the source directory into a ROM
        \\image in the output directory. The output is deterministic.
        \\
    , .{program});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var argument_iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer argument_iterator.deinit();

    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    while (argument_iterator.next()) |arg| try arguments.append(allocator, arg);

    if (arguments.items.len != 3) {
        usage(if (arguments.items.len > 0) arguments.items[0] else "gbasm");
        std.process.exit(2);
    }

    const source_dir = arguments.items[1];
    const output_dir = arguments.items[2];

    var directory = std.Io.Dir.cwd().openDir(io, source_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("cannot open source directory {s}: {s}\n", .{ source_dir, @errorName(err) });
        std.process.exit(1);
    };
    defer directory.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    defer for (names.items) |name| allocator.free(name);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".asm")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var output = std.Io.Dir.cwd().openDir(io, output_dir, .{}) catch |err| {
        std.debug.print("cannot open output directory {s}: {s}\n", .{ output_dir, @errorName(err) });
        std.process.exit(1);
    };
    defer output.close(io);

    for (names.items) |name| {
        const source_path = try std.fs.path.join(allocator, &.{ source_dir, name });
        defer allocator.free(source_path);
        const source = readFile(io, allocator, source_path) catch |err| {
            std.debug.print("{s}: cannot read: {s}\n", .{ name, @errorName(err) });
            std.process.exit(1);
        };
        defer allocator.free(source);

        var assembler = Assembler{ .allocator = allocator };
        defer assembler.deinit();
        const rom = assembler.assemble(source) catch |err| {
            if (err == error.AssemblyFailed) {
                std.debug.print("{s}:{d}: {s}\n", .{ name, assembler.error_line, assembler.error_message });
            } else {
                std.debug.print("{s}:{d}: assembly error {s}\n", .{ name, assembler.error_line, @errorName(err) });
            }
            std.process.exit(1);
        };
        defer allocator.free(rom);

        const output_name = try std.fs.path.join(allocator, &.{ output_dir, std.fs.path.stem(name) });
        defer allocator.free(output_name);
        const rom_path = std.fmt.allocPrint(allocator, "{s}.gb", .{output_name}) catch return error.OutOfMemory;
        defer allocator.free(rom_path);

        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_path, .data = rom }) catch |err| {
            std.debug.print("{s}: cannot write: {s}\n", .{ rom_path, @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("assembled {s} -> {s} ({d} bytes)\n", .{ name, rom_path, rom.len });
    }
}

test "assembler encodes simple instructions" {
    const allocator = std.testing.allocator;
    var assembler = Assembler{ .allocator = allocator };
    defer assembler.deinit();

    const source =
        \\    org $0100
        \\    nop
        \\    ld a, $42
        \\    ld a, b
        \\    ld (hl), c
        \\    add a, d
        \\    xor $ff
        \\    ret
    ;
    const rom = try assembler.assemble(source);
    defer allocator.free(rom);

    const expected = [_]u8{
        0x00, // nop
        0x3e, 0x42, // ld a, $42
        0x78, // ld a, b
        0x71, // ld (hl), c
        0x82, // add a, d
        0xee, 0xff, // xor $ff
        0xc9, // ret
    };
    try std.testing.expectEqualSlices(u8, &expected, rom[0x0100 .. 0x0100 + expected.len]);
}

test "assembler resolves labels and jump offsets" {
    const allocator = std.testing.allocator;
    var assembler = Assembler{ .allocator = allocator };
    defer assembler.deinit();

    const source =
        \\    org $0100
        \\start:
        \\    jr start
        \\    jr nz, next
        \\    ld a, 1
        \\next:
        \\    jp start
    ;
    const rom = try assembler.assemble(source);
    defer allocator.free(rom);

    const expected = [_]u8{
        0x18, 0xfe, // jr start (offset -2)
        0x20, 0x02, // jr nz, next (skip 2 bytes)
        0x3e, 0x01, // ld a, 1
        0xc3, 0x00, 0x01, // jp start
    };
    try std.testing.expectEqualSlices(u8, &expected, rom[0x0100 .. 0x0100 + expected.len]);
}

test "assembler output is deterministic" {
    const allocator = std.testing.allocator;
    const source =
        \\    org $0100
        \\loop:
        \\    ld a, (hl+)
        \\    or a
        \\    jr nz, loop
        \\    db "hello", $0a
    ;
    var first = Assembler{ .allocator = allocator };
    defer first.deinit();
    const rom_a = try first.assemble(source);
    defer allocator.free(rom_a);

    var second = Assembler{ .allocator = allocator };
    defer second.deinit();
    const rom_b = try second.assemble(source);
    defer allocator.free(rom_b);

    try std.testing.expectEqualSlices(u8, rom_a, rom_b);
}

test "assembler emits a full-sized ROM" {
    const allocator = std.testing.allocator;
    var assembler = Assembler{ .allocator = allocator };
    defer assembler.deinit();
    const rom = try assembler.assemble("    org $0100\n    jp $0150\n");
    defer allocator.free(rom);
    try std.testing.expectEqual(@as(usize, 0x8000), rom.len);
}
