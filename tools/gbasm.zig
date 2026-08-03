const std = @import("std");

// gbasm - a two-pass assembler for the SM83 instruction set.
//
// gbasm turns a small assembly source into a raw ROM image. It is the
// build tool behind the bundled test fixtures. Each fixture in
// fixtures/asm/ has an assembly source, so a reviewer can read what a
// test ROM does and regenerate the exact bytes with `zig build fixtures`.
//
// Supported syntax:
//   - labels:      name:
//   - directives:  ORG addr, DB items, DW items, DS count[, fill],
//                  PAD addr, INCBIN "file", GBFIX, END
//   - expressions: numbers ($1F, 0x1F, %1010, 31, 1Fh, 'A') and labels
//                  combined with + and -
//   - comments:    ; to end of line
//
// A label reference may appear before the label is defined. ORG, PAD, and
// DS targets must be known when the assembler reaches them (no forward
// references in those directives). GBFIX writes the cartridge header
// checksum and its complement to $014D and $014E.

pub const Error = error{
    OutOfMemory,
    Syntax,
    OutOfRange,
    InvalidOperand,
    MissingOperand,
    TooManyOperands,
    UndefinedSymbol,
    DuplicateSymbol,
    UnsupportedMnemonic,
    BadImmediate,
    IncludeUnavailable,
    MaxSizeExceeded,
    Io,
};

pub const Image = struct {
    origin: u16,
    data: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

// ---------------------------------------------------------------------------
// Expression model
// ---------------------------------------------------------------------------

const Term = struct {
    symbol: ?[]const u8 = null,
    value: i64 = 0,
    negated: bool = false,
};

const Expr = struct {
    terms: []Term,

    fn isConstant(self: Expr) bool {
        for (self.terms) |term| {
            if (term.symbol != null) return false;
        }
        return true;
    }
};

const ParseError = Error;

fn isIdentStart(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '_';
}

fn isIdentCont(ch: u8) bool {
    return isIdentStart(ch) or (ch >= '0' and ch <= '9') or ch == '.';
}

const Number = struct { value: i64, len: usize };

fn readNumber(text: []const u8) ?Number {
    if (text.len == 0) return null;
    switch (text[0]) {
        '$' => {
            var value: i64 = 0;
            var index: usize = 1;
            while (index < text.len and std.ascii.isHex(text[index])) : (index += 1) {
                value = value * 16 + @as(i64, std.fmt.charToDigit(text[index], 16) catch return null);
            }
            if (index == 1) return null;
            return .{ .value = value, .len = index };
        },
        '%' => {
            var value: i64 = 0;
            var index: usize = 1;
            while (index < text.len and (text[index] == '0' or text[index] == '1')) : (index += 1) {
                value = value * 2 + (text[index] - '0');
            }
            if (index == 1) return null;
            return .{ .value = value, .len = index };
        },
        '\'' => {
            if (text.len < 3 or text[2] != '\'') return null;
            return .{ .value = text[1], .len = 3 };
        },
        else => {},
    }

    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        var value: i64 = 0;
        var index: usize = 2;
        while (index < text.len and std.ascii.isHex(text[index])) : (index += 1) {
            value = value * 16 + @as(i64, std.fmt.charToDigit(text[index], 16) catch return null);
        }
        if (index == 2) return null;
        return .{ .value = value, .len = index };
    }

    if (std.ascii.isDigit(text[0])) {
        var index: usize = 0;
        while (index < text.len and std.ascii.isHex(text[index])) : (index += 1) {}
        if (index < text.len and (text[index] == 'h' or text[index] == 'H')) {
            var value: i64 = 0;
            for (text[0..index]) |ch| value = value * 16 + @as(i64, std.fmt.charToDigit(ch, 16) catch return null);
            return .{ .value = value, .len = index + 1 };
        }
        var only_digits = true;
        for (text[0..index]) |ch| {
            if (!std.ascii.isDigit(ch)) only_digits = false;
        }
        if (!only_digits) return null;
        var value: i64 = 0;
        for (text[0..index]) |ch| value = value * 10 + (ch - '0');
        return .{ .value = value, .len = index };
    }
    return null;
}

const Parser = struct {
    allocator: std.mem.Allocator,

    fn readExpr(self: *Parser, text: []const u8, start: usize) ParseError!struct { expr: Expr, end: usize } {
        var terms: std.ArrayList(Term) = .empty;
        defer terms.deinit(self.allocator);

        var index = start;
        var negated = false;
        var saw_term = false;
        while (index < text.len) {
            const ch = text[index];
            if (ch == ' ') {
                index += 1;
                continue;
            }
            if (ch == '+' or ch == '-') {
                negated = (ch == '-');
                index += 1;
                continue;
            }
            if (isIdentStart(ch)) {
                const begin = index;
                while (index < text.len and isIdentCont(text[index])) : (index += 1) {}
                try terms.append(self.allocator, .{
                    .symbol = text[begin..index],
                    .negated = negated,
                });
                negated = false;
                saw_term = true;
                continue;
            }
            if (std.ascii.isDigit(ch) or ch == '$' or ch == '%' or ch == '\'') {
                const number = readNumber(text[index..]) orelse return error.Syntax;
                try terms.append(self.allocator, .{
                    .value = number.value,
                    .negated = negated,
                });
                index += number.len;
                negated = false;
                saw_term = true;
                continue;
            }
            break;
        }
        if (!saw_term) return error.Syntax;
        return .{ .expr = .{ .terms = try self.allocator.dupe(Term, terms.items) }, .end = index };
    }

    fn evaluate(self: *Parser, symbols: *std.StringHashMap(i64), expr: Expr) ParseError!i64 {
        _ = self;
        var total: i64 = 0;
        for (expr.terms) |term| {
            var value = term.value;
            if (term.symbol) |name| {
                value = symbols.get(name) orelse return error.UndefinedSymbol;
            }
            total += if (term.negated) -value else value;
        }
        return total;
    }
};

fn exprFromText(allocator: std.mem.Allocator, text: []const u8) ParseError!Expr {
    var parser = Parser{ .allocator = allocator };
    const result = try parser.readExpr(text, 0);
    if (result.end != text.len) return error.Syntax;
    return result.expr;
}

fn constantValue(expr: Expr) ?i64 {
    if (!expr.isConstant()) return null;
    var total: i64 = 0;
    for (expr.terms) |term| {
        total += if (term.negated) -term.value else term.value;
    }
    return total;
}

// ---------------------------------------------------------------------------
// Instruction encoding
// ---------------------------------------------------------------------------

const Instruction = struct {
    opcode: [2]u8 = .{ 0, 0 },
    opcount: u8 = 1,
    imm: ?Expr = null,
    imm_bytes: u8 = 0,
    relative: bool = false,

    fn size(self: Instruction) usize {
        return @as(usize, self.opcount) + self.imm_bytes;
    }
};

fn regIndex(operand: []const u8) ?u3 {
    if (std.mem.eql(u8, operand, "(HL)")) return 6;
    if (operand.len != 1) return null;
    return switch (operand[0]) {
        'B' => 0,
        'C' => 1,
        'D' => 2,
        'E' => 3,
        'H' => 4,
        'L' => 5,
        'A' => 7,
        else => null,
    };
}

fn r16Index(operand: []const u8) ?u3 {
    if (std.mem.eql(u8, operand, "BC")) return 0;
    if (std.mem.eql(u8, operand, "DE")) return 1;
    if (std.mem.eql(u8, operand, "HL")) return 2;
    if (std.mem.eql(u8, operand, "SP")) return 3;
    return null;
}

fn condIndex(operand: []const u8) ?u2 {
    if (std.mem.eql(u8, operand, "NZ")) return 0;
    if (std.mem.eql(u8, operand, "Z")) return 1;
    if (std.mem.eql(u8, operand, "NC")) return 2;
    if (std.mem.eql(u8, operand, "C")) return 3;
    return null;
}

fn isMem(operand: []const u8) bool {
    return operand.len >= 2 and operand[0] == '(' and operand[operand.len - 1] == ')';
}

fn isBare(operand: []const u8) bool {
    return !isMem(operand) and operand.len != 0;
}

fn immediateInstruction(opcode: u8, expr: Expr, imm_bytes: u8, relative: bool) Instruction {
    return .{ .opcode = .{ opcode, 0 }, .opcount = 1, .imm = expr, .imm_bytes = imm_bytes, .relative = relative };
}

fn plainInstruction(opcode: u8) Instruction {
    return .{ .opcode = .{ opcode, 0 }, .opcount = 1 };
}

fn cbInstruction(sub_opcode: u8) Instruction {
    return .{ .opcode = .{ 0xcb, sub_opcode }, .opcount = 2 };
}

fn aluImmediate(mnemonic: []const u8) ?u8 {
    if (std.mem.eql(u8, mnemonic, "add")) return 0xc6;
    if (std.mem.eql(u8, mnemonic, "adc")) return 0xce;
    if (std.mem.eql(u8, mnemonic, "sub")) return 0xd6;
    if (std.mem.eql(u8, mnemonic, "sbc")) return 0xde;
    if (std.mem.eql(u8, mnemonic, "and")) return 0xe6;
    if (std.mem.eql(u8, mnemonic, "xor")) return 0xee;
    if (std.mem.eql(u8, mnemonic, "or")) return 0xf6;
    if (std.mem.eql(u8, mnemonic, "cp")) return 0xfe;
    return null;
}

fn aluRegBase(mnemonic: []const u8) ?u8 {
    if (std.mem.eql(u8, mnemonic, "add")) return 0x80;
    if (std.mem.eql(u8, mnemonic, "adc")) return 0x88;
    if (std.mem.eql(u8, mnemonic, "sub")) return 0x90;
    if (std.mem.eql(u8, mnemonic, "sbc")) return 0x98;
    if (std.mem.eql(u8, mnemonic, "and")) return 0xa0;
    if (std.mem.eql(u8, mnemonic, "xor")) return 0xa8;
    if (std.mem.eql(u8, mnemonic, "or")) return 0xb0;
    if (std.mem.eql(u8, mnemonic, "cp")) return 0xb8;
    return null;
}

fn cbOperation(mnemonic: []const u8) ?u8 {
    if (std.mem.eql(u8, mnemonic, "rlc")) return 0;
    if (std.mem.eql(u8, mnemonic, "rrc")) return 1;
    if (std.mem.eql(u8, mnemonic, "rl")) return 2;
    if (std.mem.eql(u8, mnemonic, "rr")) return 3;
    if (std.mem.eql(u8, mnemonic, "sla")) return 4;
    if (std.mem.eql(u8, mnemonic, "sra")) return 5;
    if (std.mem.eql(u8, mnemonic, "swap")) return 6;
    if (std.mem.eql(u8, mnemonic, "srl")) return 7;
    return null;
}

fn encodeAlu(allocator: std.mem.Allocator, mnemonic: []const u8, ops: []const []const u8) ParseError!Instruction {
    const count = ops.len;
    const imm_opcode = aluImmediate(mnemonic).?;
    const reg_base = aluRegBase(mnemonic).?;

    if (count == 2 and std.mem.eql(u8, ops[0], "HL")) {
        if (!std.mem.eql(u8, mnemonic, "add")) return error.InvalidOperand;
        const index = r16Index(ops[1]) orelse return error.InvalidOperand;
        return plainInstruction(0x09 | @as(u8, index) << 4);
    }
    if (count == 2 and std.mem.eql(u8, ops[0], "SP")) {
        if (!std.mem.eql(u8, mnemonic, "add")) return error.InvalidOperand;
        if (isBare(ops[1])) {
            return .{ .opcode = .{ 0xe8, 0 }, .opcount = 1, .imm = try exprFromText(allocator, ops[1]), .imm_bytes = 1 };
        }
        return error.InvalidOperand;
    }

    if (count == 1) {
        if (regIndex(ops[0])) |index| {
            return plainInstruction(reg_base + @as(u8, index));
        }
        if (isBare(ops[0])) {
            return immediateInstruction(imm_opcode, try exprFromText(allocator, ops[0]), 1, false);
        }
        return error.InvalidOperand;
    }
    if (count == 2 and std.mem.eql(u8, ops[0], "A")) {
        if (regIndex(ops[1])) |index| {
            return plainInstruction(reg_base + @as(u8, index));
        }
        if (isBare(ops[1])) {
            return immediateInstruction(imm_opcode, try exprFromText(allocator, ops[1]), 1, false);
        }
        return error.InvalidOperand;
    }
    return error.InvalidOperand;
}

fn encodeLd(allocator: std.mem.Allocator, ops: []const []const u8) ParseError!Instruction {
    if (ops.len != 2) return error.InvalidOperand;
    const dst = ops[0];
    const src = ops[1];

    if (regIndex(dst)) |d_index| {
        if (regIndex(src)) |s_index| {
            return plainInstruction(0x40 | @as(u8, d_index) << 3 | @as(u8, s_index));
        }
        if (isBare(src)) {
            return immediateInstruction(0x06 | @as(u8, d_index) << 3, try exprFromText(allocator, src), 1, false);
        }
        // Only A can load from a memory operand.
        if (!std.mem.eql(u8, dst, "A")) return error.InvalidOperand;
        if (std.mem.eql(u8, src, "(BC)")) return plainInstruction(0x0a);
        if (std.mem.eql(u8, src, "(DE)")) return plainInstruction(0x1a);
        if (std.mem.eql(u8, src, "(HL+)")) return plainInstruction(0x2a);
        if (std.mem.eql(u8, src, "(HL-)")) return plainInstruction(0x3a);
        if (std.mem.eql(u8, src, "(C)")) return plainInstruction(0xf2);
        if (isMem(src)) {
            const inner = src[1 .. src.len - 1];
            return immediateInstruction(0xfa, try exprFromText(allocator, inner), 2, false);
        }
        return error.InvalidOperand;
    }

    if (std.mem.eql(u8, dst, "SP")) {
        if (std.mem.eql(u8, src, "HL")) return plainInstruction(0xf9);
        if (isBare(src)) {
            return immediateInstruction(0x31, try exprFromText(allocator, src), 2, false);
        }
        return error.InvalidOperand;
    }

    if (std.mem.eql(u8, dst, "HL") and std.mem.startsWith(u8, src, "SP") and src.len > 2) {
        const offset = src[2..];
        return .{ .opcode = .{ 0xf8, 0 }, .opcount = 1, .imm = try exprFromText(allocator, offset), .imm_bytes = 1 };
    }

    if (r16Index(dst)) |d_index| {
        if (isBare(src)) {
            return immediateInstruction(0x01 | @as(u8, d_index) << 4, try exprFromText(allocator, src), 2, false);
        }
        return error.InvalidOperand;
    }

    if (std.mem.eql(u8, src, "A")) {
        if (std.mem.eql(u8, dst, "(BC)")) return plainInstruction(0x02);
        if (std.mem.eql(u8, dst, "(DE)")) return plainInstruction(0x12);
        if (std.mem.eql(u8, dst, "(HL+)")) return plainInstruction(0x22);
        if (std.mem.eql(u8, dst, "(HL-)")) return plainInstruction(0x32);
        if (std.mem.eql(u8, dst, "(C)")) return plainInstruction(0xe2);
        if (isMem(dst)) {
            const inner = dst[1 .. dst.len - 1];
            return immediateInstruction(0xea, try exprFromText(allocator, inner), 2, false);
        }
        return error.InvalidOperand;
    }

    if (isMem(dst) and std.mem.eql(u8, src, "SP")) {
        const inner = dst[1 .. dst.len - 1];
        return immediateInstruction(0x08, try exprFromText(allocator, inner), 2, false);
    }

    return error.InvalidOperand;
}

fn encodeLdh(allocator: std.mem.Allocator, ops: []const []const u8) ParseError!Instruction {
    if (ops.len != 2) return error.InvalidOperand;
    if (std.mem.eql(u8, ops[1], "A") and isMem(ops[0])) {
        const inner = ops[0][1 .. ops[0].len - 1];
        return immediateInstruction(0xe0, try exprFromText(allocator, inner), 1, false);
    }
    if (std.mem.eql(u8, ops[0], "A") and isMem(ops[1])) {
        const inner = ops[1][1 .. ops[1].len - 1];
        return immediateInstruction(0xf0, try exprFromText(allocator, inner), 1, false);
    }
    return error.InvalidOperand;
}

fn encodeIncDec(ops: []const []const u8, is_inc: bool) ParseError!Instruction {
    if (ops.len != 1) return error.InvalidOperand;
    if (regIndex(ops[0])) |index| {
        const base: u8 = if (is_inc) 0x04 else 0x05;
        return plainInstruction(base | @as(u8, index) << 3);
    }
    if (r16Index(ops[0])) |index| {
        const base: u8 = if (is_inc) 0x03 else 0x0b;
        return plainInstruction(base | @as(u8, index) << 4);
    }
    return error.InvalidOperand;
}

fn encodePushPop(ops: []const []const u8, is_push: bool) ParseError!Instruction {
    if (ops.len != 1) return error.InvalidOperand;
    const base: u8 = if (is_push) 0xc5 else 0xc1;
    if (std.mem.eql(u8, ops[0], "AF")) return plainInstruction(base + 0x30);
    if (std.mem.eql(u8, ops[0], "SP")) return error.InvalidOperand;
    if (r16Index(ops[0])) |index| {
        return plainInstruction(base + (@as(u8, index) << 4));
    }
    return error.InvalidOperand;
}

fn encodeJp(allocator: std.mem.Allocator, ops: []const []const u8) ParseError!Instruction {
    if (ops.len == 1) {
        if (std.mem.eql(u8, ops[0], "(HL)") or std.mem.eql(u8, ops[0], "HL")) return plainInstruction(0xe9);
        if (isBare(ops[0])) return immediateInstruction(0xc3, try exprFromText(allocator, ops[0]), 2, false);
        return error.InvalidOperand;
    }
    if (ops.len == 2) {
        const condition = condIndex(ops[0]) orelse return error.InvalidOperand;
        if (isBare(ops[1])) {
            return immediateInstruction(@intCast(0xc2 | @as(u8, condition) << 3), try exprFromText(allocator, ops[1]), 2, false);
        }
        return error.InvalidOperand;
    }
    return error.InvalidOperand;
}

fn encodeJr(allocator: std.mem.Allocator, ops: []const []const u8) ParseError!Instruction {
    if (ops.len == 1) {
        if (isBare(ops[0])) return immediateInstruction(0x18, try exprFromText(allocator, ops[0]), 1, true);
        return error.InvalidOperand;
    }
    if (ops.len == 2) {
        const condition = condIndex(ops[0]) orelse return error.InvalidOperand;
        if (isBare(ops[1])) {
            return immediateInstruction(@intCast(0x20 | @as(u8, condition) << 3), try exprFromText(allocator, ops[1]), 1, true);
        }
        return error.InvalidOperand;
    }
    return error.InvalidOperand;
}

fn encodeCall(allocator: std.mem.Allocator, ops: []const []const u8) ParseError!Instruction {
    if (ops.len == 1) {
        if (isBare(ops[0])) return immediateInstruction(0xcd, try exprFromText(allocator, ops[0]), 2, false);
        return error.InvalidOperand;
    }
    if (ops.len == 2) {
        const condition = condIndex(ops[0]) orelse return error.InvalidOperand;
        if (isBare(ops[1])) {
            return immediateInstruction(@intCast(0xc4 | @as(u8, condition) << 3), try exprFromText(allocator, ops[1]), 2, false);
        }
        return error.InvalidOperand;
    }
    return error.InvalidOperand;
}

fn encodeRet(ops: []const []const u8) ParseError!Instruction {
    if (ops.len == 0) return plainInstruction(0xc9);
    if (ops.len == 1) {
        const condition = condIndex(ops[0]) orelse return error.InvalidOperand;
        return plainInstruction(@intCast(0xc0 | @as(u8, condition) << 3));
    }
    return error.InvalidOperand;
}

fn encodeRst(allocator: std.mem.Allocator, ops: []const []const u8) ParseError!Instruction {
    if (ops.len != 1) return error.InvalidOperand;
    if (isBare(ops[0])) {
        const expression = try exprFromText(allocator, ops[0]);
        const value = constantValue(expression) orelse return error.InvalidOperand;
        if (value < 0 or value > 0xff or (value & 0x07) != 0) return error.InvalidOperand;
        return plainInstruction(@intCast(0xc7 + @as(u8, @intCast(value))));
    }
    return error.InvalidOperand;
}

// Operands arrive pre-split on top-level commas and trimmed.
fn encodeInstruction(allocator: std.mem.Allocator, mnemonic: []const u8, operands: []const []const u8) ParseError!Instruction {
    const count = operands.len;

    if (count == 0) {
        const zero_operand_ops = [_][]const u8{ "nop", "halt", "stop", "di", "ei", "ret", "reti", "rlca", "rrca", "rla", "rra", "daa", "cpl", "scf", "ccf" };
        const zero_operand_codes = [_]u8{ 0x00, 0x76, 0x10, 0xf3, 0xfb, 0xc9, 0xd9, 0x07, 0x0f, 0x17, 0x1f, 0x27, 0x2f, 0x37, 0x3f };
        for (zero_operand_ops, zero_operand_codes) |name, opcode| {
            if (std.mem.eql(u8, mnemonic, name)) return plainInstruction(opcode);
        }
        return error.UnsupportedMnemonic;
    }

    if (aluImmediate(mnemonic) != null) return encodeAlu(allocator, mnemonic, operands);
    if (std.mem.eql(u8, mnemonic, "ld")) return encodeLd(allocator, operands);
    if (std.mem.eql(u8, mnemonic, "ldh")) return encodeLdh(allocator, operands);
    if (std.mem.eql(u8, mnemonic, "inc")) return encodeIncDec(operands, true);
    if (std.mem.eql(u8, mnemonic, "dec")) return encodeIncDec(operands, false);
    if (std.mem.eql(u8, mnemonic, "push")) return encodePushPop(operands, true);
    if (std.mem.eql(u8, mnemonic, "pop")) return encodePushPop(operands, false);
    if (std.mem.eql(u8, mnemonic, "jp")) return encodeJp(allocator, operands);
    if (std.mem.eql(u8, mnemonic, "jr")) return encodeJr(allocator, operands);
    if (std.mem.eql(u8, mnemonic, "call")) return encodeCall(allocator, operands);
    if (std.mem.eql(u8, mnemonic, "ret")) return encodeRet(operands);
    if (std.mem.eql(u8, mnemonic, "rst")) return encodeRst(allocator, operands);

    if (cbOperation(mnemonic)) |operation| {
        if (count != 1) return error.InvalidOperand;
        const index = regIndex(operands[0]) orelse return error.InvalidOperand;
        return cbInstruction(operation << 3 | @as(u8, index));
    }
    if (std.mem.eql(u8, mnemonic, "bit") or std.mem.eql(u8, mnemonic, "res") or std.mem.eql(u8, mnemonic, "set")) {
        if (count != 2) return error.InvalidOperand;
        const bit_expr = try exprFromText(allocator, operands[0]);
        const bit = constantValue(bit_expr) orelse return error.InvalidOperand;
        if (bit < 0 or bit > 7) return error.InvalidOperand;
        const index = regIndex(operands[1]) orelse return error.InvalidOperand;
        const base: u8 = if (std.mem.eql(u8, mnemonic, "bit")) 0x40 else if (std.mem.eql(u8, mnemonic, "res")) 0x80 else 0xc0;
        return cbInstruction(base | @as(u8, @intCast(bit)) << 3 | @as(u8, index));
    }

    return error.UnsupportedMnemonic;
}

// ---------------------------------------------------------------------------
// Statement model
// ---------------------------------------------------------------------------

const DbItem = union(enum) {
    expr: Expr,
    string: []const u8,
};

const Statement = union(enum) {
    none: void,
    org: Expr,
    db: []const DbItem,
    dw: []const Expr,
    ds: struct { count: Expr, value: ?Expr },
    pad: Expr,
    gbfix: void,
    incbin: []const u8,
    end: void,
    instr: Instruction,
};

const Line = struct {
    label: ?[]const u8 = null,
    stmt: Statement,
    number: usize,
};

const SourceParser = struct {
    allocator: std.mem.Allocator,

    fn stripComment(text: []const u8) []const u8 {
        var in_string: ?u8 = null;
        for (text, 0..) |ch, i| {
            if (in_string != null) {
                if (ch == in_string.?) in_string = null;
                continue;
            }
            if (ch == '\'' or ch == '"') {
                in_string = ch;
                continue;
            }
            if (ch == ';') return text[0..i];
        }
        return text;
    }

    fn firstToken(text: []const u8) struct { token: []const u8, rest: []const u8 } {
        var index: usize = 0;
        while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
        const begin = index;
        while (index < text.len and text[index] != ' ' and text[index] != '\t') : (index += 1) {}
        return .{ .token = text[begin..index], .rest = std.mem.trim(u8, text[index..], " \t") };
    }

    fn splitOperands(self: *SourceParser, text: []const u8) ParseError![][]const u8 {
        if (text.len == 0) return self.allocator.alloc([]const u8, 0);
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.allocator);
        var depth: usize = 0;
        var start: usize = 0;
        var in_string: ?u8 = null;
        for (text, 0..) |ch, i| {
            switch (ch) {
                '(' => depth += 1,
                ')' => depth = if (depth == 0) 0 else depth - 1,
                '\'', '"' => {
                    if (in_string == null) {
                        in_string = ch;
                    } else if (in_string.? == ch) {
                        in_string = null;
                    }
                },
                ',' => if (depth == 0 and in_string == null) {
                    const part = std.mem.trim(u8, text[start..i], " \t");
                    if (part.len == 0) return error.Syntax;
                    try parts.append(self.allocator, part);
                    start = i + 1;
                },
                else => {},
            }
        }
        if (in_string != null) return error.Syntax;
        const last = std.mem.trim(u8, text[start..], " \t");
        if (last.len == 0) return error.Syntax;
        try parts.append(self.allocator, last);
        return try self.allocator.dupe([]const u8, parts.items);
    }

    fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
        }
        return true;
    }

    fn parseLine(self: *SourceParser, line_number: usize, raw: []const u8) ParseError!?Line {
        var text = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (text.len == 0) return null;

        var label: ?[]const u8 = null;
        {
            var depth: usize = 0;
            var in_string: ?u8 = null;
            for (text, 0..) |ch, i| {
                switch (ch) {
                    '(' => depth += 1,
                    ')' => depth = if (depth == 0) 0 else depth - 1,
                    '\'', '"' => {
                        if (in_string == null) {
                            in_string = ch;
                        } else if (in_string.? == ch) {
                            in_string = null;
                        }
                    },
                    ':' => if (depth == 0 and in_string == null) {
                        label = std.mem.trim(u8, text[0..i], " \t");
                        text = std.mem.trim(u8, text[i + 1 ..], " \t");
                        break;
                    },
                    else => {},
                }
            }
        }

        if (text.len == 0) {
            if (label == null) return error.Syntax;
            return .{ .label = label, .stmt = .{ .none = {} }, .number = line_number };
        }

        const first = firstToken(text);
        const keyword = first.token;
        const rest = first.rest;

        if (eqIgnoreCase(keyword, "org")) {
            return .{ .label = label, .stmt = .{ .org = try exprFromText(self.allocator, rest) }, .number = line_number };
        }
        if (eqIgnoreCase(keyword, "db")) {
            var items: std.ArrayList(DbItem) = .empty;
            defer items.deinit(self.allocator);
            const list = try self.splitOperands(rest);
            for (list) |item| {
                if (item.len >= 2 and item[0] == '"' and item[item.len - 1] == '"') {
                    try items.append(self.allocator, .{ .string = item[1 .. item.len - 1] });
                } else {
                    try items.append(self.allocator, .{ .expr = try exprFromText(self.allocator, item) });
                }
            }
            return .{ .label = label, .stmt = .{ .db = try self.allocator.dupe(DbItem, items.items) }, .number = line_number };
        }
        if (eqIgnoreCase(keyword, "dw")) {
            var expressions: std.ArrayList(Expr) = .empty;
            defer expressions.deinit(self.allocator);
            const list = try self.splitOperands(rest);
            for (list) |item| {
                try expressions.append(self.allocator, try exprFromText(self.allocator, item));
            }
            return .{ .label = label, .stmt = .{ .dw = try self.allocator.dupe(Expr, expressions.items) }, .number = line_number };
        }
        if (eqIgnoreCase(keyword, "ds")) {
            const list = try self.splitOperands(rest);
            if (list.len < 1 or list.len > 2) return error.InvalidOperand;
            const value: ?Expr = if (list.len == 2) try exprFromText(self.allocator, list[1]) else null;
            return .{ .label = label, .stmt = .{ .ds = .{ .count = try exprFromText(self.allocator, list[0]), .value = value } }, .number = line_number };
        }
        if (eqIgnoreCase(keyword, "pad")) {
            return .{ .label = label, .stmt = .{ .pad = try exprFromText(self.allocator, rest) }, .number = line_number };
        }
        if (eqIgnoreCase(keyword, "gbfix")) {
            if (rest.len != 0) return error.InvalidOperand;
            return .{ .label = label, .stmt = .{ .gbfix = {} }, .number = line_number };
        }
        if (eqIgnoreCase(keyword, "incbin")) {
            const path = std.mem.trim(u8, rest, " \t\"");
            if (path.len == 0) return error.InvalidOperand;
            return .{ .label = label, .stmt = .{ .incbin = path }, .number = line_number };
        }
        if (eqIgnoreCase(keyword, "end")) {
            if (rest.len != 0) return error.InvalidOperand;
            return .{ .label = label, .stmt = .{ .end = {} }, .number = line_number };
        }

        const operands = try self.splitOperands(rest);
        const lower = try self.allocator.dupe(u8, keyword);
        for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
        const instruction = try encodeInstruction(self.allocator, lower, operands);
        return .{ .label = label, .stmt = .{ .instr = instruction }, .number = line_number };
    }
};

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

const ImageBuilder = struct {
    allocator: std.mem.Allocator,
    base: u16,
    data: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator, base: u16) ImageBuilder {
        return .{ .allocator = allocator, .base = base, .data = .empty };
    }

    fn emit(self: *ImageBuilder, address: u16, value: u8) Error!void {
        if (address < self.base) return error.OutOfRange;
        const offset: usize = address - self.base;
        while (self.data.items.len < offset + 1) try self.data.append(self.allocator, 0);
        self.data.items[offset] = value;
    }

    fn byteAt(self: *ImageBuilder, address: u16) u8 {
        const offset: usize = address - self.base;
        if (offset >= self.data.items.len) return 0;
        return self.data.items[offset];
    }
};

fn checkPc(pc: u32) Error!void {
    if (pc > 0xffff) return error.MaxSizeExceeded;
}

fn readInclude(io: std.Io, allocator: std.mem.Allocator, source_dir: []const u8, path: []const u8) Error![]u8 {
    var path_buffer: std.ArrayList(u8) = .empty;
    defer path_buffer.deinit(allocator);
    try path_buffer.appendSlice(allocator, source_dir);
    try path_buffer.append(allocator, '/');
    try path_buffer.appendSlice(allocator, path);
    const dir = std.Io.Dir.cwd();
    const file = dir.openFile(io, path_buffer.items, .{}) catch return error.Io;
    defer file.close(io);
    const size = file.length(io) catch return error.Io;
    const contents = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(contents);
    _ = file.readPositionalAll(io, contents, 0) catch return error.Io;
    return contents;
}

pub fn assemble(io: std.Io, allocator: std.mem.Allocator, source: []const u8, source_dir: ?[]const u8) Error!Image {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(arena);

    var raw_lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 1;
    while (raw_lines.next()) |raw| {
        var parser = SourceParser{ .allocator = arena };
        if (try parser.parseLine(line_number, raw)) |line| {
            try lines.append(arena, line);
            if (line.stmt == .end) break;
        }
        line_number += 1;
    }

    var symbols = std.StringHashMap(i64).init(arena);
    var origin: ?u16 = null;
    var pc: u32 = 0;

    // Pass 1: record label addresses and validate sizes. ORG, PAD, and DS
    // evaluate against the symbols seen so far.
    for (lines.items) |line| {
        if (line.label) |name| {
            if (symbols.contains(name)) return error.DuplicateSymbol;
            try symbols.put(name, pc);
        }
        const stmt = line.stmt;
        switch (stmt) {
            .org => |expression| {
                var parser = Parser{ .allocator = arena };
                const value = try parser.evaluate(&symbols, expression);
                if (value < 0 or value > 0xffff) return error.OutOfRange;
                const target: u16 = @intCast(value);
                if (origin == null) {
                    origin = target;
                    pc = target;
                } else {
                    if (target < origin.?) return error.OutOfRange;
                    pc = target;
                }
            },
            .pad => |expression| {
                var parser = Parser{ .allocator = arena };
                const target = try parser.evaluate(&symbols, expression);
                if (target < pc or target > 0xffff) return error.OutOfRange;
                pc = @intCast(target);
            },
            .ds => |fill| {
                var parser = Parser{ .allocator = arena };
                const count = try parser.evaluate(&symbols, fill.count);
                if (count < 0) return error.OutOfRange;
                pc += @as(u32, @intCast(count));
                try checkPc(pc);
            },
            .db => |items| {
                var size: usize = 0;
                for (items) |item| {
                    size += switch (item) {
                        .expr => 1,
                        .string => |s| s.len,
                    };
                }
                pc += @intCast(size);
                try checkPc(pc);
            },
            .dw => |items| {
                pc += @intCast(items.len * 2);
                try checkPc(pc);
            },
            .instr => |instruction| {
                pc += @intCast(instruction.size());
                try checkPc(pc);
            },
            .incbin => |path| {
                if (source_dir == null) return error.IncludeUnavailable;
                const contents = try readInclude(io, allocator, source_dir.?, path);
                defer allocator.free(contents);
                pc += @intCast(contents.len);
                try checkPc(pc);
            },
            .gbfix, .none, .end => {},
        }
    }

    const base = origin orelse return error.Syntax;
    var builder = ImageBuilder.init(allocator, base);
    defer builder.data.deinit(allocator);

    pc = base;
    for (lines.items) |line| {
        const stmt = line.stmt;
        switch (stmt) {
            .org => |expression| {
                var parser = Parser{ .allocator = arena };
                const value = try parser.evaluate(&symbols, expression);
                pc = @intCast(value);
            },
            .pad => |expression| {
                var parser = Parser{ .allocator = arena };
                const target = try parser.evaluate(&symbols, expression);
                const gap = @as(usize, @intCast(target)) - @as(usize, pc);
                for (0..gap) |_| {
                    try builder.emit(@intCast(pc), 0);
                    pc += 1;
                }
                pc = @intCast(target);
            },
            .ds => |fill| {
                var parser = Parser{ .allocator = arena };
                const count = try parser.evaluate(&symbols, fill.count);
                const value: u8 = if (fill.value) |fill_expr| blk: {
                    const raw = try parser.evaluate(&symbols, fill_expr);
                    break :blk @intCast(@as(u8, @truncate(@as(u64, @bitCast(raw)))));
                } else 0;
                for (0..@as(usize, @intCast(count))) |_| {
                    try builder.emit(@intCast(pc), value);
                    pc += 1;
                }
            },
            .db => |items| {
                var parser = Parser{ .allocator = arena };
                for (items) |item| {
                    switch (item) {
                        .expr => |expression| {
                            const value = try parser.evaluate(&symbols, expression);
                            if (value < -128 or value > 255) return error.BadImmediate;
                            try builder.emit(@intCast(pc), @truncate(@as(u64, @bitCast(value))));
                            pc += 1;
                        },
                        .string => |s| {
                            for (s) |ch| {
                                try builder.emit(@intCast(pc), ch);
                                pc += 1;
                            }
                        },
                    }
                }
            },
            .dw => |items| {
                var parser = Parser{ .allocator = arena };
                for (items) |expression| {
                    const value = try parser.evaluate(&symbols, expression);
                    if (value < 0 or value > 0xffff) return error.BadImmediate;
                    try builder.emit(@intCast(pc), @as(u8, @intCast(value & 0xff)));
                    try builder.emit(@intCast(pc + 1), @as(u8, @intCast((value >> 8) & 0xff)));
                    pc += 2;
                }
            },
            .instr => |instruction| {
                try builder.emit(@intCast(pc), instruction.opcode[0]);
                if (instruction.opcount == 2) try builder.emit(@intCast(pc + 1), instruction.opcode[1]);
                const start = pc;
                pc += @intCast(instruction.size());
                if (instruction.imm) |expression| {
                    var parser = Parser{ .allocator = arena };
                    const value = try parser.evaluate(&symbols, expression);
                    const imm_address = start + @as(u32, instruction.opcount);
                    if (instruction.relative) {
                        const offset = value - @as(i64, start) - @as(i64, @intCast(instruction.size()));
                        if (offset < -128 or offset > 127) return error.BadImmediate;
                        try builder.emit(@intCast(imm_address), @bitCast(@as(i8, @intCast(offset))));
                    } else if (instruction.imm_bytes == 1) {
                        if (value < -128 or value > 255) return error.BadImmediate;
                        try builder.emit(@intCast(imm_address), @truncate(@as(u64, @bitCast(value))));
                    } else {
                        if (value < 0 or value > 0xffff) return error.BadImmediate;
                        try builder.emit(@intCast(imm_address), @as(u8, @intCast(value & 0xff)));
                        try builder.emit(@intCast(imm_address + 1), @as(u8, @intCast((value >> 8) & 0xff)));
                    }
                }
            },
            .incbin => |path| {
                if (source_dir == null) return error.IncludeUnavailable;
                const contents = try readInclude(io, allocator, source_dir.?, path);
                defer allocator.free(contents);
                for (contents) |byte| {
                    try builder.emit(@intCast(pc), byte);
                    pc += 1;
                }
            },
            .gbfix => try fixHeaderChecksum(&builder),
            .none => {},
            .end => break,
        }
    }

    const data = try allocator.dupe(u8, builder.data.items);
    return .{ .origin = base, .data = data };
}

fn fixHeaderChecksum(builder: *ImageBuilder) Error!void {
    if (builder.base > 0x014c) return;
    var checksum: u8 = 0;
    for (0x134..0x14d) |address| {
        checksum = checksum -% builder.byteAt(@intCast(address)) -% 1;
    }
    try builder.emit(0x14d, checksum);
    try builder.emit(0x14e, checksum ^ 0xff);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;
const testing_io = t.io;

fn assembleString(allocator: std.mem.Allocator, source: []const u8) !Image {
    return assemble(testing_io, allocator, source, null);
}

test "layout of DB DW DS PAD and ORG" {
    const allocator = t.allocator;
    const source =
        \\    ORG $0100
        \\    DB $01, $02
        \\    DW $1234
        \\    DS 2, $AA
        \\    PAD $0108
        \\    DB "Z"
        \\    PAD $8000
    ;
    var image = try assembleString(allocator, source);
    defer image.deinit(allocator);
    try t.expectEqual(@as(u16, 0x0100), image.origin);
    try t.expectEqual(@as(usize, 0x7f00), image.data.len);
    try t.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x34, 0x12, 0xaa, 0xaa }, image.data[0..6]);
    try t.expectEqual(@as(u8, 'Z'), image.data[0x08]);
}

test "labels support forward references and relative jumps" {
    const allocator = t.allocator;
    const source =
        \\    ORG $0150
        \\start:
        \\    JR skip
        \\    LD A,$00
        \\skip:
        \\    LD A,$42
        \\    JR start
        \\    PAD $8000
    ;
    var image = try assembleString(allocator, source);
    defer image.deinit(allocator);
    try t.expectEqualSlices(u8, &.{ 0x18, 0x02 }, image.data[0..2]);
    try t.expectEqual(@as(u8, 0x3e), image.data[2]);
    try t.expectEqual(@as(u8, 0x00), image.data[3]);
    try t.expectEqual(@as(u8, 0x3e), image.data[4]);
    try t.expectEqual(@as(u8, 0x42), image.data[5]);
    try t.expectEqualSlices(u8, &.{ 0x18, 0xf8 }, image.data[6..8]);
}

test "instruction encodings match the SM83 opcode map" {
    const allocator = t.allocator;
    const cases = [_]struct { source: []const u8, bytes: []const u8 }{
        .{ .source = "NOP", .bytes = &.{0x00} },
        .{ .source = "LD A,B", .bytes = &.{0x78} },
        .{ .source = "LD (HL),A", .bytes = &.{0x77} },
        .{ .source = "LD A,(HL)", .bytes = &.{0x7e} },
        .{ .source = "LD (HL),$42", .bytes = &.{ 0x36, 0x42 } },
        .{ .source = "LD B,$12", .bytes = &.{ 0x06, 0x12 } },
        .{ .source = "LD BC,$1234", .bytes = &.{ 0x01, 0x34, 0x12 } },
        .{ .source = "LD SP,$FFFE", .bytes = &.{ 0x31, 0xfe, 0xff } },
        .{ .source = "LD (BC),A", .bytes = &.{0x02} },
        .{ .source = "LD A,(DE)", .bytes = &.{0x1a} },
        .{ .source = "LD (HL+),A", .bytes = &.{0x22} },
        .{ .source = "LD A,(HL-)", .bytes = &.{0x3a} },
        .{ .source = "LD (C),A", .bytes = &.{0xe2} },
        .{ .source = "LD A,(C)", .bytes = &.{0xf2} },
        .{ .source = "LD ($C000),A", .bytes = &.{ 0xea, 0x00, 0xc0 } },
        .{ .source = "LD A,($C000)", .bytes = &.{ 0xfa, 0x00, 0xc0 } },
        .{ .source = "LD ($2000),SP", .bytes = &.{ 0x08, 0x00, 0x20 } },
        .{ .source = "LDH ($02),A", .bytes = &.{ 0xe0, 0x02 } },
        .{ .source = "LDH A,($01)", .bytes = &.{ 0xf0, 0x01 } },
        .{ .source = "LD SP,HL", .bytes = &.{0xf9} },
        .{ .source = "ADD A,B", .bytes = &.{0x80} },
        .{ .source = "ADD B", .bytes = &.{0x80} },
        .{ .source = "ADD A,$21", .bytes = &.{ 0xc6, 0x21 } },
        .{ .source = "ADC A,H", .bytes = &.{0x8c} },
        .{ .source = "SUB B", .bytes = &.{0x90} },
        .{ .source = "SBC A,(HL)", .bytes = &.{0x9e} },
        .{ .source = "AND $0F", .bytes = &.{ 0xe6, 0x0f } },
        .{ .source = "XOR A", .bytes = &.{0xaf} },
        .{ .source = "OR A", .bytes = &.{0xb7} },
        .{ .source = "CP $33", .bytes = &.{ 0xfe, 0x33 } },
        .{ .source = "ADD HL,BC", .bytes = &.{0x09} },
        .{ .source = "ADD HL,SP", .bytes = &.{0x39} },
        .{ .source = "ADD SP,-2", .bytes = &.{ 0xe8, 0xfe } },
        .{ .source = "INC B", .bytes = &.{0x04} },
        .{ .source = "INC BC", .bytes = &.{0x03} },
        .{ .source = "DEC (HL)", .bytes = &.{0x35} },
        .{ .source = "DEC SP", .bytes = &.{0x3b} },
        .{ .source = "PUSH AF", .bytes = &.{0xf5} },
        .{ .source = "PUSH BC", .bytes = &.{0xc5} },
        .{ .source = "POP HL", .bytes = &.{0xe1} },
        .{ .source = "JP HL", .bytes = &.{0xe9} },
        .{ .source = "JP (HL)", .bytes = &.{0xe9} },
        .{ .source = "JP NZ,$1234", .bytes = &.{ 0xc2, 0x34, 0x12 } },
        .{ .source = "JP $1234", .bytes = &.{ 0xc3, 0x34, 0x12 } },
        .{ .source = "CALL NC,$1234", .bytes = &.{ 0xd4, 0x34, 0x12 } },
        .{ .source = "RET Z", .bytes = &.{0xc8} },
        .{ .source = "RETI", .bytes = &.{0xd9} },
        .{ .source = "RST $38", .bytes = &.{0xff} },
        .{ .source = "RST $18", .bytes = &.{0xdf} },
        .{ .source = "RLC B", .bytes = &.{ 0xcb, 0x00 } },
        .{ .source = "SRL A", .bytes = &.{ 0xcb, 0x3f } },
        .{ .source = "BIT 3,(HL)", .bytes = &.{ 0xcb, 0x5e } },
        .{ .source = "RES 0,A", .bytes = &.{ 0xcb, 0x87 } },
        .{ .source = "SET 7,A", .bytes = &.{ 0xcb, 0xff } },
        .{ .source = "EI", .bytes = &.{0xfb} },
        .{ .source = "DI", .bytes = &.{0xf3} },
        .{ .source = "HALT", .bytes = &.{0x76} },
        .{ .source = "STOP", .bytes = &.{0x10} },
        .{ .source = "RLCA", .bytes = &.{0x07} },
        .{ .source = "CCF", .bytes = &.{0x3f} },
        .{ .source = "DAA", .bytes = &.{0x27} },
    };
    for (cases) |case| {
        const wrapped = try std.fmt.allocPrint(allocator, "    ORG $0100\n    {s}\n    PAD $8000\n", .{case.source});
        defer allocator.free(wrapped);
        var image = try assembleString(allocator, wrapped);
        defer image.deinit(allocator);
        try t.expectEqualSlices(u8, case.bytes, image.data[0..case.bytes.len]);
    }
}

test "relative jump encodes from labels" {
    const allocator = t.allocator;
    const source =
        \\    ORG $0100
        \\    JR target
        \\    ORG $0120
        \\target:
        \\    JR start
        \\start:
        \\    NOP
        \\    PAD $8000
    ;
    var image = try assembleString(allocator, source);
    defer image.deinit(allocator);
    try t.expectEqualSlices(u8, &.{ 0x18, 0x1e }, image.data[0..2]);
    try t.expectEqualSlices(u8, &.{ 0x18, 0x00 }, image.data[0x20..0x22]);
}

test "smoke ROM is reproducible from its assembly source" {
    const allocator = t.allocator;
    const smoke_asm = @embedFile("../fixtures/asm/smoke.asm");
    const smoke_gb = @embedFile("../fixtures/roms/smoke.gb");
    var image = try assembleString(allocator, smoke_asm);
    defer image.deinit(allocator);
    try t.expectEqual(@as(u16, 0x0000), image.origin);
    try t.expectEqual(@as(usize, 0x8000), image.data.len);
    try t.expectEqualSlices(u8, smoke_gb, image.data);
}

test "GBFIX fills the cartridge header checksum" {
    const allocator = t.allocator;
    const source =
        \\    ORG $0000
        \\    DB $00, $00, $01, $FF
        \\    ORG $0134
        \\    DB "ABCD"
        \\    PAD $0140
        \\    ORG $0150
        \\    GBFIX
        \\    PAD $8000
    ;
    var image = try assembleString(allocator, source);
    defer image.deinit(allocator);
    var expected: u8 = 0;
    for (0x134..0x14d) |address| expected = expected -% image.data[address] -% 1;
    try t.expectEqual(expected, image.data[0x14d]);
    try t.expectEqual(expected ^ 0xff, image.data[0x14e]);
}

test "duplicate labels are rejected" {
    const allocator = t.allocator;
    const source =
        \\    ORG $0100
        \\dup:
        \\    NOP
        \\dup:
        \\    NOP
    ;
    try t.expectError(error.DuplicateSymbol, assembleString(allocator, source));
}

test "undefined symbols are rejected" {
    const allocator = t.allocator;
    const source =
        \\    ORG $0100
        \\    LD A,nowhere
    ;
    try t.expectError(error.UndefinedSymbol, assembleString(allocator, source));
}

test "out of range relative jump is rejected" {
    const allocator = t.allocator;
    const source =
        \\    ORG $0100
        \\    JR far
        \\    DS $200
        \\far:
        \\    NOP
    ;
    try t.expectError(error.BadImmediate, assembleString(allocator, source));
}

// ---------------------------------------------------------------------------
// Command line driver
// ---------------------------------------------------------------------------

fn usage(program: []const u8) void {
    std.debug.print(
        \\gbasm - SM83 assembler for test fixture ROMs
        \\Usage:
        \\  {s} <asm-dir> <out-dir>
        \\
        \\Assembles every .asm file in asm-dir and writes a .gb file with
        \\the same base name into out-dir.
        \\
    , .{program});
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return path[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |slash| return path[slash + 1 ..];
    return path;
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| try args.append(allocator, arg);

    if (args.items.len != 3) {
        usage(args.items[0]);
        std.process.exit(2);
    }
    const asm_dir_path = args.items[1];
    const out_dir_path = args.items[2];

    var dir = try std.Io.Dir.cwd().openDir(io, asm_dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".asm")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var failures: usize = 0;
    for (names.items) |name| {
        const asm_path = try std.fs.path.join(allocator, &.{ asm_dir_path, name });
        defer allocator.free(asm_path);
        const source = readFile(io, allocator, asm_path) catch |err| {
            std.debug.print("{s}: read error: {s}\n", .{ name, @errorName(err) });
            failures += 1;
            continue;
        };
        defer allocator.free(source);

        var image = assemble(io, allocator, source, asm_dir_path) catch |err| {
            std.debug.print("{s}: assemble error: {s}\n", .{ name, @errorName(err) });
            failures += 1;
            continue;
        };
        defer image.deinit(allocator);

        const out_name = try std.mem.replaceOwned(u8, allocator, baseName(name), ".asm", ".gb");
        defer allocator.free(out_name);
        const out_path = try std.fs.path.join(allocator, &.{ out_dir_path, out_name });
        defer allocator.free(out_path);

        const dir_writer = std.Io.Dir.cwd();
        try dir_writer.writeFile(io, .{ .sub_path = out_path, .data = image.data });
        std.debug.print("{s} -> {s} ({d} bytes at ${X:0>4})\n", .{ name, out_name, image.data.len, image.origin });
    }

    std.debug.print("\n{d}/{d} sources assembled\n", .{ names.items.len - failures, names.items.len });
    if (failures != 0) std.process.exit(1);
}
