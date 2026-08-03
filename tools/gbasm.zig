const std = @import("std");

// gbasm - an SM83 assembler for test ROM sources.
//
// It turns the small assembly dialect used by the bundled test ROMs into
// a Game Boy cartridge image. The build step "zig build fixtures" runs it
// over the assembler sources and writes the ROMs. The integration tests
// assemble the smoke ROM again and compare the output to the committed
// image byte for byte.
//
// Supported syntax:
//   org $0100       set the next address; the gap fills with $00
//   db 1, 2, 3      emit bytes from numbers or double-quoted strings
//   dw $1234        emit 16-bit values, little endian
//   ds $10          emit N zero bytes
//   label:          define a label at the current address
//   instruction     the SM83 base set plus the CB prefix
//
// Literals use $ for hex, % for binary, or plain decimal. An operand may
// also be a label, or a label plus or minus a constant. The image always
// has the size of a 32 KiB cartridge. SM83 instruction sizes never depend
// on operand values, so pass one sizes the program and pass two encodes
// it with full knowledge of the labels.

pub const ImageSize: usize = 0x8000;
const max_operands = 16;

const Line = struct {
    label: ?[]const u8 = null,
    mnemonic: []const u8 = "",
    operands: [max_operands][]const u8 = undefined,
    count: usize = 0,

    fn operand(self: *const Line, index: usize) []const u8 {
        return self.operands[index];
    }
};

// Uppercases the slice in place.
fn upperInPlace(slice: []u8) void {
    for (slice) |*ch| ch.* = std.ascii.toUpper(ch.*);
}

// Splits a source line into a label, a mnemonic, and comma-separated
// operands. Tokens are uppercased in place so instructions and registers
// match case-insensitively; quoted strings keep their case. A semicolon
// starts a comment outside a quoted string.
fn parseLine(line: []u8) Line {
    var rest = std.mem.trim(u8, line, " \t\r");

    {
        var in_quotes = false;
        for (rest, 0..) |ch, i| {
            if (ch == '"') in_quotes = !in_quotes;
            if (ch == ';' and !in_quotes) {
                rest = std.mem.trimEnd(u8, rest[0..i], " \t");
                break;
            }
        }
    }
    if (rest.len == 0) return .{};

    var label: ?[]const u8 = null;
    if (std.mem.indexOf(u8, rest, ":")) |colon| {
        const prefix = std.mem.trimEnd(u8, rest[0..colon], " \t");
        const is_label = prefix.len != 0 and (colon + 1 == rest.len or rest[colon + 1] == ' ' or rest[colon + 1] == '\t');
        if (is_label) {
            upperInPlace(@constCast(prefix));
            label = prefix;
            rest = std.mem.trimStart(u8, rest[colon + 1 ..], " \t");
        }
    }
    if (rest.len == 0) return .{ .label = label };

    var line_result = Line{ .label = label };
    if (std.mem.indexOfAny(u8, rest, " \t")) |space| {
        line_result.mnemonic = rest[0..space];
        upperInPlace(@constCast(line_result.mnemonic));
        rest = std.mem.trimStart(u8, rest[space..], " \t");
    } else {
        line_result.mnemonic = rest;
        upperInPlace(@constCast(line_result.mnemonic));
        rest = "";
    }
    if (rest.len == 0) return line_result;

    var start: usize = 0;
    var in_quotes = false;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        const at_end = i == rest.len;
        const ch = if (at_end) 0 else rest[i];
        if (ch == '"') in_quotes = !in_quotes;
        if ((at_end or ch == ',') and !in_quotes) {
            const operand = std.mem.trim(u8, rest[start..i], " \t");
            if (operand.len != 0 and line_result.count < max_operands) {
                if (operand.len < 2 or operand[0] != '"') upperInPlace(@constCast(operand));
                line_result.operands[line_result.count] = operand;
                line_result.count += 1;
            }
            start = i + 1;
        }
    }
    return line_result;
}

const Operand = enum { rel8, addr16, imm8, imm16, a8, rst_vec, sp };

const Instruction = struct {
    operand: Operand,
};

fn reg8Index(text: []const u8) ?u8 {
    return if (std.mem.eql(u8, text, "A")) 7 else if (std.mem.eql(u8, text, "B")) 0 else if (std.mem.eql(u8, text, "C")) 1 else if (std.mem.eql(u8, text, "D")) 2 else if (std.mem.eql(u8, text, "E")) 3 else if (std.mem.eql(u8, text, "H")) 4 else if (std.mem.eql(u8, text, "L")) 5 else if (std.mem.eql(u8, text, "(HL)")) 6 else null;
}

fn reg16Index(text: []const u8) ?u8 {
    return if (std.mem.eql(u8, text, "BC")) 0 else if (std.mem.eql(u8, text, "DE")) 1 else if (std.mem.eql(u8, text, "HL")) 2 else if (std.mem.eql(u8, text, "SP")) 3 else null;
}

fn pushPopIndex(text: []const u8) ?u8 {
    return if (std.mem.eql(u8, text, "BC")) 0 else if (std.mem.eql(u8, text, "DE")) 1 else if (std.mem.eql(u8, text, "HL")) 2 else if (std.mem.eql(u8, text, "AF")) 3 else null;
}

fn condIndex(text: []const u8) ?u8 {
    return if (std.mem.eql(u8, text, "NZ")) 0 else if (std.mem.eql(u8, text, "Z")) 1 else if (std.mem.eql(u8, text, "NC")) 2 else if (std.mem.eql(u8, text, "C")) 3 else null;
}

fn aluIndex(text: []const u8) ?u8 {
    return if (std.mem.eql(u8, text, "ADD")) 0 else if (std.mem.eql(u8, text, "ADC")) 1 else if (std.mem.eql(u8, text, "SUB")) 2 else if (std.mem.eql(u8, text, "SBC")) 3 else if (std.mem.eql(u8, text, "AND")) 4 else if (std.mem.eql(u8, text, "XOR")) 5 else if (std.mem.eql(u8, text, "OR")) 6 else if (std.mem.eql(u8, text, "CP")) 7 else null;
}

fn cbIndex(text: []const u8) ?u8 {
    return if (std.mem.eql(u8, text, "RLC")) 0 else if (std.mem.eql(u8, text, "RRC")) 1 else if (std.mem.eql(u8, text, "RL")) 2 else if (std.mem.eql(u8, text, "RR")) 3 else if (std.mem.eql(u8, text, "SLA")) 4 else if (std.mem.eql(u8, text, "SRA")) 5 else if (std.mem.eql(u8, text, "SWAP")) 6 else if (std.mem.eql(u8, text, "SRL")) 7 else null;
}

pub const Assembler = struct {
    allocator: std.mem.Allocator,
    image: []u8,
    symbols: std.StringHashMap(u16),
    work: []u8,
    error_buffer: [160]u8 = undefined,
    error_len: usize = 0,
    pc: u16 = 0,
    final_pass: bool = false,

    pub fn deinit(self: *Assembler) void {
        var it = self.symbols.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.symbols.deinit();
        self.allocator.free(self.image);
        self.allocator.free(self.work);
    }

    pub fn errorText(self: *const Assembler) ?[]const u8 {
        if (self.error_len == 0) return null;
        return self.error_buffer[0..self.error_len];
    }

    fn fail(self: *Assembler, comptime format: []const u8, args: anytype) void {
        if (self.error_len != 0) return;
        const text = std.fmt.bufPrint(&self.error_buffer, format, args) catch "assembly error";
        self.error_len = @min(text.len, self.error_buffer.len);
    }

    // Evaluates an operand to an unsigned value. Unknown symbols return
    // null; pass one treats those as zero and pass two resolves them.
    // Surrounding parentheses, as in (a16), are ignored.
    fn evaluate(self: *Assembler, text: []const u8) ?u32 {
        const operand = std.mem.trim(u8, text, " \t");
        if (operand.len == 0) return null;

        const bare = if (operand.len >= 2 and operand[0] == '(' and operand[operand.len - 1] == ')')
            std.mem.trim(u8, operand[1 .. operand.len - 1], " \t")
        else
            operand;
        if (bare.len == 0) return null;

        if (std.mem.indexOfAny(u8, bare, "+-")) |sign| {
            const left = std.mem.trim(u8, bare[0..sign], " \t");
            const right = std.mem.trim(u8, bare[sign + 1 ..], " \t");
            const base_value = self.evaluateSymbol(left) orelse return null;
            const delta = self.parseNumber(right) orelse return null;
            const result = if (bare[sign] == '+') @as(i64, base_value) + delta else @as(i64, base_value) - delta;
            if (result < 0 or result > 0xffff) return null;
            return @intCast(result);
        }
        return self.evaluateSymbol(bare);
    }

    fn evaluateSymbol(self: *Assembler, text: []const u8) ?u32 {
        if (self.parseNumber(text)) |value| return value;
        if (self.symbols.get(text)) |value| return value;
        return null;
    }

    fn parseNumber(self: *Assembler, text: []const u8) ?u32 {
        _ = self;
        const value = if (text.len >= 1 and text[0] == '$') std.fmt.parseInt(u32, text[1..], 16) else if (text.len >= 1 and text[0] == '%') std.fmt.parseInt(u32, text[1..], 2) else std.fmt.parseInt(u32, text, 10);
        return value catch null;
    }

    fn writeByte(self: *Assembler, value: u8) void {
        if (self.pc >= ImageSize) {
            self.fail("program exceeds 32 KiB", .{});
            return;
        }
        self.image[self.pc] = value;
        self.pc +%= 1;
    }

    fn writeOperand(self: *Assembler, instruction: Instruction, line: Line, index: usize) void {
        switch (instruction.operand) {
            .rel8 => self.writeRel8(line, index),
            .imm16, .addr16 => {
                const value = self.operandWord(instruction, line, index);
                self.writeByte(@truncate(value));
                self.writeByte(@truncate(value >> 8));
            },
            .imm8, .a8, .rst_vec, .sp => self.writeByte(self.operandByte(instruction, line, index)),
        }
    }

    fn operandByte(self: *Assembler, instruction: Instruction, line: Line, index: usize) u8 {
        const text = std.mem.trim(u8, line.operand(index), " \t");
        switch (instruction.operand) {
            .rst_vec => {
                const value = self.evaluate(text) orelse 0;
                if (value > 0x38 or (value & 7) != 0) {
                    self.fail("invalid RST vector: {s}", .{text});
                    return 0;
                }
                return @intCast(value);
            },
            .sp => return self.offsetByte(text),
            .imm8, .a8 => {
                const value = self.evaluate(text) orelse 0;
                if (value > 0xff) self.fail("immediate out of range: {s}", .{text});
                return @truncate(value);
            },
            else => return 0,
        }
    }

    // Encodes a signed 8-bit stack offset for ADD SP,e8 and LD HL,SP+e8.
    // The operand may be written as a number, a label, or SP plus or
    // minus a number.
    fn offsetByte(self: *Assembler, text: []const u8) u8 {
        var token = std.mem.trim(u8, text, " \t");
        if (std.mem.startsWith(u8, token, "SP")) {
            token = std.mem.trimStart(u8, token[2..], " \t");
        }
        var negative = false;
        if (token.len >= 1 and (token[0] == '+' or token[0] == '-')) {
            negative = token[0] == '-';
            token = std.mem.trimStart(u8, token[1..], " \t");
        }
        const magnitude = self.evaluate(token) orelse 0;
        const value: i64 = if (negative) -@as(i64, magnitude) else magnitude;
        if (value < -128 or value > 127) {
            self.fail("stack offset out of range: {s}", .{text});
            return 0;
        }
        const encoded: u32 = @bitCast(@as(i32, @intCast(value)));
        return @truncate(encoded);
    }

    fn operandWord(self: *Assembler, instruction: Instruction, line: Line, index: usize) u16 {
        const text = std.mem.trim(u8, line.operand(index), " \t");
        _ = instruction;
        const value = self.evaluate(text) orelse 0;
        if (value > 0xffff) self.fail("immediate out of range: {s}", .{text});
        return @truncate(value);
    }

    fn writeRel8(self: *Assembler, line: Line, index: usize) void {
        const text = std.mem.trim(u8, line.operand(index), " \t");
        const target = self.evaluate(text) orelse 0;
        const next_pc = @as(u32, self.pc) + 1;
        const delta = @as(i64, target) - @as(i64, next_pc);
        if (self.final_pass and (delta < -128 or delta > 127)) {
            self.fail("branch target out of range: {s}", .{text});
            return;
        }
        const encoded: u32 = @bitCast(@as(i32, @intCast(delta)));
        self.writeByte(@truncate(encoded));
    }

    // Encodes a two-operand LD or ALU form where the operands encode
    // register bits directly.
    fn encodeRegPair(self: *Assembler, opcode: u8, line: Line) void {
        const dst = reg8Index(line.operand(0)) orelse blk: {
            self.fail("expected 8-bit register: {s}", .{line.operand(0)});
            break :blk 0;
        };
        const src = reg8Index(line.operand(1)) orelse blk: {
            self.fail("expected 8-bit register: {s}", .{line.operand(1)});
            break :blk 0;
        };
        self.writeByte(opcode | (dst << 3) | src);
    }

    fn encodeAluReg(self: *Assembler, alu: u8, line: Line) void {
        const src = reg8Index(line.operand(1)) orelse blk: {
            self.fail("expected 8-bit register: {s}", .{line.operand(1)});
            break :blk 0;
        };
        self.writeByte(0x80 | (alu << 3) | src);
    }

    fn encodeCb(self: *Assembler, line: Line) bool {
        if (cbIndex(line.mnemonic)) |operation| {
            if (line.count != 1) {
                self.fail("expected one register: {s}", .{line.mnemonic});
                return true;
            }
            const reg = reg8Index(line.operand(0)) orelse blk: {
                self.fail("expected 8-bit register: {s}", .{line.operand(0)});
                break :blk 0;
            };
            self.writeByte(0xcb);
            self.writeByte(operation << 3 | reg);
            return true;
        }
        if (std.mem.eql(u8, line.mnemonic, "BIT") or std.mem.eql(u8, line.mnemonic, "RES") or std.mem.eql(u8, line.mnemonic, "SET")) {
            if (line.count != 2) {
                self.fail("expected bit and register: {s}", .{line.mnemonic});
                return true;
            }
            const bit = self.evaluate(line.operand(0)) orelse 0;
            if (bit > 7) {
                self.fail("bit index out of range: {s}", .{line.operand(0)});
                return true;
            }
            const reg = reg8Index(line.operand(1)) orelse blk: {
                self.fail("expected 8-bit register: {s}", .{line.operand(1)});
                break :blk 0;
            };
            const base: u8 = if (std.mem.eql(u8, line.mnemonic, "BIT")) 0x40 else if (std.mem.eql(u8, line.mnemonic, "RES")) 0x80 else 0xc0;
            self.writeByte(0xcb);
            self.writeByte(base | (@as(u8, @intCast(bit)) << 3) | reg);
            return true;
        }
        return false;
    }

    fn emitInstruction(self: *Assembler, line: Line) void {
        if (self.encodeCb(line)) return;

        const no_operands = [_][]const u8{
            "NOP",  "HALT", "STOP", "DAA", "CPL", "SCF",  "CCF", "DI", "EI",
            "RLCA", "RRCA", "RLA",  "RRA", "RET", "RETI",
        };
        const no_operand_codes = [_]u8{
            0x00, 0x76, 0x10, 0x27, 0x2f, 0x37, 0x3f, 0xf3, 0xfb,
            0x07, 0x0f, 0x17, 0x1f, 0xc9, 0xd9,
        };
        for (no_operands, 0..) |name, i| {
            if (std.mem.eql(u8, line.mnemonic, name)) {
                if (line.count == 0) {
                    self.writeByte(no_operand_codes[i]);
                } else {
                    self.fail("instruction takes no operands: {s}", .{name});
                }
                return;
            }
        }

        if (line.count == 1) {
            if (std.mem.eql(u8, line.mnemonic, "JP") and std.mem.eql(u8, line.operand(0), "(HL)")) {
                self.writeByte(0xe9);
                return;
            }
            if (reg8Index(line.operand(0))) |reg| {
                if (std.mem.eql(u8, line.mnemonic, "INC")) {
                    self.writeByte(0x04 | (reg << 3));
                    return;
                }
                if (std.mem.eql(u8, line.mnemonic, "DEC")) {
                    self.writeByte(0x05 | (reg << 3));
                    return;
                }
            }
            if (reg16Index(line.operand(0))) |rp| {
                if (std.mem.eql(u8, line.mnemonic, "INC")) {
                    self.writeByte(0x03 | (rp << 4));
                    return;
                }
                if (std.mem.eql(u8, line.mnemonic, "DEC")) {
                    self.writeByte(0x0b | (rp << 4));
                    return;
                }
            }
            if (pushPopIndex(line.operand(0))) |rp| {
                if (std.mem.eql(u8, line.mnemonic, "PUSH")) {
                    self.writeByte(0xc5 | (rp << 4));
                    return;
                }
                if (std.mem.eql(u8, line.mnemonic, "POP")) {
                    self.writeByte(0xc1 | (rp << 4));
                    return;
                }
            }
            if (std.mem.eql(u8, line.mnemonic, "JR")) {
                self.writeByte(0x18);
                self.writeOperand(.{ .operand = .rel8 }, line, 0);
                return;
            }
            if (std.mem.eql(u8, line.mnemonic, "JP")) {
                self.writeByte(0xc3);
                self.writeOperand(.{ .operand = .addr16 }, line, 0);
                return;
            }
            if (std.mem.eql(u8, line.mnemonic, "CALL")) {
                self.writeByte(0xcd);
                self.writeOperand(.{ .operand = .addr16 }, line, 0);
                return;
            }
            if (std.mem.eql(u8, line.mnemonic, "RST")) {
                self.writeByte(0xc7);
                self.writeOperand(.{ .operand = .rst_vec }, line, 0);
                return;
            }
            if (aluIndex(line.mnemonic)) |alu| {
                if (reg8Index(line.operand(0))) |src| {
                    self.writeByte(0x80 | (alu << 3) | src);
                    return;
                }
                self.writeByte(0xc6 | (alu << 3));
                self.writeOperand(.{ .operand = .imm8 }, line, 0);
                return;
            }
            self.fail("unsupported instruction: {s}", .{line.mnemonic});
            return;
        }

        if (line.count == 2) {
            if (std.mem.eql(u8, line.mnemonic, "LD")) {
                self.emitLd(line);
                return;
            }
            if (std.mem.eql(u8, line.mnemonic, "LDH")) {
                self.emitLdh(line);
                return;
            }
            if (std.mem.eql(u8, line.mnemonic, "ADD") and std.mem.eql(u8, line.operand(0), "HL")) {
                if (reg16Index(line.operand(1))) |rp| {
                    self.writeByte(0x09 | (rp << 4));
                    return;
                }
                self.fail("expected 16-bit register: {s}", .{line.operand(1)});
                return;
            }
            if (std.mem.eql(u8, line.mnemonic, "ADD") and std.mem.eql(u8, line.operand(0), "SP")) {
                self.writeByte(0xe8);
                self.writeOperand(.{ .operand = .sp }, line, 1);
                return;
            }
            if (aluIndex(line.mnemonic)) |alu| {
                if (!std.mem.eql(u8, line.operand(0), "A")) {
                    self.fail("ALU operands must start with A: {s}", .{line.operand(0)});
                    return;
                }
                if (reg8Index(line.operand(1))) |src| {
                    self.writeByte(0x80 | (alu << 3) | src);
                    return;
                }
                self.writeByte(0xc6 | (alu << 3));
                self.writeOperand(.{ .operand = .imm8 }, line, 1);
                return;
            }
            if (std.mem.eql(u8, line.mnemonic, "JR")) {
                if (condIndex(line.operand(0))) |cc| {
                    self.writeByte(0x20 | (cc << 3));
                    self.writeOperand(.{ .operand = .rel8 }, line, 1);
                    return;
                }
                self.fail("expected condition: {s}", .{line.operand(0)});
                return;
            }
            if (std.mem.eql(u8, line.mnemonic, "RET")) {
                if (condIndex(line.operand(0))) |cc| {
                    self.writeByte(0xc0 | (cc << 3));
                    return;
                }
                self.fail("expected condition: {s}", .{line.operand(0)});
                return;
            }
            if (std.mem.eql(u8, line.mnemonic, "JP") or std.mem.eql(u8, line.mnemonic, "CALL")) {
                const base: u8 = if (std.mem.eql(u8, line.mnemonic, "JP")) 0xc2 else 0xc4;
                if (condIndex(line.operand(0))) |cc| {
                    self.writeByte(base | (cc << 3));
                    self.writeOperand(.{ .operand = .addr16 }, line, 1);
                    return;
                }
                self.fail("expected condition: {s}", .{line.operand(0)});
                return;
            }
            self.fail("unsupported instruction: {s}", .{line.mnemonic});
            return;
        }

        self.fail("unsupported instruction: {s}", .{line.mnemonic});
    }

    fn emitLd(self: *Assembler, line: Line) void {
        if (std.mem.eql(u8, line.operand(1), "A")) {
            if (std.mem.eql(u8, line.operand(0), "(BC)")) return self.writeByte(0x02);
            if (std.mem.eql(u8, line.operand(0), "(DE)")) return self.writeByte(0x12);
            if (std.mem.eql(u8, line.operand(0), "(HL+)")) return self.writeByte(0x22);
            if (std.mem.eql(u8, line.operand(0), "(HL-)")) return self.writeByte(0x32);
            if (std.mem.eql(u8, line.operand(0), "(C)")) return self.writeByte(0xe2);
            if (std.mem.eql(u8, line.operand(0), "(HL)")) return self.writeByte(0x77);
            if (line.operand(0).len >= 2 and line.operand(0)[0] == '(') {
                self.writeByte(0xea);
                self.writeOperand(.{ .operand = .addr16 }, line, 0);
                return;
            }
            if (reg8Index(line.operand(0))) |reg| {
                self.writeByte(0x40 | (reg << 3) | 7);
                return;
            }
        }
        if (std.mem.eql(u8, line.operand(0), "A")) {
            if (std.mem.eql(u8, line.operand(1), "(BC)")) return self.writeByte(0x0a);
            if (std.mem.eql(u8, line.operand(1), "(DE)")) return self.writeByte(0x1a);
            if (std.mem.eql(u8, line.operand(1), "(HL+)")) return self.writeByte(0x2a);
            if (std.mem.eql(u8, line.operand(1), "(HL-)")) return self.writeByte(0x3a);
            if (std.mem.eql(u8, line.operand(1), "(C)")) return self.writeByte(0xf2);
            if (std.mem.eql(u8, line.operand(1), "(HL)")) return self.writeByte(0x7e);
            if (line.operand(1).len >= 2 and line.operand(1)[0] == '(') {
                self.writeByte(0xfa);
                self.writeOperand(.{ .operand = .addr16 }, line, 1);
                return;
            }
            if (reg8Index(line.operand(1))) |src| {
                self.writeByte(0x40 | (7 << 3) | src);
                return;
            }
        }
        if (std.mem.eql(u8, line.operand(0), "SP") and std.mem.eql(u8, line.operand(1), "HL")) {
            return self.writeByte(0xf9);
        }
        if (std.mem.eql(u8, line.operand(1), "SP")) {
            if (line.operand(0).len >= 2 and line.operand(0)[0] == '(') {
                self.writeByte(0x08);
                self.writeOperand(.{ .operand = .addr16 }, line, 0);
                return;
            }
        }
        if (std.mem.eql(u8, line.operand(0), "HL") and std.mem.startsWith(u8, line.operand(1), "SP")) {
            self.writeByte(0xf8);
            self.writeOperand(.{ .operand = .sp }, line, 1);
            return;
        }
        if (std.mem.eql(u8, line.operand(0), "(HL)") and reg8Index(line.operand(1)) == null) {
            self.writeByte(0x36);
            self.writeOperand(.{ .operand = .imm8 }, line, 1);
            return;
        }
        if (reg16Index(line.operand(0))) |rp| {
            self.writeByte(0x01 | (rp << 4));
            self.writeOperand(.{ .operand = .imm16 }, line, 1);
            return;
        }
        if (reg8Index(line.operand(0))) |reg| {
            self.writeByte(0x06 | (reg << 3));
            self.writeOperand(.{ .operand = .imm8 }, line, 1);
            return;
        }
        if (reg8Index(line.operand(0))) |dst| {
            if (reg8Index(line.operand(1))) |src| {
                self.writeByte(0x40 | (dst << 3) | src);
                return;
            }
        }
        self.fail("unsupported LD form: {s}, {s}", .{ line.operand(0), line.operand(1) });
    }

    fn emitLdh(self: *Assembler, line: Line) void {
        if (std.mem.eql(u8, line.operand(0), "(C)") and std.mem.eql(u8, line.operand(1), "A")) {
            return self.writeByte(0xe2);
        }
        if (std.mem.eql(u8, line.operand(0), "A") and std.mem.eql(u8, line.operand(1), "(C)")) {
            return self.writeByte(0xf2);
        }
        if (std.mem.eql(u8, line.operand(1), "A")) {
            self.writeByte(0xe0);
            self.writeOperand(.{ .operand = .a8 }, line, 0);
            return;
        }
        if (std.mem.eql(u8, line.operand(0), "A")) {
            self.writeByte(0xf0);
            self.writeOperand(.{ .operand = .a8 }, line, 1);
            return;
        }
        self.fail("unsupported LDH form: {s}, {s}", .{ line.operand(0), line.operand(1) });
    }

    fn emitDirective(self: *Assembler, line: Line) bool {
        if (std.mem.eql(u8, line.mnemonic, "ORG")) {
            const value = self.evaluate(line.operand(0)) orelse {
                self.fail("org needs a constant address", .{});
                return true;
            };
            if (value > 0xffff) {
                self.fail("org address out of range", .{});
                return true;
            }
            const target: u16 = @intCast(value);
            if (target < self.pc) {
                self.fail("org moves the program backwards", .{});
                return true;
            }
            while (self.pc < target) self.writeByte(0);
            return true;
        }
        if (std.mem.eql(u8, line.mnemonic, "DS")) {
            const count = self.evaluate(line.operand(0)) orelse {
                self.fail("DS needs a constant size", .{});
                return true;
            };
            var i: u32 = 0;
            while (i < count) : (i += 1) self.writeByte(0);
            return true;
        }
        if (std.mem.eql(u8, line.mnemonic, "DB")) {
            for (0..line.count) |i| self.emitDbOperand(line.operand(i));
            return true;
        }
        if (std.mem.eql(u8, line.mnemonic, "DW")) {
            for (0..line.count) |i| {
                const value = self.evaluate(line.operand(i)) orelse 0;
                if (value > 0xffff) self.fail("16-bit value out of range: {s}", .{line.operand(i)});
                self.writeByte(@truncate(value));
                self.writeByte(@truncate(value >> 8));
            }
            return true;
        }
        return false;
    }

    fn emitDbOperand(self: *Assembler, text: []const u8) void {
        const operand = std.mem.trim(u8, text, " \t");
        if (operand.len >= 2 and operand[0] == '"' and operand[operand.len - 1] == '"') {
            for (operand[1 .. operand.len - 1]) |ch| self.writeByte(ch);
            return;
        }
        const value = self.evaluate(operand) orelse 0;
        if (value > 0xff) self.fail("byte value out of range: {s}", .{operand});
        self.writeByte(@truncate(value));
    }

    // Runs one assembly pass. The first pass records labels and lays out
    // the program. The second pass rewrites the image with resolved
    // labels; instruction sizes do not change between the passes.
    fn pass(self: *Assembler, record_labels: bool) void {
        self.pc = 0;
        var lines = std.mem.splitScalar(u8, self.work, '\n');
        while (lines.next()) |raw| {
            const line = parseLine(@constCast(raw));
            if (line.mnemonic.len == 0 and line.label == null) continue;

            if (line.label) |name| {
                if (record_labels) {
                    if (self.symbols.contains(name)) {
                        self.fail("duplicate label: {s}", .{name});
                        return;
                    }
                    const key = self.allocator.dupe(u8, name) catch {
                        self.fail("out of memory", .{});
                        return;
                    };
                    self.symbols.put(key, self.pc) catch {
                        self.allocator.free(key);
                        self.fail("out of memory", .{});
                        return;
                    };
                }
            }
            if (line.mnemonic.len == 0) continue;

            if (self.emitDirective(line)) continue;
            self.emitInstruction(line);
            if (self.error_len != 0) return;
        }
    }
};

pub fn assembleSource(allocator: std.mem.Allocator, source: []const u8) !Assembler {
    const image = try allocator.alloc(u8, ImageSize);
    @memset(image, 0);
    const work = try allocator.dupe(u8, source);
    var assembler = Assembler{
        .allocator = allocator,
        .image = image,
        .symbols = std.StringHashMap(u16).init(allocator),
        .work = work,
    };
    errdefer assembler.deinit();
    assembler.pass(true);
    assembler.final_pass = true;
    assembler.pass(false);
    return assembler;
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
        std.debug.print(
            \\gbasm - SM83 assembler for Dot Matrix Deck fixtures
            \\Usage:
            \\  {s} <asm-dir> <rom-dir>
            \\
        , .{argv[0]});
        std.process.exit(2);
    }

    const asm_dir_path = argv[1];
    const rom_dir_path = argv[2];

    var asm_dir = try std.Io.Dir.cwd().openDir(io, asm_dir_path, .{ .iterate = true });
    defer asm_dir.close(io);
    var rom_dir = try std.Io.Dir.cwd().openDir(io, rom_dir_path, .{});
    defer rom_dir.close(io);

    var sources: std.ArrayList([]const u8) = .empty;
    defer {
        for (sources.items) |name| allocator.free(name);
        sources.deinit(allocator);
    }
    var iter = asm_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".asm")) {
            try sources.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var failures: usize = 0;
    for (sources.items) |name| {
        const source_path = try std.fs.path.join(allocator, &.{ asm_dir_path, name });
        defer allocator.free(source_path);

        const dir = std.Io.Dir.cwd();
        const file = try dir.openFile(io, source_path, .{});
        defer file.close(io);
        const size = try file.length(io);
        const source = try allocator.alloc(u8, @intCast(size));
        defer allocator.free(source);
        _ = try file.readPositionalAll(io, source, 0);

        var assembler = try assembleSource(allocator, source);
        defer assembler.deinit();
        if (assembler.errorText()) |error_text| {
            std.debug.print("{s}: {s}\n", .{ name, error_text });
            failures += 1;
            continue;
        }

        const out_name = std.fmt.allocPrint(allocator, "{s}.gb", .{std.mem.trimEnd(u8, name, ".asm")}) catch blk: {
            failures += 1;
            break :blk "";
        };
        defer allocator.free(out_name);
        const out_path = try std.fs.path.join(allocator, &.{ rom_dir_path, out_name });
        defer allocator.free(out_path);

        const out_file = try rom_dir.createFile(io, out_name, .{});
        defer out_file.close(io);
        try out_file.writePositionalAll(io, assembler.image, 0);
        std.debug.print("{s}: {d} bytes\n", .{ name, assembler.pc });
    }

    if (failures != 0) std.process.exit(1);
}

const testing = std.testing;

test "assembles and runs a small NOP program" {
    const allocator = testing.allocator;
    const source =
        \\org $0100
        \\nop
        \\jr done
        \\db "X", $00
        \\done:
        \\halt
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try testing.expect(assembler.errorText() == null);
    try testing.expectEqual(@as(u8, 0x00), assembler.image[0x0100]);
    try testing.expectEqual(@as(u8, 0x18), assembler.image[0x0101]);
    try testing.expectEqual(@as(u8, 0x02), assembler.image[0x0102]);
    try testing.expectEqual(@as(u8, 0x58), assembler.image[0x0103]);
    try testing.expectEqual(@as(u16, 0x0105), assembler.symbols.get("DONE").?);
    try testing.expectEqual(@as(u8, 0x76), assembler.image[0x0105]);
}

test "two-pass assembly resolves forward references" {
    const allocator = testing.allocator;
    const source =
        \\org $0100
        \\ld a, $01
        \\jp skip
        \\ld b, $02
        \\skip:
        \\cp $01
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try testing.expect(assembler.errorText() == null);
    try testing.expectEqual(@as(u8, 0x3e), assembler.image[0x0100]);
    try testing.expectEqual(@as(u8, 0xc3), assembler.image[0x0102]);
    try testing.expectEqual(@as(u16, 0x0107), @as(u16, assembler.image[0x0103]) | @as(u16, assembler.image[0x0104]) << 8);
    try testing.expectEqual(@as(u8, 0xfe), assembler.image[0x0107]);
}

test "directives emit data and pad gaps" {
    const allocator = testing.allocator;
    const source =
        \\org $0100
        \\db 1, 2
        \\dw $1234
        \\ds 2
        \\org $0108
        \\db $aa
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try testing.expect(assembler.errorText() == null);
    try testing.expectEqual(@as(u8, 1), assembler.image[0x0100]);
    try testing.expectEqual(@as(u8, 2), assembler.image[0x0101]);
    try testing.expectEqual(@as(u8, 0x34), assembler.image[0x0102]);
    try testing.expectEqual(@as(u8, 0x12), assembler.image[0x0103]);
    try testing.expectEqual(@as(u8, 0x00), assembler.image[0x0106]);
    try testing.expectEqual(@as(u8, 0xaa), assembler.image[0x0108]);
}

test "cb-prefixed instructions encode bit operations" {
    const allocator = testing.allocator;
    const source =
        \\org $0100
        \\sla a
        \\bit 1, a
        \\set 3, (hl)
        \\res 0, b
        \\rrc c
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try testing.expect(assembler.errorText() == null);
    try testing.expectEqual(@as(u8, 0xcb), assembler.image[0x0100]);
    try testing.expectEqual(@as(u8, 0x27), assembler.image[0x0101]);
    try testing.expectEqual(@as(u8, 0xcb), assembler.image[0x0102]);
    try testing.expectEqual(@as(u8, 0x4f), assembler.image[0x0103]);
    try testing.expectEqual(@as(u8, 0xcb), assembler.image[0x0104]);
    try testing.expectEqual(@as(u8, 0xde), assembler.image[0x0105]);
    try testing.expectEqual(@as(u8, 0xcb), assembler.image[0x0106]);
    try testing.expectEqual(@as(u8, 0x80), assembler.image[0x0107]);
    try testing.expectEqual(@as(u8, 0xcb), assembler.image[0x0108]);
    try testing.expectEqual(@as(u8, 0x09), assembler.image[0x0109]);
}

test "errors report the offending construct" {
    const allocator = testing.allocator;
    const source =
        \\org $0100
        \\label:
        \\label:
        \\nop
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    const error_text = assembler.errorText();
    try testing.expect(error_text != null);
    try testing.expect(std.mem.indexOf(u8, error_text.?, "duplicate label") != null);
}

test "signed stack offsets encode as two-pass values" {
    const allocator = testing.allocator;
    const source =
        \\org $0100
        \\add sp, -$02
        \\ld hl, sp+$05
        \\ld (start), sp
        \\start:
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try testing.expect(assembler.errorText() == null);
    try testing.expectEqual(@as(u8, 0xe8), assembler.image[0x0100]);
    try testing.expectEqual(@as(u8, 0xfe), assembler.image[0x0101]);
    try testing.expectEqual(@as(u8, 0xf8), assembler.image[0x0102]);
    try testing.expectEqual(@as(u8, 0x05), assembler.image[0x0103]);
    try testing.expectEqual(@as(u8, 0x08), assembler.image[0x0104]);
    try testing.expectEqual(@as(u16, 0x0107), @as(u16, assembler.image[0x0105]) | @as(u16, assembler.image[0x0106]) << 8);
}
