const std = @import("std");
const Bus = @import("bus.zig").Bus;
const Cpu = @import("cpu.zig").Cpu;
const ppu = @import("ppu.zig");

// Ties the bus and CPU together and drives one headless run. The SDL2
// frontend uses the same core; only the window, input, and debugger live
// in the frontend.

pub const Emulator = struct {
    allocator: std.mem.Allocator,
    bus: Bus,
    cpu: Cpu = .{},
    total_cycles: u64 = 0,
    total_instructions: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, rom: []const u8) !Emulator {
        return .{
            .allocator = allocator,
            .bus = try Bus.init(allocator, rom),
        };
    }

    pub fn deinit(self: *Emulator) void {
        self.bus.deinit();
    }

    pub fn step(self: *Emulator) u16 {
        const cycles = self.cpu.step(&self.bus);
        self.total_cycles += cycles;
        self.total_instructions += 1;
        return cycles;
    }

    pub fn runInstructions(self: *Emulator, count: u64) void {
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) _ = self.step();
    }

    // Runs until a new frame is ready or `cap` instructions elapse.
    pub fn runFrame(self: *Emulator, cap: u64) void {
        var remaining = cap;
        while (!self.bus.ppu.takeFrame()) {
            self.step();
            remaining -= 1;
            if (remaining == 0) return;
        }
    }

    pub fn serialOutput(self: *Emulator) []const u8 {
        return self.bus.serialOutput();
    }

    pub fn cycleCount(self: *Emulator) u64 {
        return self.total_cycles;
    }

    pub fn reset(self: *Emulator) void {
        self.cpu = .{};
        self.bus.ppu = .{};
        self.bus.timer = .{};
        self.bus.serial_len = 0;
        self.total_cycles = 0;
        self.total_instructions = 0;
    }
};

test "emulator initialises and steps through ROM entry" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0x00} ** 0x8000;
    var emulator = try Emulator.init(allocator, &rom);
    defer emulator.deinit();
    try std.testing.expectEqual(@as(u16, 0x0100), emulator.cpu.pc);
    emulator.runInstructions(10);
    try std.testing.expectEqual(@as(u64, 10), emulator.total_instructions);
    try std.testing.expect(emulator.total_cycles > 0);
}

test "emulator loads a full-sized ROM" {
    const allocator = std.testing.allocator;
    var rom: [0x8000]u8 = undefined;
    std.mem.writeInt(u16, rom[0x0100..0x0102], 0x0000, .little);
    var emulator = try Emulator.init(allocator, &rom);
    defer emulator.deinit();
    emulator.runInstructions(2);
}

test "page size sanity" {
    try std.testing.expectEqual(@as(usize, 160), ppu.ScreenWidth);
    try std.testing.expectEqual(@as(usize, 144), ppu.ScreenHeight);
}

fn frameChecksum(frame: []const u32) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (frame) |pixel| {
        var bytes = [4]u8{ @truncate(pixel), @truncate(pixel >> 8), @truncate(pixel >> 16), @truncate(pixel >> 24) };
        for (&bytes) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3;
        }
    }
    return hash;
}

test "a frame completes within the frame cycle budget" {
    const allocator = std.testing.allocator;
    var rom: [0x8000]u8 = [_]u8{0x00} ** 0x8000;
    var emulator = try Emulator.init(allocator, &rom);
    defer emulator.deinit();
    emulator.runFrame(70_224);
    try std.testing.expectEqual(@as(u64, 0), emulator.total_cycles % 4);
    try std.testing.expectEqual(@as(u64, 65_664), emulator.total_cycles);
}

test "frame output is deterministic across runs" {
    const allocator = std.testing.allocator;
    var rom: [0x8000]u8 = [_]u8{0x00} ** 0x8000;
    var first = try Emulator.init(allocator, &rom);
    defer first.deinit();
    first.runFrame(70_224);
    const hash_a = frameChecksum(&first.bus.ppu.frame);

    var second = try Emulator.init(allocator, &rom);
    defer second.deinit();
    second.runFrame(70_224);
    const hash_b = frameChecksum(&second.bus.ppu.frame);

    try std.testing.expectEqual(hash_a, hash_b);
}
