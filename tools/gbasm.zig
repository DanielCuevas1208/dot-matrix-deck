// gbasm - a small SM83 assembler for Game Boy test ROMs.
//
// It reads a single .asm file or a whole directory of sources and
// writes raw .gb images. The assembler targets the instruction set
// implemented by the emulator core, which is the complete 256-opcode
// SM83 set plus the CB prefix group.
//
// Directives:
//   ORG <address>   set the output position, filling gaps with zero
//   PAD <address>   alias for ORG, used to size the final image
//   DB <items>      emit bytes; items may be strings or numbers
//   DW <items>      emit little-endian 16-bit values
//   DS <count>[,<fill>]  emit <count> bytes of <fill>
//
// Numbers accept $hex, 0xhex, %binary, or decimal. Labels are written
// as `name:` and may be forward-referenced. A `;` starts a comment.

const std = @import("std");

pub const AssemblerError = error{
    Syntax,
    UnknownMnemonic,
    BadOperand,
    BadOperandCount,
    DuplicateLabel,
    UnknownSymbol,
    BranchOutOfRange,
    AddressOverlap,
    NumberOutOfRange,
    BadRstVector,
    TooManyOperands,
    OutOfMemory,
};

const reg8_names = [_][]const u8{ "B", "C", "D", "E", "H", "L", "(HL)", "A" };
const reg16_names = [_][]const u8{ "BC", "DE", "HL", "SP" };
const cond_names = [_][]const u8{ "NZ", "Z", "NC", "C" };

pub const Assembler = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    symbols: std.StringHashMap(u16),
    address: u16 = 0,
    emit: bool = false,

    pub fn init(allocator: std.mem.Allocator) Assembler {
        return .{
            .allocator = allocator,
            .output = std.ArrayList(u8).empty,
            .symbols = std.StringHashMap(u16).init(allocator),
        };
    }

    pub fn deinit(self: *Assembler) void {
        self.output.deinit(self.allocator);
        self.symbols.deinit();
    }

    pub fn assemble(self: *Assembler, source: []const u8) AssemblerError![]u8 {
        try self.runPass(source);
        self.emit = true;
        try self.runPass(source);
        return self.output.toOwnedSlice(self.allocator);
    }

    fn runPass(self: *Assembler, source: []const u8) AssemblerError!void {
        self.address = 0;
        self.output.clearRetainingCapacity();

        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const comment = std.mem.indexOfScalar(u8, raw_line, ';');
            const line = std.mem.trim(u8, raw_line[0 .. comment orelse raw_line.len], " \t\r");
            if (line.len == 0) continue;

            var rest = line;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const candidate = line[0..colon];
                if (candidate.len != 0 and std.mem.indexOfAny(u8, candidate, " \t") == null) {
                    try self.defineLabel(candidate);
                    rest = std.mem.trim(u8, line[colon + 1 ..], " \t");
                    if (rest.len == 0) continue;
                }
            }

            const mnemonic = nextToken(rest);
            const operands = std.mem.trim(u8, rest[mnemonic.len..], " \t");
            try self.emitLine(mnemonic, operands);
        }
    }

    fn defineLabel(self: *Assembler, name: []const u8) AssemblerError!void {
        if (self.emit) return;
        const gop = try self.symbols.getOrPut(name);
        if (gop.found_existing) return error.DuplicateLabel;
        gop.value_ptr.* = self.address;
    }

    fn emitLine(self: *Assembler, mnemonic_in: []const u8, operands: []const u8) AssemblerError!void {
        const mnemonic = mnemonic_in;

        if (eqlI(mnemonic, "ORG") or eqlI(mnemonic, "PAD")) {
            const target = try self.eval(operands);
            if (target < 0) return error.AddressOverlap;
            const fill_to: u16 = @intCast(target);
            if (fill_to < self.address) return error.AddressOverlap;
            while (self.address < fill_to) try self.emitByte(0x00);
            return;
        }
        if (eqlI(mnemonic, "DB")) return self.emitData(operands, false);
        if (eqlI(mnemonic, "DW")) return self.emitData(operands, true);
        if (eqlI(mnemonic, "DS")) return self.emitSpace(operands);
        return self.encode(mnemonic, operands);
    }

    fn emitData(self: *Assembler, operands: []const u8, wide: bool) AssemblerError!void {
        var items: [64][]const u8 = undefined;
        const count = try splitItems(operands, &items);
        for (items[0..count]) |item| {
            if (item.len >= 2 and item[0] == '"' and item[item.len - 1] == '"') {
                const text = item[1 .. item.len - 1];
                if (wide) {
                    for (text) |byte| {
                        try self.emitByte(byte);
                        try self.emitByte(0);
                    }
                } else {
                    for (text) |byte| try self.emitByte(byte);
                }
                continue;
            }
            const value = try self.eval(item);
            if (wide) {
                if (value < 0 or value > 0xffff) return error.NumberOutOfRange;
                const word: u16 = @intCast(value);
                try self.emitByte(@truncate(word));
                try self.emitByte(@truncate(word >> 8));
            } else {
                if (value < -128 or value > 0xff) return error.NumberOutOfRange;
                try self.emitByte(lowByte(value));
            }
        }
    }

    fn emitSpace(self: *Assembler, operands: []const u8) AssemblerError!void {
        var items: [2][]const u8 = undefined;
        const count = try splitItems(operands, &items);
        if (count < 1 or count > 2) return error.BadOperandCount;
        const length = try self.eval(items[0]);
        if (length < 0 or length > 0xffff) return error.NumberOutOfRange;
        const fill: u8 = if (count == 2) blk: {
            const value = try self.eval(items[1]);
            if (value < 0 or value > 0xff) return error.NumberOutOfRange;
            break :blk @intCast(value);
        } else 0;
        var remaining: usize = @intCast(length);
        while (remaining != 0) : (remaining -= 1) try self.emitByte(fill);
    }

    fn emitByte(self: *Assembler, value: u8) AssemblerError!void {
        if (self.emit) self.output.append(self.allocator, value) catch return error.OutOfMemory;
        self.address +%= 1;
    }

    // Parses a signed expression: numbers, labels, and + and - terms.
    fn eval(self: *Assembler, text_in: []const u8) AssemblerError!i32 {
        const text = std.mem.trim(u8, text_in, " \t");
        if (text.len == 0) return error.Syntax;
        var total: i32 = 0;
        var sign: i32 = 1;
        var index: usize = 0;
        while (index < text.len) {
            const ch = text[index];
            if (ch == '+' or ch == '-') {
                sign = if (ch == '+') 1 else -1;
                index += 1;
                continue;
            }
            const start = index;
            while (index < text.len and text[index] != '+' and text[index] != '-') index += 1;
            const term = text[start..index];
            total += sign * try self.evalTerm(term);
            sign = 1;
        }
        return total;
    }

    fn evalTerm(self: *Assembler, term: []const u8) AssemblerError!i32 {
        if (term.len == 0) return error.Syntax;
        const value = self.parseNumber(term) orelse blk: {
            if (self.symbols.get(term)) |symbol_value| break :blk @as(i32, symbol_value);
            if (!self.emit) break :blk 0; // forward reference during the sizing pass
            return error.UnknownSymbol;
        };
        return value;
    }

    fn parseNumber(self: *Assembler, term: []const u8) ?i32 {
        _ = self;
        if (term.len >= 2 and term[0] == '$') return parseRadix(term[1..], 16) orelse return null;
        if (term.len >= 3 and term[0] == '0' and (term[1] == 'x' or term[1] == 'X')) return parseRadix(term[2..], 16) orelse return null;
        if (term.len >= 2 and term[0] == '%') return parseRadix(term[1..], 2) orelse return null;
        if (term[0] >= '0' and term[0] <= '9') return parseRadix(term, 10) orelse return null;
        return null;
    }

    fn encode(self: *Assembler, mnemonic: []const u8, operands: []const u8) AssemblerError!void {
        var parts: [4][]const u8 = undefined;
        const count = try splitItems(operands, &parts);

        if (eqlI(mnemonic, "LD")) return self.encodeLd(parts[0..count], count);
        if (eqlI(mnemonic, "LDH")) return self.encodeLdh(parts[0..count], count);

        const op: ?u3 = blk: {
            const names = [_][]const u8{ "ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP" };
            for (names, 0..) |name, i| {
                if (eqlI(mnemonic, name)) break :blk @as(u3, @intCast(i));
            }
            break :blk null;
        };

        if (op) |alu_op| return self.encodeAlu(alu_op, parts[0..count], count);

        if (eqlI(mnemonic, "INC")) return self.encodeIncDec(parts[0..count], count, true);
        if (eqlI(mnemonic, "DEC")) return self.encodeIncDec(parts[0..count], count, false);
        if (eqlI(mnemonic, "JP")) return self.encodeJp(parts[0..count], count);
        if (eqlI(mnemonic, "JR")) return self.encodeJr(parts[0..count], count);
        if (eqlI(mnemonic, "CALL")) return self.encodeCall(parts[0..count], count);
        if (eqlI(mnemonic, "RET")) return self.encodeRet(parts[0..count], count);
        if (eqlI(mnemonic, "RETI")) {
            if (count != 0) return error.BadOperandCount;
            return self.emitByte(0xd9);
        }
        if (eqlI(mnemonic, "RST")) return self.encodeRst(parts[0..count], count);
        if (eqlI(mnemonic, "PUSH") or eqlI(mnemonic, "POP")) return self.encodePushPop(mnemonic, parts[0..count], count);
        if (eqlI(mnemonic, "RLC") or eqlI(mnemonic, "RRC") or
            eqlI(mnemonic, "RL") or eqlI(mnemonic, "RR") or
            eqlI(mnemonic, "SLA") or eqlI(mnemonic, "SRA") or
            eqlI(mnemonic, "SWAP") or eqlI(mnemonic, "SRL")) return self.encodeShift(mnemonic, parts[0..count], count);
        if (eqlI(mnemonic, "BIT") or eqlI(mnemonic, "RES") or eqlI(mnemonic, "SET")) return self.encodeBitOp(mnemonic, parts[0..count], count);

        const zero_arg = [_][]const u8{ "NOP", "HALT", "DI", "EI", "RLCA", "RLA", "RRCA", "RRA", "DAA", "CPL", "SCF", "CCF" };
        const zero_bytes = [_]u8{ 0x00, 0x76, 0xf3, 0xfb, 0x07, 0x17, 0x0f, 0x1f, 0x27, 0x2f, 0x37, 0x3f };
        for (zero_arg, 0..) |name, i| {
            if (eqlI(mnemonic, name)) {
                if (count != 0) return error.BadOperandCount;
                return self.emitByte(zero_bytes[i]);
            }
        }

        if (eqlI(mnemonic, "STOP")) {
            if (count != 0) return error.BadOperandCount;
            try self.emitByte(0x10);
            return self.emitByte(0x00);
        }

        return error.UnknownMnemonic;
    }

    fn encodeLd(self: *Assembler, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count != 2) return error.BadOperandCount;
        const dst = parts[0];
        const src = parts[1];

        if (std.mem.eql(u8, dst, "(C)") and std.mem.eql(u8, src, "A")) return self.emitByte(0xe2);
        if (std.mem.eql(u8, dst, "A") and std.mem.eql(u8, src, "(C)")) return self.emitByte(0xf2);
        if (std.mem.eql(u8, dst, "(BC)") and std.mem.eql(u8, src, "A")) return self.emitByte(0x02);
        if (std.mem.eql(u8, dst, "(DE)") and std.mem.eql(u8, src, "A")) return self.emitByte(0x12);
        if (std.mem.eql(u8, dst, "(HL)") and std.mem.eql(u8, src, "A")) return self.emitByte(0x77);
        if (std.mem.eql(u8, dst, "(HL+)") and std.mem.eql(u8, src, "A")) return self.emitByte(0x22);
        if (std.mem.eql(u8, dst, "(HL-)") and std.mem.eql(u8, src, "A")) return self.emitByte(0x32);
        if (std.mem.eql(u8, dst, "A") and std.mem.eql(u8, src, "(BC)")) return self.emitByte(0x0a);
        if (std.mem.eql(u8, dst, "A") and std.mem.eql(u8, src, "(DE)")) return self.emitByte(0x1a);
        if (std.mem.eql(u8, dst, "A") and std.mem.eql(u8, src, "(HL)")) return self.emitByte(0x7e);
        if (std.mem.eql(u8, dst, "A") and std.mem.eql(u8, src, "(HL+)")) return self.emitByte(0x2a);
        if (std.mem.eql(u8, dst, "A") and std.mem.eql(u8, src, "(HL-)")) return self.emitByte(0x3a);
        if (std.mem.eql(u8, dst, "SP") and std.mem.eql(u8, src, "HL")) return self.emitByte(0xf9);

        if (std.mem.eql(u8, dst, "HL") and startsWith(src, "SP+")) return self.encodeLdHlSp(0xf8, src[3..]);
        if (std.mem.eql(u8, dst, "HL") and startsWith(src, "SP-")) return self.encodeLdHlSpSigned(0xf8, src[3..]);

        if (isAddress(dst)) {
            const address = try self.eval(dst[1 .. dst.len - 1]);
            if (std.mem.eql(u8, src, "SP")) {
                if (address < 0 or address > 0xffff) return error.NumberOutOfRange;
                try self.emitByte(0x08);
                try self.emitByte(@truncate(@as(u16, @intCast(address))));
                return self.emitByte(@truncate(@as(u16, @intCast(address)) >> 8));
            }
            if (std.mem.eql(u8, src, "A")) {
                if (address < 0 or address > 0xffff) return error.NumberOutOfRange;
                try self.emitByte(0xea);
                try self.emitByte(@truncate(@as(u16, @intCast(address))));
                return self.emitByte(@truncate(@as(u16, @intCast(address)) >> 8));
            }
        }
        if (std.mem.eql(u8, dst, "A") and isAddress(src)) {
            const address = try self.eval(src[1 .. src.len - 1]);
            if (address < 0 or address > 0xffff) return error.NumberOutOfRange;
            try self.emitByte(0xfa);
            try self.emitByte(@truncate(@as(u16, @intCast(address))));
            return self.emitByte(@truncate(@as(u16, @intCast(address)) >> 8));
        }

        if (reg16Index(dst)) |pair| {
            const value = try self.eval(src);
            if (value < 0 or value > 0xffff) return error.NumberOutOfRange;
            try self.emitByte(0x01 | @as(u8, pair) << 4);
            try self.emitByte(@truncate(@as(u16, @intCast(value))));
            return self.emitByte(@truncate(@as(u16, @intCast(value)) >> 8));
        }

        if (reg8Index(dst)) |dest_reg| {
            if (reg8Index(src)) |source_reg| {
                if (dest_reg == 6 and source_reg == 6) return error.BadOperand;
                return self.emitByte(0x40 | @as(u8, dest_reg) << 3 | @as(u8, source_reg));
            }
            const value = try self.eval(src);
            try self.emitByte(0x06 | @as(u8, dest_reg) << 3);
            return self.emitByte(lowByte(value));
        }

        return error.BadOperand;
    }

    fn encodeLdHlSp(self: *Assembler, opcode: u8, offset_text: []const u8) AssemblerError!void {
        const offset = try self.eval(offset_text);
        try self.emitByte(opcode);
        return self.emitByte(lowByte(offset));
    }

    fn encodeLdHlSpSigned(self: *Assembler, opcode: u8, offset_text: []const u8) AssemblerError!void {
        const offset = -(try self.eval(offset_text));
        try self.emitByte(opcode);
        return self.emitByte(lowByte(offset));
    }

    fn encodeLdh(self: *Assembler, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count != 2) return error.BadOperandCount;
        const dst = parts[0];
        const src = parts[1];
        if (std.mem.eql(u8, dst, "(C)") and std.mem.eql(u8, src, "A")) return self.emitByte(0xe2);
        if (std.mem.eql(u8, dst, "A") and std.mem.eql(u8, src, "(C)")) return self.emitByte(0xf2);
        if (isAddress(dst) and std.mem.eql(u8, src, "A")) {
            const value = try self.eval(dst[1 .. dst.len - 1]);
            try self.emitByte(0xe0);
            return self.emitByte(lowByte(value));
        }
        if (std.mem.eql(u8, dst, "A") and isAddress(src)) {
            const value = try self.eval(src[1 .. src.len - 1]);
            try self.emitByte(0xf0);
            return self.emitByte(lowByte(value));
        }
        return error.BadOperand;
    }

    fn encodeAlu(self: *Assembler, operation: u3, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count == 2) {
            const dst = parts[0];
            const src = parts[1];
            if (operation == 0 and std.mem.eql(u8, dst, "HL")) {
                if (reg16Index(src)) |pair| return self.emitByte(0x09 | @as(u8, pair) << 4);
            }
            if (operation == 0 and std.mem.eql(u8, dst, "SP")) {
                if (startsWith(src, "+")) return self.encodeLdHlSp(0xe8, src[1..]);
                if (startsWith(src, "-")) return self.encodeLdHlSpSigned(0xe8, src[1..]);
                return self.encodeLdHlSp(0xe8, src);
            }
            if (!std.mem.eql(u8, dst, "A")) return error.BadOperand;
            if (reg8Index(src)) |source_reg| return self.emitByte(0x80 | @as(u8, operation) << 3 | source_reg);
            const value = try self.eval(src);
            try self.emitByte(0xc6 | @as(u8, operation) << 3);
            return self.emitByte(lowByte(value));
        }
        if (count == 1) {
            if (reg8Index(parts[0])) |source_reg| return self.emitByte(0x80 | @as(u8, operation) << 3 | source_reg);
            const value = try self.eval(parts[0]);
            try self.emitByte(0xc6 | @as(u8, operation) << 3);
            return self.emitByte(lowByte(value));
        }
        return error.BadOperandCount;
    }

    fn encodeIncDec(self: *Assembler, parts: []const []const u8, count: usize, increment: bool) AssemblerError!void {
        if (count != 1) return error.BadOperandCount;
        if (reg8Index(parts[0])) |reg| {
            const base: u8 = if (increment) 0x04 else 0x05;
            return self.emitByte(base | @as(u8, reg) << 3);
        }
        if (reg16Index(parts[0])) |pair| {
            const base: u8 = if (increment) 0x03 else 0x0b;
            return self.emitByte(base | @as(u8, pair) << 4);
        }
        return error.BadOperand;
    }

    fn encodeJp(self: *Assembler, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count == 1) {
            if (std.mem.eql(u8, parts[0], "(HL)")) return self.emitByte(0xe9);
            const target = try self.eval(parts[0]);
            return self.emitAddress(0xc3, target);
        }
        if (count == 2) {
            if (condIndex(parts[0])) |condition| {
                const target = try self.eval(parts[1]);
                return self.emitAddress(0xc2 | @as(u8, condition) << 3, target);
            }
        }
        return error.BadOperand;
    }

    fn encodeJr(self: *Assembler, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count < 1 or count > 2) return error.BadOperandCount;
        const base: u8 = if (count == 1) 0x18 else 0x20 | @as(u8, condIndex(parts[0]) orelse return error.BadOperand) << 3;
        const target_text = if (count == 1) parts[0] else parts[1];
        const target = try self.eval(target_text);
        const after = @as(i32, self.address) + 2;
        const displacement = target - after;
        if (self.emit and (displacement < -128 or displacement > 127)) return error.BranchOutOfRange;
        try self.emitByte(base);
        return self.emitByte(lowByte(displacement));
    }

    fn encodeCall(self: *Assembler, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count == 1) {
            const target = try self.eval(parts[0]);
            return self.emitAddress(0xcd, target);
        }
        if (count == 2) {
            if (condIndex(parts[0])) |condition| {
                const target = try self.eval(parts[1]);
                return self.emitAddress(0xc4 | @as(u8, condition) << 3, target);
            }
        }
        return error.BadOperand;
    }

    fn encodeRet(self: *Assembler, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count == 0) return self.emitByte(0xc9);
        if (count == 1) {
            if (condIndex(parts[0])) |condition| return self.emitByte(0xc0 | @as(u8, condition) << 3);
        }
        return error.BadOperand;
    }

    fn encodeRst(self: *Assembler, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count != 1) return error.BadOperandCount;
        const vector = try self.eval(parts[0]);
        if (vector < 0 or vector > 0x38 or (vector & 0x07) != 0) return error.BadRstVector;
        return self.emitByte(0xc7 | @as(u8, @intCast(vector)));
    }

    fn encodePushPop(self: *Assembler, mnemonic: []const u8, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count != 1) return error.BadOperandCount;
        const names = [_][]const u8{ "BC", "DE", "HL", "AF" };
        for (names, 0..) |name, i| {
            if (std.mem.eql(u8, parts[0], name)) {
                const base: u8 = if (eqlI(mnemonic, "PUSH")) 0xc5 else 0xc1;
                return self.emitByte(base | @as(u8, @intCast(i)) << 4);
            }
        }
        return error.BadOperand;
    }

    fn encodeShift(self: *Assembler, mnemonic: []const u8, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count != 1) return error.BadOperandCount;
        const reg = reg8Index(parts[0]) orelse return error.BadOperand;
        const names = [_][]const u8{ "RLC", "RRC", "RL", "RR", "SLA", "SRA", "SWAP", "SRL" };
        var operation: u8 = 0;
        for (names, 0..) |name, i| {
            if (eqlI(mnemonic, name)) {
                operation = @intCast(i);
                break;
            }
        }
        try self.emitByte(0xcb);
        return self.emitByte(operation << 3 | reg);
    }

    fn encodeBitOp(self: *Assembler, mnemonic: []const u8, parts: []const []const u8, count: usize) AssemblerError!void {
        if (count != 2) return error.BadOperandCount;
        const bit_value = try self.eval(parts[0]);
        if (bit_value < 0 or bit_value > 7) return error.NumberOutOfRange;
        const reg = reg8Index(parts[1]) orelse return error.BadOperand;
        const base: u8 = if (eqlI(mnemonic, "BIT")) 0x40 else if (eqlI(mnemonic, "RES")) 0x80 else 0xc0;
        try self.emitByte(0xcb);
        return self.emitByte(base | @as(u8, @intCast(bit_value)) << 3 | reg);
    }

    fn emitAddress(self: *Assembler, opcode: u8, value: i32) AssemblerError!void {
        if (value < 0 or value > 0xffff) return error.NumberOutOfRange;
        const word: u16 = @intCast(value);
        try self.emitByte(opcode);
        try self.emitByte(@truncate(word));
        return self.emitByte(@truncate(word >> 8));
    }
};

fn reg8Index(text: []const u8) ?u3 {
    for (reg8_names, 0..) |name, i| {
        if (std.mem.eql(u8, text, name)) return @intCast(i);
    }
    return null;
}

fn reg16Index(text: []const u8) ?u2 {
    for (reg16_names, 0..) |name, i| {
        if (std.mem.eql(u8, text, name)) return @intCast(i);
    }
    return null;
}

fn condIndex(text: []const u8) ?u2 {
    for (cond_names, 0..) |name, i| {
        if (std.mem.eql(u8, text, name)) return @intCast(i);
    }
    return null;
}

fn isAddress(text: []const u8) bool {
    return text.len >= 3 and text[0] == '(' and text[text.len - 1] == ')' and
        !std.mem.eql(u8, text, "(HL)") and !std.mem.eql(u8, text, "(HL+)") and
        !std.mem.eql(u8, text, "(HL-)") and !std.mem.eql(u8, text, "(BC)") and
        !std.mem.eql(u8, text, "(DE)") and !std.mem.eql(u8, text, "(C)");
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
}

fn eqlI(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// Low byte of a signed value in two's complement form.
fn lowByte(value: i32) u8 {
    return @truncate(@as(u32, @bitCast(value)));
}

fn nextToken(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    return text[0..end];
}

// Splits comma-separated items, keeping quoted strings intact.
fn splitItems(text: []const u8, items: [][]const u8) AssemblerError!usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and (text[index] == ' ' or text[index] == '\t' or text[index] == ',')) index += 1;
        if (index >= text.len) break;
        const start = index;
        var in_string = false;
        while (index < text.len) : (index += 1) {
            const ch = text[index];
            if (ch == '"') in_string = !in_string;
            if (ch == ',' and !in_string) break;
        }
        if (count == items.len) return error.TooManyOperands;
        items[count] = text[start..index];
        count += 1;
    }
    return count;
}

fn parseRadix(digits: []const u8, base: u8) ?i32 {
    var value: i64 = 0;
    for (digits) |digit| {
        const nibble: i64 = switch (digit) {
            '0'...'9' => digit - '0',
            'a'...'f' => digit - 'a' + 10,
            'A'...'F' => digit - 'A' + 10,
            else => return null,
        };
        if (nibble >= base) return null;
        value = value * base + nibble;
        if (value > 0x7fffffff) return null;
    }
    return @intCast(value);
}

const testing = std.testing;

fn assembleBytes(source: []const u8) ![]u8 {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    return assembler.assemble(source);
}

test "assembles a minimal program" {
    const bytes = try assembleBytes(
        \\    ORG $0100
        \\    JP start
        \\start:
        \\    LD A,$12
        \\    HALT
        \\
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xc3, 0x03, 0x01, 0x3e, 0x12, 0x76 }, bytes[0x0100..]);
}

test "assembles register moves and arithmetic" {
    const bytes = try assembleBytes(
        \\    LD B,A
        \\    LD C,(HL)
        \\    ADD A,B
        \\    ADC A,(HL)
        \\    SUB B
        \\    XOR A
        \\    CP $40
        \\    INC (HL)
        \\    DEC B
        \\    INC HL
        \\    ADD HL,DE
        \\    ADD SP,-$06
        \\
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x47, 0x4e, 0x80, 0x8e, 0x90, 0xaf, 0xfe, 0x40, 0x34, 0x05, 0x23, 0x19, 0xe8, 0xfa }, bytes);
}

test "assembles jumps, calls, and stack operations" {
    const bytes = try assembleBytes(
        \\    ORG $0200
        \\    JP target
        \\    JR NZ,target
        \\    CALL Z,target
        \\    PUSH HL
        \\    POP AF
        \\    RET
        \\    RETI
        \\    RST $38
        \\    JP (HL)
        \\target:
        \\    NOP
        \\
    );
    defer testing.allocator.free(bytes);
    const expected = [_]u8{
        0xc3, 0x0e, 0x02,
        0x20, 0x09, 0xcc,
        0x0e, 0x02, 0xe5,
        0xf1, 0xc9, 0xd9,
        0xff, 0xe9, 0x00,
    };
    try testing.expectEqualSlices(u8, &expected, bytes[0x0200..]);
}

test "assembles CB prefix group" {
    const bytes = try assembleBytes(
        \\    RLC A
        \\    SRA (HL)
        \\    BIT 3,L
        \\    SET 7,(HL)
        \\    RES 0,A
        \\
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xcb, 0x07, 0xcb, 0x2e, 0xcb, 0x5d, 0xcb, 0xfe, 0xcb, 0x87 }, bytes);
}

test "assembles ldh and memory forms" {
    const bytes = try assembleBytes(
        \\    LDH ($FF44),A
        \\    LDH A,($FF40)
        \\    LD (C),A
        \\    LD A,(C)
        \\    LD (BC),A
        \\    LD A,(HL+)
        \\    LD (HL-),A
        \\    LD (MAP),SP
        \\    LD HL,SP+$10
        \\    ORG $3000
        \\MAP:
        \\
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xe0, 0x44, 0xf0, 0x40, 0xe2, 0xf2, 0x02, 0x2a, 0x32, 0x08, 0x00, 0x30, 0xf8, 0x10 }, bytes[0..14]);
    try testing.expectEqual(@as(u16, 0x3000), bytes.len);
}

test "assembles data directives and pads to size" {
    const bytes = try assembleBytes(
        \\    ORG $0000
        \\    DB "Passed", $0A, $00
        \\    DW $1234
        \\    DS 3,$FF
        \\    PAD $0010
        \\
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0x10), bytes.len);
    try testing.expectEqualSlices(u8, "Passed", bytes[0..6]);
    try testing.expectEqual(@as(u8, 0x0a), bytes[6]);
    try testing.expectEqual(@as(u8, 0x00), bytes[7]);
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, bytes[8..10]);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff }, bytes[10..13]);
}

test "backward branch encodes the right displacement" {
    const bytes = try assembleBytes(
        \\    ORG $1000
        \\loop:
        \\    JR loop
        \\
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x18, 0xfe }, bytes[0x1000..]);
}

test "forward branch over data" {
    const bytes = try assembleBytes(
        \\    ORG $0100
        \\    JR skip
        \\    DB $00, $00, $00
        \\skip:
        \\    NOP
        \\
    );
    defer testing.allocator.free(bytes);
    // JR is two bytes; skip is at 0105, so displacement is 0105-0102 = 3.
    try testing.expectEqualSlices(u8, &.{ 0x18, 0x03 }, bytes[0x0100..0x0102]);
    try testing.expectEqual(@as(u8, 0x00), bytes[0x0105]);
}

test "rejects a branch out of range" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    const source =
        \\    ORG $0000
        \\    JR far
        \\    DS $100,$00
        \\far:
        \\
    ;
    try testing.expectError(AssemblerError.BranchOutOfRange, assembler.assemble(source));
}

test "rejects an unknown mnemonic" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    try testing.expectError(AssemblerError.UnknownMnemonic, assembler.assemble("    BOGUS\n"));
}

test "rejects a duplicate label" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    try testing.expectError(AssemblerError.DuplicateLabel, assembler.assemble(
        \\start:
        \\start:
        \\
    ));
}

fn usage(program: []const u8) void {
    std.debug.print(
        \\gbasm - SM83 assembler for Game Boy test ROMs
        \\Usage:
        \\  {s} <input.asm> [output.gb]
        \\  {s} <asm-directory> <output-directory>
        \\
        \\Assembles every .asm file in the directory mode and writes a
        \\matching .gb image next to each source name.
        \\
    , .{ program, program });
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

fn isDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn assembleOne(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const source = try readFile(io, allocator, input_path);
    defer allocator.free(source);

    var assembler = Assembler.init(allocator);
    defer assembler.deinit();
    const image = assembler.assemble(source) catch |err| {
        std.debug.print("{s}: error {s}\n", .{ input_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(image);

    if (std.fs.path.dirname(output_path)) |parent| {
        if (parent.len != 0) {
            std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
                std.debug.print("{s}: create error {s}\n", .{ parent, @errorName(err) });
                std.process.exit(1);
            };
        }
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = image }) catch |err| {
        std.debug.print("{s}: write error {s}\n", .{ output_path, @errorName(err) });
        std.process.exit(1);
    };
    std.debug.print("{s} -> {s} ({d} bytes)\n", .{ input_path, output_path, image.len });
}

fn assembleDirectory(io: std.Io, allocator: std.mem.Allocator, input_dir: []const u8, output_dir: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, output_dir) catch |err| {
        std.debug.print("{s}: create error {s}\n", .{ output_dir, @errorName(err) });
        std.process.exit(1);
    };

    var dir = try std.Io.Dir.cwd().openDir(io, input_dir, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
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

    if (names.items.len == 0) {
        std.debug.print("no .asm sources found in {s}\n", .{input_dir});
        std.process.exit(1);
    }

    for (names.items) |name| {
        defer allocator.free(name);
        const input_path = try std.fs.path.join(allocator, &.{ input_dir, name });
        defer allocator.free(input_path);
        const base = name[0 .. name.len - 4];
        const output_name = try std.fmt.allocPrint(allocator, "{s}.gb", .{base});
        defer allocator.free(output_name);
        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_name });
        defer allocator.free(output_path);
        try assembleOne(io, allocator, input_path, output_path);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| try args.append(allocator, arg);

    if (args.items.len < 2 or args.items.len > 3) {
        usage(args.items[0]);
        std.process.exit(2);
    }

    if (isDirectory(io, args.items[1])) {
        if (args.items.len != 3) {
            usage(args.items[0]);
            std.process.exit(2);
        }
        return assembleDirectory(io, allocator, args.items[1], args.items[2]);
    }

    const input = args.items[1];
    const output = if (args.items.len == 3) args.items[2] else blk: {
        break :blk try std.fmt.allocPrint(allocator, "{s}.gb", .{input[0 .. input.len - 4]});
    };
    defer if (args.items.len == 2) allocator.free(output);
    return assembleOne(io, allocator, input, output);
}
