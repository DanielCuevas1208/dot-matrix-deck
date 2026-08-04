const std = @import("std");
const Bus = @import("bus.zig").Bus;

// A complete disassembler for the SM83. It reads bytes through the bus
// without side effects and formats each instruction as a mnemonic line.
// It powers headless --trace mode and the interactive debugger.

pub const Instruction = struct {
    text: [32]u8,
    len: usize,
    cycles: u8,
};

const r8_names = [_][]const u8{ "B", "C", "D", "E", "H", "L", "(HL)", "A" };
const r16_names = [_][]const u8{ "BC", "DE", "HL", "SP" };

fn r8(index: u8) []const u8 {
    return r8_names[index & 7];
}

fn r16(index: u8) []const u8 {
    return r16_names[index & 3];
}

fn condName(index: u8) []const u8 {
    return switch (index & 3) {
        0 => "NZ",
        1 => "Z",
        2 => "NC",
        3 => "C",
    };
}

const Writer = struct {
    buffer: [32]u8 = [_]u8{0} ** 32,
    len: usize = 0,

    fn put(self: *Writer, part: []const u8) void {
        const remaining = self.buffer.len - self.len;
        const count = @min(remaining, part.len);
        @memcpy(self.buffer[self.len .. self.len + count], part[0..count]);
        self.len += count;
    }

    fn putFmt(self: *Writer, comptime format: []const u8, args: anytype) void {
        const formatted = std.fmt.bufPrint(self.buffer[self.len..], format, args) catch return;
        self.len += formatted.len;
    }

    fn byte(self: *Writer, value: u8) void {
        self.putFmt("${X:0>2}", .{value});
    }

    fn word(self: *Writer, value: u16) void {
        self.putFmt("${X:0>4}", .{value});
    }

    fn offset(self: *Writer, origin: u16, signed: i8) void {
        self.putFmt("${X:0>4}", .{origin +% @as(u16, @bitCast(@as(i16, signed)))});
    }

    fn putLD16(self: *Writer, name: []const u8, hi: u8, lo: u8) void {
        self.putFmt("LD {s},${X:0>4}", .{ name, @as(u16, hi) << 8 | lo });
    }

    fn putLDW(self: *Writer, hi: u8, lo: u8) void {
        self.putFmt("LD (${X:0>4}),SP", .{@as(u16, hi) << 8 | lo});
    }

    fn putINC16(self: *Writer, name: []const u8) void {
        self.putFmt("INC {s}", .{name});
    }

    fn putDEC16(self: *Writer, index: u8) void {
        self.putFmt("DEC {s}", .{r16_names[index & 3]});
    }

    fn putINCDEC8(self: *Writer, op: []const u8, index: u8) void {
        self.putFmt("{s} {s}", .{ op, r8(index) });
    }

    fn putLDIMM(self: *Writer, index: u8, value: u8) void {
        self.putFmt("LD {s},", .{r8(index)});
        self.byte(value);
    }

    fn putADD16(self: *Writer, name: []const u8) void {
        self.putFmt("ADD HL,{s}", .{name});
    }

    fn putJR(self: *Writer, flag: []const u8, pc: u16, signed: i8) void {
        if (flag.len != 0) {
            self.putFmt("JR {s},", .{flag});
        } else {
            self.put("JR ");
        }
        self.offset(pc, signed);
    }

    fn putRETC(self: *Writer, flag: []const u8) void {
        self.putFmt("RET {s}", .{flag});
    }

    fn putPOP(self: *Writer, index: u8) void {
        self.putFmt("POP {s}", .{r16_names[index & 3]});
    }

    fn putPUSH(self: *Writer, index: u8) void {
        self.putFmt("PUSH {s}", .{r16_names[index & 3]});
    }

    fn putJPC(self: *Writer, flag: []const u8, hi: u8, lo: u8) void {
        self.putFmt("JP {s},${X:0>4}", .{ flag, @as(u16, hi) << 8 | lo });
    }

    fn putJP(self: *Writer, hi: u8, lo: u8) void {
        self.putFmt("JP ${X:0>4}", .{@as(u16, hi) << 8 | lo});
    }

    fn putCALL(self: *Writer, flag: []const u8, hi: u8, lo: u8) void {
        if (flag.len != 0) {
            self.putFmt("CALL {s},", .{flag});
        } else {
            self.put("CALL ");
        }
        self.word(@as(u16, hi) << 8 | lo);
    }

    fn putALUIMM(self: *Writer, name: []const u8, value: u8) void {
        self.putFmt("{s} A,", .{name});
        self.byte(value);
    }

    fn putRST(self: *Writer, address: u8) void {
        self.putFmt("RST ${X:0>2}", .{address});
    }

    fn putLD8(self: *Writer, dst: []const u8, src: []const u8) void {
        self.putFmt("LD {s},{s}", .{ dst, src });
    }

    fn putLDIMM8(self: *Writer, address: u16, reg: []const u8) void {
        self.putFmt("LDH (${X:0>2}),{s}", .{ address & 0xff, reg });
    }

    fn putLDA16(self: *Writer, hi: u8, lo: u8) void {
        self.putFmt("LD A,(${X:0>4})", .{@as(u16, hi) << 8 | lo});
    }

    fn putADDSP(self: *Writer, pc: u16, signed: u8) void {
        self.put("ADD SP,");
        const value: i8 = @bitCast(signed);
        if (value < 0) self.putFmt("-${X}", .{@as(u8, @intCast(-@as(i16, value)))}) else self.putFmt("+${X}", .{signed});
        _ = pc;
    }

    fn putLDHLSP(self: *Writer, pc: u16, signed: u8) void {
        self.put("LD HL,SP");
        const value: i8 = @bitCast(signed);
        if (value < 0) self.putFmt("-${X}", .{@as(u8, @intCast(-@as(i16, value)))}) else self.putFmt("+${X}", .{signed});
        _ = pc;
    }
};

const Fetch = struct {
    bus: *Bus,
    pc: u16,

    fn byte(fetch: *Fetch, index: usize) u8 {
        return fetch.bus.read(fetch.pc + @as(u16, @intCast(index)));
    }
};

pub fn formatAt(bus: *Bus, pc: u16) Instruction {
    var fetch = Fetch{ .bus = bus, .pc = pc };
    const opcode = fetch.byte(0);
    var writer = Writer{};
    var len: usize = 1;
    var cycles: u8 = 4;

    if (opcode == 0xcb) {
        const sub = fetch.byte(1);
        len = 2;
        const operation = sub >> 3;
        const target: u8 = sub & 7;
        const base = switch (operation) {
            0 => "RLC",
            1 => "RRC",
            2 => "RL",
            3 => "RR",
            4 => "SLA",
            5 => "SRA",
            6 => "SWAP",
            else => "SRL",
        };
        if (operation < 8) {
            writer.put(base);
            writer.put(" ");
            writer.put(r8(target));
            cycles = if (target == 6) 16 else 8;
        } else if (operation == 8) {
            writer.putFmt("BIT {d},", .{@as(u8, sub >> 3) & 7});
            writer.put(r8(target));
            cycles = if (target == 6) 12 else 8;
        } else {
            writer.put("RES ");
            writer.putFmt("{d},", .{@as(u8, sub >> 3) & 7});
            writer.put(r8(target));
            cycles = if (target == 6) 16 else 8;
        }
        return Instruction{ .text = writer.buffer, .len = len, .cycles = cycles };
    }

    const alu_names = [_][]const u8{ "ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP" };

    if ((opcode & 0xc0) == 0x40 and opcode != 0x76) {
        writer.put("LD ");
        writer.put(r8(opcode >> 3));
        writer.put(",");
        writer.put(r8(opcode));
        cycles = if ((opcode & 7) == 6 or (opcode >> 3) == 6) 8 else 4;
        return Instruction{ .text = writer.buffer, .len = 1, .cycles = cycles };
    }

    if ((opcode & 0xc0) == 0x80) {
        writer.put(alu_names[(opcode >> 3) & 7]);
        writer.put(" A,");
        writer.put(r8(opcode));
        cycles = if ((opcode & 7) == 6) 8 else 4;
        return Instruction{ .text = writer.buffer, .len = 1, .cycles = cycles };
    }

    switch (opcode) {
        0x00 => writer.put("NOP"),
        0x01 => writer.putLD16(r16(0), fetch.byte(2), fetch.byte(1)),
        0x02 => writer.putLD8("(BC)", "A"),
        0x03 => writer.putINC16(r16(0)),
        0x04 => writer.putINCDEC8("INC", 0),
        0x05 => writer.putINCDEC8("DEC", 0),
        0x06 => writer.putLDIMM(0, fetch.byte(1)),
        0x07 => writer.put("RLCA"),
        0x08 => writer.putLDW(fetch.byte(2), fetch.byte(1)),
        0x09 => writer.putADD16("BC"),
        0x0a => writer.putLD8("A", "(BC)"),
        0x0b => writer.putDEC16(0),
        0x0c => writer.putINCDEC8("INC", 1),
        0x0d => writer.putINCDEC8("DEC", 1),
        0x0e => writer.putLDIMM(1, fetch.byte(1)),
        0x0f => writer.put("RRCA"),
        0x10 => writer.put("STOP"),
        0x11 => writer.putLD16(r16(1), fetch.byte(2), fetch.byte(1)),
        0x12 => writer.putLD8("(DE)", "A"),
        0x13 => writer.putINC16(r16(1)),
        0x14 => writer.putINCDEC8("INC", 2),
        0x15 => writer.putINCDEC8("DEC", 2),
        0x16 => writer.putLDIMM(2, fetch.byte(1)),
        0x17 => writer.put("RLA"),
        0x18 => writer.putJR("", pc, @bitCast(fetch.byte(1))),
        0x19 => writer.putADD16("DE"),
        0x1a => writer.putLD8("A", "(DE)"),
        0x1b => writer.putDEC16(1),
        0x1c => writer.putINCDEC8("INC", 3),
        0x1d => writer.putINCDEC8("DEC", 3),
        0x1e => writer.putLDIMM(3, fetch.byte(1)),
        0x1f => writer.put("RRA"),
        0x20 => writer.putJR("NZ", pc, @bitCast(fetch.byte(1))),
        0x21 => writer.putLD16(r16(2), fetch.byte(2), fetch.byte(1)),
        0x22 => writer.putLD8("(HL+)", "A"),
        0x23 => writer.putINC16(r16(2)),
        0x24 => writer.putINCDEC8("INC", 4),
        0x25 => writer.putINCDEC8("DEC", 4),
        0x26 => writer.putLDIMM(4, fetch.byte(1)),
        0x27 => writer.put("DAA"),
        0x28 => writer.putJR("Z", pc, @bitCast(fetch.byte(1))),
        0x29 => writer.putADD16("HL"),
        0x2a => writer.putLD8("A", "(HL+)"),
        0x2b => writer.putDEC16(2),
        0x2c => writer.putINCDEC8("INC", 5),
        0x2d => writer.putINCDEC8("DEC", 5),
        0x2e => writer.putLDIMM(5, fetch.byte(1)),
        0x2f => writer.put("CPL"),
        0x30 => writer.putJR("NC", pc, @bitCast(fetch.byte(1))),
        0x31 => writer.putLD16(r16(3), fetch.byte(2), fetch.byte(1)),
        0x32 => writer.putLD8("(HL-)", "A"),
        0x33 => writer.putINC16(r16(3)),
        0x34 => writer.put("INC (HL)"),
        0x35 => writer.put("DEC (HL)"),
        0x36 => writer.putLDIMM(6, fetch.byte(1)),
        0x37 => writer.put("SCF"),
        0x38 => writer.putJR("C", pc, @bitCast(fetch.byte(1))),
        0x39 => writer.putADD16("SP"),
        0x3a => writer.putLD8("A", "(HL-)"),
        0x3b => writer.putDEC16(3),
        0x3c => writer.putINCDEC8("INC", 7),
        0x3d => writer.putINCDEC8("DEC", 7),
        0x3e => writer.putLDIMM(7, fetch.byte(1)),
        0x3f => writer.put("CCF"),
        0x76 => writer.put("HALT"),
        0xc0 => writer.putRETC("NZ"),
        0xc1 => writer.putPOP(0),
        0xc2 => writer.putJPC("NZ", fetch.byte(2), fetch.byte(1)),
        0xc3 => writer.putJP(fetch.byte(2), fetch.byte(1)),
        0xc4 => writer.putCALL("NZ", fetch.byte(2), fetch.byte(1)),
        0xc5 => writer.putPUSH(0),
        0xc6 => writer.putALUIMM("ADD", fetch.byte(1)),
        0xc7 => writer.putRST(0x00),
        0xc8 => writer.putRETC("Z"),
        0xc9 => writer.put("RET"),
        0xca => writer.putJPC("Z", fetch.byte(2), fetch.byte(1)),
        0xcc => writer.putCALL("Z", fetch.byte(2), fetch.byte(1)),
        0xcd => writer.putCALL("", fetch.byte(2), fetch.byte(1)),
        0xce => writer.putALUIMM("ADC", fetch.byte(1)),
        0xcf => writer.putRST(0x08),
        0xd0 => writer.putRETC("NC"),
        0xd1 => writer.putPOP(1),
        0xd2 => writer.putJPC("NC", fetch.byte(2), fetch.byte(1)),
        0xd4 => writer.putCALL("NC", fetch.byte(2), fetch.byte(1)),
        0xd5 => writer.putPUSH(1),
        0xd6 => writer.putALUIMM("SUB", fetch.byte(1)),
        0xd7 => writer.putRST(0x10),
        0xd8 => writer.putRETC("C"),
        0xd9 => writer.put("RETI"),
        0xda => writer.putJPC("C", fetch.byte(2), fetch.byte(1)),
        0xdc => writer.putCALL("C", fetch.byte(2), fetch.byte(1)),
        0xde => writer.putALUIMM("SBC", fetch.byte(1)),
        0xdf => writer.putRST(0x18),
        0xe0 => writer.putLDIMM8(@as(u16, 0xff00) + fetch.byte(1), "A"),
        0xe1 => writer.putPOP(2),
        0xe2 => writer.putLD8("(C)", "A"),
        0xe5 => writer.putPUSH(2),
        0xe6 => writer.putALUIMM("AND", fetch.byte(1)),
        0xe7 => writer.putRST(0x20),
        0xe8 => writer.putADDSP(pc, fetch.byte(1)),
        0xe9 => writer.put("JP (HL)"),
        0xea => writer.putLDA16(fetch.byte(2), fetch.byte(1)),
        0xee => writer.putALUIMM("XOR", fetch.byte(1)),
        0xef => writer.putRST(0x28),
        0xf0 => writer.putLDIMM8(@as(u16, 0xff00) + fetch.byte(1), "A"),
        0xf1 => writer.putPOP(3),
        0xf2 => writer.putLD8("A", "(C)"),
        0xf3 => writer.put("DI"),
        0xf5 => writer.putPUSH(3),
        0xf6 => writer.putALUIMM("OR", fetch.byte(1)),
        0xf7 => writer.putRST(0x30),
        0xf8 => writer.putLDHLSP(pc, fetch.byte(1)),
        0xf9 => writer.put("LD SP,HL"),
        0xfa => writer.putLDA16(fetch.byte(2), fetch.byte(1)),
        0xfb => writer.put("EI"),
        0xfe => writer.putALUIMM("CP", fetch.byte(1)),
        0xff => writer.putRST(0x38),
        else => {
            writer.putFmt("DB ${X:0>2}", .{opcode});
            return Instruction{ .text = writer.buffer, .len = 1, .cycles = 4 };
        },
    }

    return Instruction{ .text = writer.buffer, .len = instructionLen(opcode), .cycles = cyclesOf(opcode) };
}

fn instructionLen(opcode: u8) usize {
    const table = [_]u8{
        1, 3, 1, 1, 1, 1, 2, 1, 3, 1, 1, 1, 1, 1, 2, 1,
        2, 3, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 1,
        2, 3, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 1,
        2, 3, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
        1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        2, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
        2, 1, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 1,
        2, 1, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 2, 1,
        2, 1, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 1,
    };
    return table[opcode];
}

fn cyclesOf(opcode: u8) u8 {
    const table = [_]u8{
        4,  12, 8,  8,  4,  4,  8,  4,  20, 8,  8,  8,  4,  4,  8, 4,
        4,  12, 8,  8,  4,  4,  8,  4,  12, 8,  8,  8,  4,  4,  8, 4,
        8,  12, 8,  8,  4,  4,  8,  4,  12, 8,  8,  8,  4,  4,  8, 4,
        8,  12, 8,  8,  12, 12, 12, 4,  12, 8,  8,  8,  4,  4,  8, 4,
        4,  4,  4,  4,  4,  4,  8,  4,  4,  4,  4,  4,  4,  4,  8, 4,
        4,  4,  4,  4,  4,  4,  8,  4,  4,  4,  4,  4,  4,  4,  8, 4,
        8,  8,  8,  8,  8,  8,  4,  8,  4,  4,  4,  4,  4,  4,  8, 4,
        8,  8,  8,  8,  8,  8,  4,  8,  4,  4,  4,  4,  4,  4,  8, 4,
        8,  12, 12, 16, 12, 16, 8,  16, 8,  16, 12, 16, 12, 24, 8, 16,
        8,  12, 12, 16, 12, 16, 8,  16, 8,  16, 12, 16, 12, 24, 8, 16,
        8,  12, 12, 16, 12, 16, 8,  16, 8,  16, 12, 16, 12, 24, 8, 16,
        8,  12, 12, 16, 12, 16, 8,  16, 8,  16, 12, 16, 12, 24, 8, 16,
        12, 12, 8,  4,  16, 16, 8,  16, 20, 16, 16, 4,  16, 24, 8, 16,
        12, 12, 8,  4,  16, 16, 8,  16, 20, 16, 16, 4,  16, 24, 8, 16,
        12, 12, 8,  4,  16, 16, 20, 16, 8,  16, 16, 4,  16, 24, 8, 16,
        12, 12, 8,  4,  16, 16, 4,  16, 8,  16, 16, 4,  16, 24, 8, 16,
    };
    return table[opcode];
}

test "disassembler formats representative instructions" {
    const allocator = std.testing.allocator;
    var rom = [_]u8{0} ** 0x8000;
    rom[0x0100] = 0x21; // LD HL,d16
    rom[0x0101] = 0x34;
    rom[0x0102] = 0x12;
    rom[0x0103] = 0x3e; // LD A,d8
    rom[0x0104] = 0xaa;
    rom[0x0105] = 0xcb; // CB RLC C
    rom[0x0106] = 0x01;
    rom[0x0107] = 0xc3; // JP a16
    rom[0x0108] = 0x00;
    rom[0x0109] = 0x10;
    var bus = try Bus.init(allocator, &rom);
    defer bus.deinit();

    const a = formatAt(&bus, 0x0100);
    try std.testing.expectEqual(@as(usize, 3), a.len);
    try std.testing.expectEqualStrings("LD HL,$1234", std.mem.trimEnd(u8, &a.text, "\x00"));

    const b = formatAt(&bus, 0x0103);
    try std.testing.expectEqualStrings("LD A,$AA", std.mem.trimEnd(u8, &b.text, "\x00"));

    const c = formatAt(&bus, 0x0105);
    try std.testing.expectEqualStrings("RLC C", std.mem.trimEnd(u8, &c.text, "\x00"));

    const d = formatAt(&bus, 0x0107);
    try std.testing.expectEqualStrings("JP $1000", std.mem.trimEnd(u8, &d.text, "\x00"));
}
