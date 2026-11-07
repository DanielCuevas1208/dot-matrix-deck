// Headless debugger interface for Dot Matrix Deck.
//
// Models reproducible address breakpoints, single-stepping, execution
// continuation, and CPU register inspection without depending on SDL2.

const std = @import("std");
const Emulator = @import("emulator.zig").Emulator;
const Bus = @import("bus.zig").Bus;
const Cpu = @import("cpu.zig").Cpu;
const disasm = @import("disasm.zig");

pub const StopReason = enum {
    none,
    step,
    breakpoint,
    halted,
    instruction_limit,
    cycle_limit,
};

pub const CpuInspection = struct {
    a: u8,
    f: u8,
    b: u8,
    c: u8,
    d: u8,
    e: u8,
    h: u8,
    l: u8,
    sp: u16,
    pc: u16,
    ime: bool,
    halted: bool,
    total_cycles: u64,
    total_instructions: u64,

    pub fn af(self: CpuInspection) u16 {
        return (@as(u16, self.a) << 8) | self.f;
    }

    pub fn bc(self: CpuInspection) u16 {
        return (@as(u16, self.b) << 8) | self.c;
    }

    pub fn de(self: CpuInspection) u16 {
        return (@as(u16, self.d) << 8) | self.e;
    }

    pub fn hl(self: CpuInspection) u16 {
        return (@as(u16, self.h) << 8) | self.l;
    }

    pub fn flagZ(self: CpuInspection) bool {
        return (self.f & 0x80) != 0;
    }

    pub fn flagN(self: CpuInspection) bool {
        return (self.f & 0x40) != 0;
    }

    pub fn flagH(self: CpuInspection) bool {
        return (self.f & 0x20) != 0;
    }

    pub fn flagC(self: CpuInspection) bool {
        return (self.f & 0x10) != 0;
    }

    pub fn formatFlags(self: CpuInspection, out: *[4]u8) void {
        out[0] = if (self.flagZ()) 'Z' else '-';
        out[1] = if (self.flagN()) 'N' else '-';
        out[2] = if (self.flagH()) 'H' else '-';
        out[3] = if (self.flagC()) 'C' else '-';
    }
};

// Parses address strings in "$1234", "0x1234", or "1234" hex formats.
pub fn parseAddress(text: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    var slice = trimmed;
    if (std.mem.startsWith(u8, slice, "$")) {
        slice = slice[1..];
    } else if (std.mem.startsWith(u8, slice, "0x") or std.mem.startsWith(u8, slice, "0X")) {
        slice = slice[2..];
    }
    return std.fmt.parseInt(u16, slice, 16) catch null;
}

pub const Debugger = struct {
    allocator: std.mem.Allocator,
    emulator: *Emulator,
    breakpoints: std.ArrayListUnmanaged(u16) = .empty,
    last_stop_reason: StopReason = .none,
    breakpoint_hit: ?u16 = null,
    resuming_from_breakpoint: bool = false,

    pub fn init(allocator: std.mem.Allocator, emulator: *Emulator) Debugger {
        return .{
            .allocator = allocator,
            .emulator = emulator,
        };
    }

    pub fn deinit(self: *Debugger) void {
        self.breakpoints.deinit(self.allocator);
    }

    pub fn addBreakpoint(self: *Debugger, address: u16) !void {
        for (self.breakpoints.items) |existing| {
            if (existing == address) return;
        }
        try self.breakpoints.append(self.allocator, address);
    }

    pub fn removeBreakpoint(self: *Debugger, address: u16) bool {
        for (self.breakpoints.items, 0..) |existing, i| {
            if (existing == address) {
                _ = self.breakpoints.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn clearBreakpoints(self: *Debugger) void {
        self.breakpoints.clearRetainingCapacity();
    }

    pub fn hasBreakpoint(self: *const Debugger, address: u16) bool {
        for (self.breakpoints.items) |bp| {
            if (bp == address) return true;
        }
        return false;
    }

    pub fn listBreakpoints(self: *const Debugger) []const u16 {
        return self.breakpoints.items;
    }

    // Steps a single instruction. Clears any pending breakpoint stop.
    pub fn step(self: *Debugger) StopReason {
        self.resuming_from_breakpoint = false;
        self.breakpoint_hit = null;
        _ = self.emulator.step();
        self.last_stop_reason = .step;
        return .step;
    }

    // Runs until an address breakpoint is encountered or the instruction limit elapses.
    pub fn continueExecution(self: *Debugger, max_instructions: u64) StopReason {
        var remaining = max_instructions;
        if (self.resuming_from_breakpoint or self.breakpoint_hit != null) {
            self.resuming_from_breakpoint = false;
            self.breakpoint_hit = null;
            _ = self.emulator.step();
            if (remaining > 0) remaining -= 1;
        }

        while (remaining > 0) : (remaining -= 1) {
            const pc = self.emulator.cpu.pc;
            if (self.hasBreakpoint(pc)) {
                self.breakpoint_hit = pc;
                self.resuming_from_breakpoint = true;
                self.last_stop_reason = .breakpoint;
                return .breakpoint;
            }
            _ = self.emulator.step();
        }

        self.last_stop_reason = .instruction_limit;
        return .instruction_limit;
    }

    // Runs until the PPU completes a frame or an address breakpoint triggers.
    pub fn stepFrame(self: *Debugger, cap: u64) StopReason {
        var remaining = cap;
        if (self.resuming_from_breakpoint or self.breakpoint_hit != null) {
            self.resuming_from_breakpoint = false;
            self.breakpoint_hit = null;
            _ = self.emulator.step();
            if (remaining > 0) remaining -= 1;
        }

        while (!self.emulator.bus.ppu.takeFrame()) {
            const pc = self.emulator.cpu.pc;
            if (self.hasBreakpoint(pc)) {
                self.breakpoint_hit = pc;
                self.resuming_from_breakpoint = true;
                self.last_stop_reason = .breakpoint;
                return .breakpoint;
            }
            _ = self.emulator.step();
            if (remaining == 0) {
                self.last_stop_reason = .instruction_limit;
                return .instruction_limit;
            }
            remaining -= 1;
        }

        self.last_stop_reason = .none;
        return .none;
    }

    pub fn inspect(self: *const Debugger) CpuInspection {
        return .{
            .a = self.emulator.cpu.a,
            .f = self.emulator.cpu.f,
            .b = self.emulator.cpu.b,
            .c = self.emulator.cpu.c,
            .d = self.emulator.cpu.d,
            .e = self.emulator.cpu.e,
            .h = self.emulator.cpu.h,
            .l = self.emulator.cpu.l,
            .sp = self.emulator.cpu.sp,
            .pc = self.emulator.cpu.pc,
            .ime = self.emulator.cpu.ime,
            .halted = self.emulator.cpu.halted,
            .total_cycles = self.emulator.total_cycles,
            .total_instructions = self.emulator.total_instructions,
        };
    }

    pub fn currentInstruction(self: *const Debugger) disasm.Instruction {
        return disasm.formatAt(&self.emulator.bus, self.emulator.cpu.pc);
    }

    pub fn readMemory(self: *const Debugger, address: u16) u8 {
        return self.emulator.bus.read(address);
    }

    pub fn readMemoryWord(self: *const Debugger, address: u16) u16 {
        const lo: u16 = self.emulator.bus.read(address);
        const hi: u16 = self.emulator.bus.read(address +% 1);
        return (hi << 8) | lo;
    }

    // Formats register state into a fixed buffer.
    pub fn formatRegisters(self: *const Debugger, buffer: []u8) []const u8 {
        const state = self.inspect();
        var flags: [4]u8 = undefined;
        state.formatFlags(&flags);
        return std.fmt.bufPrint(
            buffer,
            "PC:{X:0>4} SP:{X:0>4} AF:{X:0>4} BC:{X:0>4} DE:{X:0>4} HL:{X:0>4} [{s}]",
            .{
                state.pc,
                state.sp,
                state.af(),
                state.bc(),
                state.de(),
                state.hl(),
                flags,
            },
        ) catch "";
    }

    // Formats a multi-line report for headless debugging logs.
    pub fn formatReport(self: *const Debugger, buffer: []u8) []const u8 {
        const state = self.inspect();
        var flags: [4]u8 = undefined;
        state.formatFlags(&flags);
        const inst = self.currentInstruction();
        const mnemonic = std.mem.trimEnd(u8, &inst.text, "\x00");
        return std.fmt.bufPrint(
            buffer,
            "PC: {X:0>4}  SP: {X:0>4}  AF: {X:0>4} ({s})  BC: {X:0>4}  DE: {X:0>4}  HL: {X:0>4}\nInst: {X:0>4}: {s} ({d} cyc)\nCycles: {d}  Instructions: {d}",
            .{
                state.pc,
                state.sp,
                state.af(),
                flags,
                state.bc(),
                state.de(),
                state.hl(),
                state.pc,
                mnemonic,
                inst.cycles,
                state.total_cycles,
                state.total_instructions,
            },
        ) catch "";
    }
};

test "parseAddress parses various hex representations" {
    try std.testing.expectEqual(@as(?u16, 0x0150), parseAddress("0150"));
    try std.testing.expectEqual(@as(?u16, 0x0150), parseAddress("$0150"));
    try std.testing.expectEqual(@as(?u16, 0x0150), parseAddress("0x0150"));
    try std.testing.expectEqual(@as(?u16, 0x0150), parseAddress("  0X0150 \n"));
    try std.testing.expectEqual(@as(?u16, null), parseAddress(""));
    try std.testing.expectEqual(@as(?u16, null), parseAddress("invalid"));
}

test "debugger manages address breakpoints" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x8000;
    var emulator = try Emulator.init(allocator, &rom);
    defer emulator.deinit();

    var debugger = Debugger.init(allocator, &emulator);
    defer debugger.deinit();

    try std.testing.expectEqual(@as(usize, 0), debugger.listBreakpoints().len);
    try debugger.addBreakpoint(0x0150);
    try debugger.addBreakpoint(0x0200);
    // Duplicate insertion is ignored
    try debugger.addBreakpoint(0x0150);

    try std.testing.expectEqual(@as(usize, 2), debugger.listBreakpoints().len);
    try std.testing.expect(debugger.hasBreakpoint(0x0150));
    try std.testing.expect(debugger.hasBreakpoint(0x0200));
    try std.testing.expect(!debugger.hasBreakpoint(0x0300));

    try std.testing.expect(debugger.removeBreakpoint(0x0150));
    try std.testing.expect(!debugger.hasBreakpoint(0x0150));
    try std.testing.expect(!debugger.removeBreakpoint(0x0150));

    debugger.clearBreakpoints();
    try std.testing.expectEqual(@as(usize, 0), debugger.listBreakpoints().len);
}

test "debugger single stepping executes one instruction" {
    const allocator = std.testing.allocator;
    var rom = [_]u8{0} ** 0x8000;
    // 0x0100: NOP (1 byte)
    // 0x0101: NOP (1 byte)
    rom[0x0100] = 0x00;
    rom[0x0101] = 0x00;
    var emulator = try Emulator.init(allocator, &rom);
    defer emulator.deinit();

    var debugger = Debugger.init(allocator, &emulator);
    defer debugger.deinit();

    try std.testing.expectEqual(@as(u16, 0x0100), debugger.inspect().pc);
    const reason = debugger.step();
    try std.testing.expectEqual(StopReason.step, reason);
    try std.testing.expectEqual(@as(u16, 0x0101), debugger.inspect().pc);
    try std.testing.expectEqual(@as(u64, 1), debugger.inspect().total_instructions);
}

test "debugger pauses on breakpoint and resumes to completion" {
    const allocator = std.testing.allocator;
    var rom = [_]u8{0} ** 0x8000;
    // 0x0100: JP $0150 (0xC3 0x50 0x01)
    rom[0x0100] = 0xc3;
    rom[0x0101] = 0x50;
    rom[0x0102] = 0x01;
    // 0x0150: LD A,$42 (0x3E 0x42)
    rom[0x0150] = 0x3e;
    rom[0x0151] = 0x42;
    // 0x0152: NOP
    rom[0x0152] = 0x00;

    var emulator = try Emulator.init(allocator, &rom);
    defer emulator.deinit();

    var debugger = Debugger.init(allocator, &emulator);
    defer debugger.deinit();

    try debugger.addBreakpoint(0x0150);

    // Run until breakpoint
    const reason = debugger.continueExecution(100);
    try std.testing.expectEqual(StopReason.breakpoint, reason);
    try std.testing.expectEqual(@as(?u16, 0x0150), debugger.breakpoint_hit);
    try std.testing.expectEqual(@as(u16, 0x0150), debugger.inspect().pc);
    try std.testing.expectEqual(@as(u8, 0x01), debugger.inspect().a); // Default A before LD

    // Inspect registers string
    var buf: [128]u8 = undefined;
    const formatted = debugger.formatRegisters(&buf);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "PC:0150") != null);

    // Step once to execute LD A,$42
    _ = debugger.step();
    try std.testing.expectEqual(@as(u16, 0x0152), debugger.inspect().pc);
    try std.testing.expectEqual(@as(u8, 0x42), debugger.inspect().a);

    // Continue past without getting stuck
    const reason2 = debugger.continueExecution(10);
    try std.testing.expectEqual(StopReason.instruction_limit, reason2);
    try std.testing.expect(debugger.inspect().pc > 0x0152);
}

test "debugger reads memory correctly" {
    const allocator = std.testing.allocator;
    var rom = [_]u8{0} ** 0x8000;
    rom[0x0100] = 0x34;
    rom[0x0101] = 0x12;

    var emulator = try Emulator.init(allocator, &rom);
    defer emulator.deinit();

    var debugger = Debugger.init(allocator, &emulator);
    defer debugger.deinit();

    try std.testing.expectEqual(@as(u8, 0x34), debugger.readMemory(0x0100));
    try std.testing.expectEqual(@as(u16, 0x1234), debugger.readMemoryWord(0x0100));
}
