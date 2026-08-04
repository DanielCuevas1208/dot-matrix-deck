//! gbasm - a small assembler for the SM83.
//!
//! It turns line-oriented SM83 assembly into Game Boy ROM bytes. The
//! output is deterministic, so generated fixtures never change between
//! runs. The same code powers the CLI and the deterministic tests.

const std = @import("std");

pub const Diagnostics = struct {
    line: usize,
    message: []const u8,
};

pub const AssemblyError = error{
    OutOfMemory,
    AssemblyFailed,
    IoFailed,
};

const Reg = enum(u8) {
    b = 0,
    c,
    d,
    e,
    h,
    l,
    mhl, // (HL)
    a,
};

const Pair = enum(u8) {
    bc = 0,
    de,
    hl,
    sp,
};

const Cond = enum(u8) {
    nz = 0,
    z,
    nc,
    c,
};

const TokenKind = enum {
    ident,
    number,
    string,
    comma,
    colon,
    plus,
    minus,
    lparen,
    rparen,
    eol,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

const Line = struct {
    number: usize,
    tokens: []Token,
};

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '.';
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
}

fn isHex(ch: u8) bool {
    return std.ascii.isHex(ch);
}

// Splits the source into lines of tokens. Comments start with ';'.
// String literals support \\, \", \n, \t and \xNN escapes.
fn tokenize(allocator: std.mem.Allocator, source: []const u8, diagnostics: *std.ArrayList(Diagnostics)) AssemblyError![]Line {
    var lines = std.ArrayList(Line).empty;
    errdefer {
        for (lines.items) |line| allocator.free(line.tokens);
        lines.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (it.next()) |raw| {
        defer line_no += 1;
        var tokens = std.ArrayList(Token).empty;
        errdefer tokens.deinit(allocator);

        var i: usize = 0;
        var ok = true;
        while (i < raw.len) {
            const ch = raw[i];
            if (ch == ';') break;
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                i += 1;
                continue;
            }
            if (isIdentStart(ch)) {
                var end = i + 1;
                while (end < raw.len and isIdentChar(raw[end])) end += 1;
                try tokens.append(allocator, .{ .kind = .ident, .text = raw[i..end] });
                i = end;
            } else if (std.ascii.isDigit(ch)) {
                var end = i + 1;
                while (end < raw.len and std.ascii.isAlphanumeric(raw[end])) end += 1;
                try tokens.append(allocator, .{ .kind = .number, .text = raw[i..end] });
                i = end;
            } else if (ch == '$' or ch == '0') {
                // Handle $-prefixed hex and 0x/0b prefixes.
                var end = i;
                if (ch == '$') {
                    end = i + 1;
                    while (end < raw.len and isHex(raw[end])) end += 1;
                    try tokens.append(allocator, .{ .kind = .number, .text = raw[i..end] });
                } else {
                    end = i + 1;
                    if (end < raw.len and (raw[end] == 'x' or raw[end] == 'X' or raw[end] == 'b' or raw[end] == 'B')) {
                        end += 1;
                        while (end < raw.len and std.ascii.isAlphanumeric(raw[end])) end += 1;
                        try tokens.append(allocator, .{ .kind = .number, .text = raw[i..end] });
                    } else {
                        while (end < raw.len and std.ascii.isDigit(raw[end])) end += 1;
                        try tokens.append(allocator, .{ .kind = .number, .text = raw[i..end] });
                    }
                }
                i = end;
            } else if (ch == '"') {
                var text = std.ArrayList(u8).empty;
                errdefer text.deinit(allocator);
                i += 1;
                var closed = false;
                while (i < raw.len) {
                    const c = raw[i];
                    if (c == '"') {
                        closed = true;
                        i += 1;
                        break;
                    } else if (c == '\\') {
                        i += 1;
                        if (i >= raw.len) break;
                        const esc = raw[i];
                        switch (esc) {
                            'n' => try text.append(allocator, '\n'),
                            't' => try text.append(allocator, '\t'),
                            '\\' => try text.append(allocator, '\\'),
                            '"' => try text.append(allocator, '"'),
                            'x' => {
                                if (i + 2 < raw.len and isHex(raw[i + 1]) and isHex(raw[i + 2])) {
                                    try text.append(allocator, std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch 0);
                                    i += 2;
                                } else {
                                    try text.append(allocator, 'x');
                                }
                            },
                            else => try text.append(allocator, esc),
                        }
                        i += 1;
                    } else {
                        try text.append(allocator, c);
                        i += 1;
                    }
                }
                if (!closed) {
                    try diagnostics.append(allocator, .{ .line = line_no, .message = "unterminated string" });
                    ok = false;
                    break;
                }
                try tokens.append(allocator, .{ .kind = .string, .text = try text.toOwnedSlice(allocator) });
            } else {
                const kind: TokenKind = switch (ch) {
                    ',' => .comma,
                    ':' => .colon,
                    '+' => .plus,
                    '-' => .minus,
                    '(' => .lparen,
                    ')' => .rparen,
                    else => {
                        try diagnostics.append(allocator, .{ .line = line_no, .message = "unexpected character" });
                        ok = false;
                        break;
                    },
                };
                try tokens.append(allocator, .{ .kind = kind, .text = raw[i .. i + 1] });
                i += 1;
            }
        }

        try tokens.append(allocator, .{ .kind = .eol, .text = "" });
        try lines.append(allocator, .{ .number = line_no, .tokens = try tokens.toOwnedSlice(allocator) });
        if (!ok) return error.AssemblyFailed;
    }
    return lines.toOwnedSlice(allocator);
}

fn freeLines(allocator: std.mem.Allocator, lines: []Line) void {
    for (lines) |line| {
        for (line.tokens) |token| {
            if (token.kind == .string) allocator.free(token.text);
        }
        allocator.free(line.tokens);
    }
    allocator.free(lines);
}

fn diag(diagnostics: *std.ArrayList(Diagnostics), allocator: std.mem.Allocator, line: usize, message: []const u8) AssemblyError {
    diagnostics.append(allocator, .{ .line = line, .message = message }) catch return error.OutOfMemory;
    return error.AssemblyFailed;
}

const LabelTable = struct {
    map: std.StringHashMap(u16),
    allocator: std.mem.Allocator,
    // In pass 1 expressions resolve to zero so forward labels do not
    // need to be defined yet. Sizes stay correct because every
    // instruction has a fixed length.
    dummy: bool = false,

    fn init(allocator: std.mem.Allocator) LabelTable {
        return .{ .map = std.StringHashMap(u16).init(allocator), .allocator = allocator };
    }

    fn deinit(self: *LabelTable) void {
        var it = self.map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.map.deinit();
    }

    fn define(self: *LabelTable, name: []const u8, value: u16, line: usize, diagnostics: *std.ArrayList(Diagnostics)) AssemblyError!void {
        if (self.map.get(name) != null) return diag(diagnostics, self.allocator, line, "duplicate label");
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.map.put(owned, value);
    }

    fn lookup(self: *const LabelTable, name: []const u8, line: usize, diagnostics: *std.ArrayList(Diagnostics)) AssemblyError!u16 {
        if (self.dummy) return 0;
        if (self.map.get(name)) |value| return value;
        return diag(diagnostics, self.allocator, line, "unknown label");
    }
};

// Parses a number literal or a label name.
fn parseExprValue(tokens: []Token, i: *usize, labels: *const LabelTable, allocator: std.mem.Allocator, line: usize, diagnostics: *std.ArrayList(Diagnostics)) AssemblyError!u16 {
    const token = tokens[i.*];
    switch (token.kind) {
        .number => {
            i.* += 1;
            return parseNumber(token.text, allocator, line, diagnostics);
        },
        .ident => {
            i.* += 1;
            return labels.lookup(token.text, line, diagnostics);
        },
        else => return diag(diagnostics, allocator, line, "expected a value"),
    }
}

fn parseNumber(text: []const u8, allocator: std.mem.Allocator, line: usize, diagnostics: *std.ArrayList(Diagnostics)) AssemblyError!u16 {
    if (text.len >= 2 and text[0] == '$') {
        return std.fmt.parseInt(u16, text[1..], 16) catch return diag(diagnostics, allocator, line, "bad hex value");
    }
    if (text.len >= 3 and (text[0] == '0' and (text[1] == 'x' or text[1] == 'X'))) {
        return std.fmt.parseInt(u16, text[2..], 16) catch return diag(diagnostics, allocator, line, "bad hex value");
    }
    if (text.len >= 3 and (text[0] == '0' and (text[1] == 'b' or text[1] == 'B'))) {
        return std.fmt.parseInt(u16, text[2..], 2) catch return diag(diagnostics, allocator, line, "bad binary value");
    }
    return std.fmt.parseInt(u16, text, 10) catch return diag(diagnostics, allocator, line, "bad number");
}

fn parseSignedValue(tokens: []Token, i: *usize, labels: *const LabelTable, allocator: std.mem.Allocator, line: usize, diagnostics: *std.ArrayList(Diagnostics)) AssemblyError!i16 {
    var sign: i16 = 1;
    if (i.* < tokens.len and tokens[i.*].kind == .minus) {
        sign = -1;
        i.* += 1;
    } else if (i.* < tokens.len and tokens[i.*].kind == .plus) {
        i.* += 1;
    }
    const value = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
    return sign * @as(i16, @intCast(value));
}

fn parseReg(tokens: []Token, i: *usize) ?Reg {
    if (tokens[i.*].kind != .ident) return null;
    const name = tokens[i.*].text;
    const reg: Reg = if (std.mem.eql(u8, name, "a")) .a else if (std.mem.eql(u8, name, "b")) .b else if (std.mem.eql(u8, name, "c")) .c else if (std.mem.eql(u8, name, "d")) .d else if (std.mem.eql(u8, name, "e")) .e else if (std.mem.eql(u8, name, "h")) .h else if (std.mem.eql(u8, name, "l")) .l else return null;
    i.* += 1;
    return reg;
}

// Recognises "(reg)" where reg is bc, de, hl, (hl), c.
const ParenReg = enum { bc, de, hl_inc, hl_dec, hl, c, none };

fn parseParen(tokens: []Token, i: *usize) ParenReg {
    if (tokens[i.*].kind != .lparen) return .none;
    const save = i.*;
    i.* += 1;
    if (tokens[i.*].kind == .ident) {
        const name = tokens[i.*].text;
        if (std.mem.eql(u8, name, "bc") or std.mem.eql(u8, name, "BC")) {
            i.* += 1;
        } else if (std.mem.eql(u8, name, "de") or std.mem.eql(u8, name, "DE")) {
            i.* += 1;
            if (match(i, tokens, .rparen)) {
                i.* += 1;
                return .de;
            }
            i.* = save;
            return .none;
        } else if (std.mem.eql(u8, name, "hl") or std.mem.eql(u8, name, "HL")) {
            i.* += 1;
            if (match(i, tokens, .plus)) {
                i.* += 1;
                if (match(i, tokens, .rparen)) {
                    i.* += 1;
                    return .hl_inc;
                }
                i.* = save;
                return .none;
            }
            if (match(i, tokens, .minus)) {
                i.* += 1;
                if (match(i, tokens, .rparen)) {
                    i.* += 1;
                    return .hl_dec;
                }
                i.* = save;
                return .none;
            }
            if (match(i, tokens, .rparen)) {
                i.* += 1;
                return .hl;
            }
            i.* = save;
            return .none;
        } else if (std.mem.eql(u8, name, "c") or std.mem.eql(u8, name, "C")) {
            i.* += 1;
            if (match(i, tokens, .rparen)) {
                i.* += 1;
                return .c;
            }
            i.* = save;
            return .none;
        }
        if (match(i, tokens, .rparen)) {
            i.* += 1;
            return .bc;
        }
        i.* = save;
        return .none;
    }
    i.* = save;
    return .none;
}

fn match(i: *usize, tokens: []Token, kind: TokenKind) bool {
    return i.* < tokens.len and tokens[i.*].kind == kind;
}

fn isIdentAt(tokens: []Token, index: usize, name: []const u8) bool {
    return index < tokens.len and tokens[index].kind == .ident and std.ascii.eqlIgnoreCase(tokens[index].text, name);
}

fn matchIdent(tokens: []Token, i: *usize, name: []const u8) bool {
    return tokens[i.*].kind == .ident and (std.mem.eql(u8, tokens[i.*].text, name) or std.ascii.eqlIgnoreCase(tokens[i.*].text, name));
}

fn opcode(value: u8, bytes: *std.ArrayList(u8), allocator: std.mem.Allocator) AssemblyError!void {
    try bytes.append(allocator, value);
}

fn encode8(value: u8, bytes: *std.ArrayList(u8), allocator: std.mem.Allocator) AssemblyError!void {
    try bytes.append(allocator, value);
}

fn encode16(value: u16, bytes: *std.ArrayList(u8), allocator: std.mem.Allocator) AssemblyError!void {
    try bytes.append(allocator, @intCast(value & 0xff));
    try bytes.append(allocator, @intCast(value >> 8));
}

// Emits one line of assembly into `bytes`. Returns the number of bytes
// emitted so the caller can advance the program counter. When
// `resolve_labels` is false, expressions return 0; sizes stay correct
// because every instruction has a fixed length.
fn emitLine(
    tokens: []Token,
    line: usize,
    address: u16,
    labels: *LabelTable,
    resolve_labels: bool,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostics),
) AssemblyError!usize {
    var i: usize = 0;

    // A label occupies the leading position and may share the line.
    if (tokens[i].kind == .ident and tokens[i + 1].kind == .colon) {
        if (!resolve_labels) try labels.define(tokens[i].text, address, line, diagnostics);
        i += 2;
    }

    const start = bytes.items.len;
    if (tokens[i].kind == .eol) return 0;
    if (tokens[i].kind == .ident) {
        const name = tokens[i].text;
        if (name.len != 0 and name[0] == '.') {
            return emitDirective(tokens, line, address, labels, resolve_labels, bytes, allocator, diagnostics);
        }
    }

    const mnemonic = tokens[i].text;
    if (tokens[i].kind != .ident) return diag(diagnostics, allocator, line, "expected a mnemonic");
    i += 1;

    try emitInstruction(tokens, &i, line, address, labels, resolve_labels, bytes, allocator, diagnostics, mnemonic);
    if (tokens[i].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after instruction");
    return bytes.items.len - start;
}

fn emitDirective(
    tokens: []Token,
    line: usize,
    address: u16,
    labels: *const LabelTable,
    resolve_labels: bool,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostics),
) AssemblyError!usize {
    const name = tokens[0].text;
    var i: usize = 1;

    if (std.mem.eql(u8, name, ".org")) {
        const value = try parseExprValue(tokens, &i, labels, allocator, line, diagnostics);
        if (tokens[i].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after .org");
        const target: usize = value;
        if (target > 0x8000) return diag(diagnostics, allocator, line, ".org target is out of range");
        if (target < @as(usize, address)) return diag(diagnostics, allocator, line, ".org target overlaps emitted bytes");
        if (resolve_labels) {
            while (bytes.items.len < target) try bytes.append(allocator, 0x00);
        }
        return target - @as(usize, address);
    }

    if (std.mem.eql(u8, name, ".db")) {
        var count: usize = 0;
        while (true) {
            const value = try parseExprValue(tokens, &i, labels, allocator, line, diagnostics);
            if (value > 0xff) return diag(diagnostics, allocator, line, "byte value out of range");
            if (resolve_labels) try bytes.append(allocator, @intCast(value & 0xff));
            count += 1;
            if (!match(&i, tokens, .comma)) break;
            i += 1;
        }
        if (tokens[i].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after .db");
        return count;
    }

    if (std.mem.eql(u8, name, ".dw")) {
        var count: usize = 0;
        while (true) {
            const value = try parseExprValue(tokens, &i, labels, allocator, line, diagnostics);
            if (resolve_labels) try encode16(value, bytes, allocator);
            count += 2;
            if (!match(&i, tokens, .comma)) break;
            i += 1;
        }
        if (tokens[i].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after .dw");
        return count;
    }

    if (std.mem.eql(u8, name, ".ascii")) {
        var count: usize = 0;
        while (true) {
            if (tokens[i].kind != .string) return diag(diagnostics, allocator, line, "expected a string after .ascii");
            if (resolve_labels) {
                for (tokens[i].text) |ch| try bytes.append(allocator, ch);
            }
            count += tokens[i].text.len;
            i += 1;
            if (!match(&i, tokens, .comma)) break;
            i += 1;
        }
        if (tokens[i].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after .ascii");
        return count;
    }

    return diag(diagnostics, allocator, line, "unknown directive");
}

const ALU = enum(u8) {
    add = 0,
    adc,
    sub,
    sbc,
    and_op,
    xor_op,
    or_op,
    cp,
};

fn parseAlu(name: []const u8) ?ALU {
    if (std.ascii.eqlIgnoreCase(name, "ADD")) return .add;
    if (std.ascii.eqlIgnoreCase(name, "ADC")) return .adc;
    if (std.ascii.eqlIgnoreCase(name, "SUB")) return .sub;
    if (std.ascii.eqlIgnoreCase(name, "SBC")) return .sbc;
    if (std.ascii.eqlIgnoreCase(name, "AND")) return .and_op;
    if (std.ascii.eqlIgnoreCase(name, "XOR")) return .xor_op;
    if (std.ascii.eqlIgnoreCase(name, "OR")) return .or_op;
    if (std.ascii.eqlIgnoreCase(name, "CP")) return .cp;
    return null;
}

fn parseCond(name: []const u8) ?Cond {
    if (std.ascii.eqlIgnoreCase(name, "NZ")) return .nz;
    if (std.ascii.eqlIgnoreCase(name, "Z")) return .z;
    if (std.ascii.eqlIgnoreCase(name, "NC")) return .nc;
    if (std.ascii.eqlIgnoreCase(name, "C")) return .c;
    return null;
}

fn emitInstruction(
    tokens: []Token,
    i: *usize,
    line: usize,
    address: u16,
    labels: *const LabelTable,
    resolve_labels: bool,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostics),
    mnemonic: []const u8,
) AssemblyError!void {
    if (std.ascii.eqlIgnoreCase(mnemonic, "NOP")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "NOP takes no operands");
        try opcode(0x00, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "HALT")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "HALT takes no operands");
        try opcode(0x76, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "STOP")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "STOP takes no operands");
        try opcode(0x10, bytes, allocator);
        try opcode(0x00, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "DI")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "DI takes no operands");
        try opcode(0xf3, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "EI")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "EI takes no operands");
        try opcode(0xfb, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "DAA")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "DAA takes no operands");
        try opcode(0x27, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "CPL")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "CPL takes no operands");
        try opcode(0x2f, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "SCF")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "SCF takes no operands");
        try opcode(0x37, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "CCF")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "CCF takes no operands");
        try opcode(0x3f, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "RLCA")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "RLCA takes no operands");
        try opcode(0x07, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "RLA")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "RLA takes no operands");
        try opcode(0x17, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "RRCA")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "RRCA takes no operands");
        try opcode(0x0f, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "RRA")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "RRA takes no operands");
        try opcode(0x1f, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "RET")) {
        const cond = if (tokens[i.*].kind == .ident) parseCond(tokens[i.*].text) else null;
        if (cond) |c| {
            i.* += 1;
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after RET");
            try opcode(@intFromEnum(c) * 8 + 0xc0, bytes, allocator);
        } else {
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after RET");
            try opcode(0xc9, bytes, allocator);
        }
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "RETI")) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "RETI takes no operands");
        try opcode(0xd9, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "PUSH") or std.ascii.eqlIgnoreCase(mnemonic, "POP")) {
        const pair = parsePushPopPair(tokens[i.*]) orelse return diag(diagnostics, allocator, line, "expected a register pair");
        if (tokens[i.* + 1].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after PUSH/POP");
        i.* += 1;
        const base: u8 = if (std.ascii.eqlIgnoreCase(mnemonic, "PUSH")) 0xc5 else 0xc1;
        try opcode(base | @as(u8, @intFromEnum(pair)) << 4, bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "INC") or std.ascii.eqlIgnoreCase(mnemonic, "DEC")) {
        const base: u8 = if (std.ascii.eqlIgnoreCase(mnemonic, "INC")) 0x04 else 0x05;
        if (parseParen(tokens, i) == .hl) {
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after INC/DEC (HL)");
            try opcode(base | 0x30, bytes, allocator);
            return;
        }
        if (parseParen(tokens, i) != .none) return diag(diagnostics, allocator, line, "unsupported indirect operand");
        if (parseReg(tokens, i)) |reg| {
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after INC/DEC");
            try opcode(base | @as(u8, @intFromEnum(reg)) << 3, bytes, allocator);
            return;
        }
        if (parsePair(tokens[i.*])) |pair| {
            i.* += 1;
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after INC/DEC pair");
            const op: u8 = if (std.ascii.eqlIgnoreCase(mnemonic, "INC")) 0x03 else 0x0b;
            try opcode(op | @as(u8, @intFromEnum(pair)) << 4, bytes, allocator);
            return;
        }
        return diag(diagnostics, allocator, line, "expected a register, (HL), or register pair");
    }
    if (parseAlu(mnemonic)) |alu| {
        return emitAlu(tokens, i, line, labels, resolve_labels, bytes, allocator, diagnostics, alu);
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "JP")) {
        // JP (HL)
        if (parseParen(tokens, i) == .hl) {
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after JP (HL)");
            try opcode(0xe9, bytes, allocator);
            return;
        }
        const cond = if (tokens[i.*].kind == .ident) parseCond(tokens[i.*].text) else null;
        var base: u8 = 0xc3;
        if (cond) |c| {
            base = @intFromEnum(c) * 8 + 0xc2;
            i.* += 1;
            if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma after JP condition");
            i.* += 1;
        }
        const target = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
        try opcode(base, bytes, allocator);
        try encode16(target, bytes, allocator);
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after JP");
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "JR")) {
        const cond = if (tokens[i.*].kind == .ident) parseCond(tokens[i.*].text) else null;
        var base: u8 = 0x18;
        if (cond) |c| {
            base = @intFromEnum(c) * 8 + 0x20;
            i.* += 1;
            if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma after JR condition");
            i.* += 1;
        }
        const target = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
        if (resolve_labels) {
            const here = @as(u16, address +% 2);
            const offset: i32 = @as(i32, target) - @as(i32, here);
            if (offset < -128 or offset > 127) return diag(diagnostics, allocator, line, "JR offset out of range");
            try opcode(base, bytes, allocator);
            try opcode(@as(u8, @bitCast(@as(i8, @intCast(offset)))), bytes, allocator);
        } else {
            try opcode(base, bytes, allocator);
            try opcode(0x00, bytes, allocator);
        }
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after JR");
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "CALL")) {
        const cond = if (tokens[i.*].kind == .ident) parseCond(tokens[i.*].text) else null;
        var base: u8 = 0xcd;
        if (cond) |c| {
            base = @intFromEnum(c) * 8 + 0xc4;
            i.* += 1;
            if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma after CALL condition");
            i.* += 1;
        }
        const target = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
        try opcode(base, bytes, allocator);
        try encode16(target, bytes, allocator);
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after CALL");
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "RST")) {
        const value = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
        if (value > 0x38 or (value & 7) != 0) return diag(diagnostics, allocator, line, "RST target must be 0x00-0x38 step 8");
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after RST");
        try opcode(0xc7 + @as(u8, @intCast(value)), bytes, allocator);
        return;
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "LD")) {
        return emitLd(tokens, i, line, labels, resolve_labels, bytes, allocator, diagnostics);
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "LDH")) {
        return emitLdh(tokens, i, line, labels, resolve_labels, bytes, allocator, diagnostics);
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "RLC") or std.ascii.eqlIgnoreCase(mnemonic, "RRC") or std.ascii.eqlIgnoreCase(mnemonic, "RL") or std.ascii.eqlIgnoreCase(mnemonic, "RR") or std.ascii.eqlIgnoreCase(mnemonic, "SLA") or std.ascii.eqlIgnoreCase(mnemonic, "SRA") or std.ascii.eqlIgnoreCase(mnemonic, "SWAP") or std.ascii.eqlIgnoreCase(mnemonic, "SRL")) {
        return emitCbRotate(tokens, i, line, mnemonic, resolve_labels, bytes, allocator, diagnostics);
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "BIT") or std.ascii.eqlIgnoreCase(mnemonic, "RES") or std.ascii.eqlIgnoreCase(mnemonic, "SET")) {
        return emitCbBit(tokens, i, line, mnemonic, labels, resolve_labels, bytes, allocator, diagnostics);
    }

    return diag(diagnostics, allocator, line, "unknown mnemonic");
}

fn parsePair(token: Token) ?Pair {
    if (token.kind != .ident) return null;
    if (std.ascii.eqlIgnoreCase(token.text, "BC")) return .bc;
    if (std.ascii.eqlIgnoreCase(token.text, "DE")) return .de;
    if (std.ascii.eqlIgnoreCase(token.text, "HL")) return .hl;
    if (std.ascii.eqlIgnoreCase(token.text, "SP")) return .sp;
    return null;
}

// PUSH/POP also accept AF, which shares the SP encoding.
fn parsePushPopPair(token: Token) ?Pair {
    if (token.kind == .ident and std.ascii.eqlIgnoreCase(token.text, "AF")) return .sp;
    return parsePair(token);
}

fn parseExprZero(tokens: []Token, i: *usize, labels: *const LabelTable, line: usize, diagnostics: *std.ArrayList(Diagnostics)) AssemblyError!u16 {
    _ = labels;
    _ = line;
    _ = diagnostics;
    _ = tokens;
    i.* += 1;
    return 0;
}

const ParenOperand = union(enum) {
    c,
    bc,
    de,
    hl_inc,
    hl_dec,
    hl,
    ldh: u16, // (ff00+n)
    abs: u16, // (nn)
};

// Parses a parenthesised operand. Register forms and the FF00+n form
// are recognised by name; anything else is an absolute 16-bit address.
fn parseParenOperand(
    tokens: []Token,
    i: *usize,
    labels: *const LabelTable,
    allocator: std.mem.Allocator,
    line: usize,
    diagnostics: *std.ArrayList(Diagnostics),
) AssemblyError!ParenOperand {
    if (tokens[i.*].kind != .lparen) return diag(diagnostics, allocator, line, "expected '('");
    i.* += 1;

    if (tokens[i.*].kind == .ident) {
        const name = tokens[i.*].text;
        if (std.ascii.eqlIgnoreCase(name, "ff00")) {
            i.* += 1;
            const sign = if (match(i, tokens, .plus)) @as(i16, 1) else if (match(i, tokens, .minus)) @as(i16, -1) else return diag(diagnostics, allocator, line, "expected + or - after FF00");
            i.* += 1;
            const offset = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
            const total = 0xff00 +% @as(u16, @intCast(@mod(sign * @as(i16, @intCast(offset)), 0x100)));
            if (!match(i, tokens, .rparen)) return diag(diagnostics, allocator, line, "expected ')'");
            i.* += 1;
            return .{ .ldh = total & 0xff };
        }
        if (std.ascii.eqlIgnoreCase(name, "bc")) {
            i.* += 1;
            if (!match(i, tokens, .rparen)) return diag(diagnostics, allocator, line, "expected ')'");
            i.* += 1;
            return .bc;
        }
        if (std.ascii.eqlIgnoreCase(name, "de")) {
            i.* += 1;
            if (!match(i, tokens, .rparen)) return diag(diagnostics, allocator, line, "expected ')'");
            i.* += 1;
            return .de;
        }
        if (std.ascii.eqlIgnoreCase(name, "c")) {
            i.* += 1;
            if (!match(i, tokens, .rparen)) return diag(diagnostics, allocator, line, "expected ')'");
            i.* += 1;
            return .c;
        }
        if (std.ascii.eqlIgnoreCase(name, "hl")) {
            i.* += 1;
            if (match(i, tokens, .plus)) {
                i.* += 1;
                if (!match(i, tokens, .rparen)) return diag(diagnostics, allocator, line, "expected ')'");
                i.* += 1;
                return .hl_inc;
            }
            if (match(i, tokens, .minus)) {
                i.* += 1;
                if (!match(i, tokens, .rparen)) return diag(diagnostics, allocator, line, "expected ')'");
                i.* += 1;
                return .hl_dec;
            }
            if (!match(i, tokens, .rparen)) return diag(diagnostics, allocator, line, "expected ')'");
            i.* += 1;
            return .hl;
        }
    }

    // Any other token is an absolute address.
    const target = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
    if (!match(i, tokens, .rparen)) return diag(diagnostics, allocator, line, "expected ')'");
    i.* += 1;
    return .{ .abs = target };
}

fn emitAlu(
    tokens: []Token,
    i: *usize,
    line: usize,
    labels: *const LabelTable,
    resolve_labels: bool,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostics),
    alu: ALU,
) AssemblyError!void {
    _ = resolve_labels;
    const base: u8 = @intFromEnum(alu) << 3;

    // 16-bit ADD forms: ADD HL,rr and ADD SP,o.
    if (alu == .add) {
        if (parsePair(tokens[i.*])) |left| {
            if (left == .sp or left == .hl) {
                i.* += 1;
                if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma");
                i.* += 1;
                if (left == .hl) {
                    const right = parsePair(tokens[i.*]) orelse return diag(diagnostics, allocator, line, "expected a register pair");
                    i.* += 1;
                    if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after ADD HL,rr");
                    try opcode(0x09 | @as(u8, @intFromEnum(right)) << 4, bytes, allocator);
                    return;
                }
                const offset = try parseSignedValue(tokens, i, labels, allocator, line, diagnostics);
                if (offset < -128 or offset > 127) return diag(diagnostics, allocator, line, "offset out of range");
                if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after ADD SP,o");
                try opcode(0xe8, bytes, allocator);
                try encode8(@as(u8, @bitCast(@as(i8, @intCast(offset)))), bytes, allocator);
                return;
            }
        }
    }

    // Allow the redundant "A," prefix, e.g. "ADD A,B".
    if (matchIdent(tokens, i, "A") and tokens[i.* + 1].kind == .comma) {
        i.* += 2;
    }
    if (parseReg(tokens, i)) |reg| {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after ALU");
        try opcode(0x80 | base | @as(u8, @intFromEnum(reg)), bytes, allocator);
        return;
    }
    if (parseParen(tokens, i) == .hl) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after ALU");
        try opcode(0x80 | base | 6, bytes, allocator);
        return;
    }
    const value = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
    if (value > 0xff) return diag(diagnostics, allocator, line, "immediate out of range");
    if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after ALU");
    try opcode(0xc6 | base, bytes, allocator);
    try encode8(@intCast(value & 0xff), bytes, allocator);
}

fn emitLd(
    tokens: []Token,
    i: *usize,
    line: usize,
    labels: *const LabelTable,
    resolve_labels: bool,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostics),
) AssemblyError!void {
    _ = resolve_labels;
    // LD (nn),SP. Only numeric addresses reach this probe; register
    // operands like (C) or (HL) are handled below.
    if (tokens[i.*].kind == .lparen and tokens[i.* + 1].kind == .number) {
        const save = i.*;
        i.* += 1;
        const target = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
        if (tokens[i.*].kind == .rparen and tokens[i.* + 1].kind == .comma and tokens[i.* + 2].kind == .ident and std.ascii.eqlIgnoreCase(tokens[i.* + 2].text, "SP")) {
            i.* += 3;
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD (nn),SP");
            try opcode(0x08, bytes, allocator);
            try encode16(target, bytes, allocator);
            return;
        }
        i.* = save;
    }

    // LD (operand),A for C, BC, DE, HL+, HL-, FF00+n or nn, plus the
    // LD (HL),A / (HL),r / (HL),n forms.
    if (tokens[i.*].kind == .lparen) {
        const operand = try parseParenOperand(tokens, i, labels, allocator, line, diagnostics);
        if (operand == .hl) {
            if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma");
            i.* += 1;
            if (parseReg(tokens, i)) |reg| {
                if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD (HL),r");
                try opcode(0x70 | @as(u8, @intFromEnum(reg)), bytes, allocator);
                return;
            }
            const value = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
            if (value > 0xff) return diag(diagnostics, allocator, line, "immediate out of range");
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD (HL),n");
            try opcode(0x36, bytes, allocator);
            try encode8(@intCast(value & 0xff), bytes, allocator);
            return;
        }
        if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma");
        i.* += 1;
        if (!matchIdent(tokens, i, "A")) return diag(diagnostics, allocator, line, "LD to an indirect address only takes A");
        i.* += 1;
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD");
        switch (operand) {
            .c => try opcode(0xe2, bytes, allocator),
            .bc => try opcode(0x02, bytes, allocator),
            .de => try opcode(0x12, bytes, allocator),
            .hl_inc => try opcode(0x22, bytes, allocator),
            .hl_dec => try opcode(0x32, bytes, allocator),
            .hl => unreachable,
            .ldh => |offset| {
                try opcode(0xe0, bytes, allocator);
                try encode8(@intCast(offset), bytes, allocator);
            },
            .abs => |target| {
                try opcode(0xea, bytes, allocator);
                try encode16(target, bytes, allocator);
            },
        }
        return;
    }

    // LD SP,HL
    if (matchIdent(tokens, i, "SP") and tokens[i.* + 1].kind == .comma and isIdentAt(tokens, i.* + 2, "HL")) {
        i.* += 3;
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD SP,HL");
        try opcode(0xf9, bytes, allocator);
        return;
    }

    // LD HL,SP+o
    if (matchIdent(tokens, i, "HL") and tokens[i.* + 1].kind == .comma and isIdentAt(tokens, i.* + 2, "SP")) {
        if (tokens[i.* + 3].kind == .eol) {
            i.* += 1;
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD HL,SP");
            try opcode(0xf9, bytes, allocator);
            return;
        }
        if (tokens[i.* + 3].kind == .plus or tokens[i.* + 3].kind == .minus) {
            i.* += 3;
            const offset = try parseSignedValue(tokens, i, labels, allocator, line, diagnostics);
            if (offset < -128 or offset > 127) return diag(diagnostics, allocator, line, "offset out of range");
            if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD HL,SP+o");
            try opcode(0xf8, bytes, allocator);
            try encode8(@as(u8, @bitCast(@as(i8, @intCast(offset)))), bytes, allocator);
            return;
        }
        return diag(diagnostics, allocator, line, "LD HL,SP expects an offset");
    }

    // LD rr,nn
    if (parsePair(tokens[i.*])) |pair| {
        i.* += 1;
        if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma");
        i.* += 1;
        const value = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD rr,nn");
        try opcode(0x01 | @as(u8, @intFromEnum(pair)) << 4, bytes, allocator);
        try encode16(value, bytes, allocator);
        return;
    }

    // LD A,(operand) where operand is C, BC, DE, HL+, HL-, HL, FF00+n or nn.
    if (matchIdent(tokens, i, "A") and tokens[i.* + 1].kind == .comma and tokens[i.* + 2].kind == .lparen) {
        i.* += 2;
        const operand = try parseParenOperand(tokens, i, labels, allocator, line, diagnostics);
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD A,(...)");
        switch (operand) {
            .c => try opcode(0xf2, bytes, allocator),
            .bc => try opcode(0x0a, bytes, allocator),
            .de => try opcode(0x1a, bytes, allocator),
            .hl_inc => try opcode(0x2a, bytes, allocator),
            .hl_dec => try opcode(0x3a, bytes, allocator),
            .hl => try opcode(0x7e, bytes, allocator),
            .ldh => |offset| {
                try opcode(0xf0, bytes, allocator);
                try encode8(@intCast(offset), bytes, allocator);
            },
            .abs => |target| {
                try opcode(0xfa, bytes, allocator);
                try encode16(target, bytes, allocator);
            },
        }
        return;
    }

    // LD r,(HL) / LD r,r' / LD r,n
    const dst = parseReg(tokens, i) orelse return diag(diagnostics, allocator, line, "expected a register");
    if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma");
    i.* += 1;
    if (parseParen(tokens, i) == .hl) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD r,(HL)");
        try opcode(0x46 | @as(u8, @intFromEnum(dst)) << 3, bytes, allocator);
        return;
    }
    if (parseReg(tokens, i)) |src| {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD r,r'");
        try opcode(0x40 | @as(u8, @intFromEnum(dst)) << 3 | @as(u8, @intFromEnum(src)), bytes, allocator);
        return;
    }
    const value = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
    if (value > 0xff) return diag(diagnostics, allocator, line, "immediate out of range");
    if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens after LD r,n");
    try opcode(0x06 | @as(u8, @intFromEnum(dst)) << 3, bytes, allocator);
    try encode8(@intCast(value & 0xff), bytes, allocator);
}

fn emitLdh(
    tokens: []Token,
    i: *usize,
    line: usize,
    labels: *const LabelTable,
    resolve_labels: bool,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostics),
) AssemblyError!void {
    _ = resolve_labels;
    // LDH A,(n8) or LDH (n8),A
    const read = matchIdent(tokens, i, "A") and tokens[i.* + 1].kind == .comma;
    if (read) i.* += 2;
    if (tokens[i.*].kind != .lparen) return diag(diagnostics, allocator, line, "LDH expects a (n8) operand");
    i.* += 1;
    const value = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
    if (value > 0xff) return diag(diagnostics, allocator, line, "LDH offset out of range");
    if (!match(i, tokens, .rparen)) return diag(diagnostics, allocator, line, "expected ')'");
    i.* += 1;
    if (read) {
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens");
        try opcode(0xf0, bytes, allocator);
    } else {
        if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma");
        i.* += 1;
        if (!matchIdent(tokens, i, "A")) return diag(diagnostics, allocator, line, "LDH (n8) only takes A");
        i.* += 1;
        if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens");
        try opcode(0xe0, bytes, allocator);
    }
    try encode8(@intCast(value & 0xff), bytes, allocator);
}

fn emitCbRotate(
    tokens: []Token,
    i: *usize,
    line: usize,
    mnemonic: []const u8,
    resolve_labels: bool,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostics),
) AssemblyError!void {
    _ = resolve_labels;
    const base: u8 = if (std.ascii.eqlIgnoreCase(mnemonic, "RLC")) 0x00 else if (std.ascii.eqlIgnoreCase(mnemonic, "RRC")) 0x08 else if (std.ascii.eqlIgnoreCase(mnemonic, "RL")) 0x10 else if (std.ascii.eqlIgnoreCase(mnemonic, "RR")) 0x18 else if (std.ascii.eqlIgnoreCase(mnemonic, "SLA")) 0x20 else if (std.ascii.eqlIgnoreCase(mnemonic, "SRA")) 0x28 else if (std.ascii.eqlIgnoreCase(mnemonic, "SWAP")) 0x30 else 0x38;
    const reg = parseReg(tokens, i) orelse blk: {
        if (parseParen(tokens, i) == .hl) break :blk Reg.mhl;
        return diag(diagnostics, allocator, line, "expected a register or (HL)");
    };
    if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens");
    try opcode(0xcb, bytes, allocator);
    try opcode(base | @as(u8, @intFromEnum(reg)), bytes, allocator);
}

fn emitCbBit(
    tokens: []Token,
    i: *usize,
    line: usize,
    mnemonic: []const u8,
    labels: *const LabelTable,
    resolve_labels: bool,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostics),
) AssemblyError!void {
    _ = resolve_labels;
    const bit = try parseExprValue(tokens, i, labels, allocator, line, diagnostics);
    if (bit > 7) return diag(diagnostics, allocator, line, "bit index out of range");
    if (tokens[i.*].kind != .comma) return diag(diagnostics, allocator, line, "expected a comma after bit index");
    i.* += 1;
    const reg = parseReg(tokens, i) orelse blk: {
        if (parseParen(tokens, i) == .hl) break :blk Reg.mhl;
        return diag(diagnostics, allocator, line, "expected a register or (HL)");
    };
    if (tokens[i.*].kind != .eol) return diag(diagnostics, allocator, line, "trailing tokens");
    const base: u8 = if (std.ascii.eqlIgnoreCase(mnemonic, "BIT")) 0x40 else if (std.ascii.eqlIgnoreCase(mnemonic, "RES")) 0x80 else 0xc0;
    try opcode(0xcb, bytes, allocator);
    try opcode(base | @as(u8, @intCast(bit)) << 3 | @as(u8, @intFromEnum(reg)), bytes, allocator);
}

// Assemblies the source text into a ROM image. Callers should free the
// returned slice with the allocator.
pub fn assemble(allocator: std.mem.Allocator, source: []const u8, diagnostics: *std.ArrayList(Diagnostics)) AssemblyError![]u8 {
    const lines = try tokenize(allocator, source, diagnostics);
    defer freeLines(allocator, lines);

    var labels = LabelTable.init(allocator);
    defer labels.deinit();

    // Pass 1: assign addresses and collect labels.
    labels.dummy = true;
    var address: u16 = 0;
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);
    for (lines) |line| {
        scratch.clearRetainingCapacity();
        const size = emitLine(line.tokens, line.number, address, &labels, false, &scratch, allocator, diagnostics) catch |err| return err;
        address +%= @intCast(size);
    }

    // Pass 2: emit the final bytes.
    labels.dummy = false;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    address = 0;
    for (lines) |line| {
        const size = emitLine(line.tokens, line.number, address, &labels, true, &output, allocator, diagnostics) catch |err| return err;
        address +%= @intCast(size);
    }

    return output.toOwnedSlice(allocator);
}

fn usage(program: []const u8) void {
    std.debug.print(
        \\gbasm - SM83 assembler for dot-matrix-deck fixtures
        \\Usage:
        \\  {s} <input-dir> <output-dir>
        \\
        \\Assembles every .gbasm file in the input directory and writes a
        \\<name>.gb ROM for each one into the output directory.
        \\
    , .{program});
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
        usage(argv[0]);
        std.process.exit(2);
    }

    const input_dir = argv[1];
    const output_dir = argv[2];

    var dir = std.Io.Dir.cwd().openDir(io, input_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("cannot open input directory: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer dir.close(io);

    std.Io.Dir.cwd().createDirPath(io, output_dir) catch |err| {
        std.debug.print("cannot create output directory: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iter = dir.iterate();
    while (iter.next(io) catch |err| {
        std.debug.print("cannot read input directory: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    }) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".gbasm")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (names.items) |name| {
        const stem = name[0 .. name.len - ".gbasm".len];
        const in_path = try std.fs.path.join(allocator, &.{ input_dir, name });
        defer allocator.free(in_path);
        const out_path = try std.fs.path.join(allocator, &.{ output_dir, stem });
        const out_path2 = try std.fmt.allocPrint(allocator, "{s}.gb", .{out_path});
        defer allocator.free(out_path);
        defer allocator.free(out_path2);

        const source = readFile(io, allocator, in_path) catch |err| {
            std.debug.print("{s}: cannot read: {s}\n", .{ name, @errorName(err) });
            std.process.exit(1);
        };
        defer allocator.free(source);

        var diagnostics = std.ArrayList(Diagnostics).empty;
        defer diagnostics.deinit(allocator);

        const image = assemble(allocator, source, &diagnostics) catch |err| {
            if (diagnostics.items.len != 0) {
                for (diagnostics.items) |d| {
                    std.debug.print("{s}:{d}: {s}\n", .{ name, d.line, d.message });
                }
            } else {
                std.debug.print("{s}: {s}\n", .{ name, @errorName(err) });
            }
            std.process.exit(1);
        };
        defer allocator.free(image);

        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path2, .data = image }) catch |err| {
            std.debug.print("{s}: cannot write: {s}\n", .{ name, @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("{s} -> {s} ({d} bytes)\n", .{ name, out_path2, image.len });
    }
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const buffer = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

test "gbasm assembles core instructions to known bytes" {
    const allocator = std.testing.allocator;
    const source =
        \\.org 0x100
        \\    nop
        \\    ld a, 5
        \\    ld hl, 0x1234
        \\    jp 0x200
        \\    jr 0x106
        \\    ld (0xff01), a
        \\    add a, 0x40
        \\    rlc c
        \\    bit 3, (hl)
        \\    ret
    ;
    var diagnostics = std.ArrayList(Diagnostics).empty;
    defer diagnostics.deinit(allocator);
    const image = try assemble(allocator, source, &diagnostics);
    defer allocator.free(image);

    const expected = [_]u8{ 0x00, 0x3e, 0x05, 0x21, 0x34, 0x12, 0xc3, 0x00, 0x02, 0x18, 0xfb, 0xea, 0x01, 0xff, 0xc6, 0x40, 0xcb, 0x01, 0xcb, 0x5e, 0xc9 };
    try std.testing.expectEqualSlices(u8, &expected, image[0x100..]);
}

test "gbasm resolves forward labels and conditional jumps" {
    const allocator = std.testing.allocator;
    const source =
        \\    ld a, 0
        \\loop:
        \\    inc a
        \\    cp 0x10
        \\    jr nz, loop
        \\    jp done
        \\    ld b, 0xaa
        \\done:
        \\    ld c, a
    ;
    var diagnostics = std.ArrayList(Diagnostics).empty;
    defer diagnostics.deinit(allocator);
    const image = try assemble(allocator, source, &diagnostics);
    defer allocator.free(image);

    // loop at offset 2; jr nz target loop (offset 2) from 7+2=9 -> -7.
    const expected = [_]u8{ 0x3e, 0x00, 0x3c, 0xfe, 0x10, 0x20, 0xfb, 0xc3, 0x0c, 0x00, 0x06, 0xaa, 0x4f };
    try std.testing.expectEqualSlices(u8, &expected, image);
}

test "gbasm assembles the demo ROM pattern" {
    const allocator = std.testing.allocator;
    const source =
        \\.org 0x100
        \\    ld sp, 0xfffe
        \\    ld a, 0x80
        \\    ld (0xff40), a
        \\halted:
        \\    jr halted
    ;
    var diagnostics = std.ArrayList(Diagnostics).empty;
    defer diagnostics.deinit(allocator);
    const image = try assemble(allocator, source, &diagnostics);
    defer allocator.free(image);

    const expected = [_]u8{ 0x31, 0xfe, 0xff, 0x3e, 0x80, 0xea, 0x40, 0xff, 0x18, 0xfe };
    try std.testing.expectEqualSlices(u8, &expected, image[0x100..]);
}

test "gbasm encodes 16-bit increment and decrement pairs" {
    const allocator = std.testing.allocator;
    const source =
        \\    inc bc
        \\    dec de
        \\    inc hl
        \\    dec sp
        \\    inc b
        \\    dec c
    ;
    var diagnostics = std.ArrayList(Diagnostics).empty;
    defer diagnostics.deinit(allocator);
    const image = try assemble(allocator, source, &diagnostics);
    defer allocator.free(image);
    const expected = [_]u8{ 0x03, 0x1b, 0x23, 0x3b, 0x04, 0x0d };
    try std.testing.expectEqualSlices(u8, &expected, image);
}

test "gbasm reports errors with a line number" {
    const allocator = std.testing.allocator;
    const source =
        \\    ld a, 1
        \\    ld b, 2
        \\    nop nope
    ;
    var diagnostics = std.ArrayList(Diagnostics).empty;
    defer diagnostics.deinit(allocator);
    try std.testing.expectError(error.AssemblyFailed, assemble(allocator, source, &diagnostics));
    try std.testing.expectEqual(@as(usize, 3), diagnostics.items[0].line);
}

test "gbasm supports LDH, strings, and registers" {
    const allocator = std.testing.allocator;
    const source =
        \\.org 0x150
        \\    ldh (0x01), a
        \\    ldh a, (0x02)
        \\    .ascii "PASS\n"
        \\    .dw 0x1234
        \\    add hl, de
        \\    pop af
    ;
    var diagnostics = std.ArrayList(Diagnostics).empty;
    defer diagnostics.deinit(allocator);
    const image = try assemble(allocator, source, &diagnostics);
    defer allocator.free(image);

    const expected = [_]u8{ 0xe0, 0x01, 0xf0, 0x02, 'P', 'A', 'S', 'S', '\n', 0x34, 0x12, 0x19, 0xf1 };
    try std.testing.expectEqualSlices(u8, &expected, image[0x150..]);
}
