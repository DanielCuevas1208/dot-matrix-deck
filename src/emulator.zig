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

    // Connects the link ports on two emulator instances.
    pub fn connectSerial(left: *Emulator, right: *Emulator) void {
        Bus.connectSerial(&left.bus, &right.bus);
    }

    pub fn disconnectSerial(self: *Emulator) void {
        self.bus.disconnectSerial();
    }

    pub fn step(self: *Emulator) u16 {
        if (self.bus.dma.active()) {
            const cycles = self.bus.dmaStep();
            self.total_cycles += cycles;
            return cycles;
        }
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
            _ = self.step();
            remaining -= 1;
            if (remaining == 0) return;
        }
    }

    pub fn serialOutput(self: *Emulator) []const u8 {
        return self.bus.serialOutput();
    }

    // True when the loaded cartridge keeps its RAM in a battery save file.
    pub fn hasSaveData(self: *const Emulator) bool {
        return self.bus.cartridge.hasBattery();
    }

    // A battery-backed cartridge with unflushed RAM needs a save.
    pub fn saveNeeded(self: *const Emulator) bool {
        return self.bus.cartridge.saveNeeded();
    }

    // Restores external RAM from a .sav file. Returns false when no save
    // file exists at the path.
    pub fn loadSaveFile(self: *Emulator, io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
        const file = dir.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close(io);
        const size = try file.length(io);
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(bytes);
        _ = try file.readPositionalAll(io, bytes, 0);
        try self.bus.cartridge.loadSaveData(bytes);
        return true;
    }

    // Writes external RAM to a .sav file when the cartridge uses battery
    // RAM and the RAM holds unflushed writes. No-op otherwise.
    pub fn saveSaveFile(self: *Emulator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        const cartridge = &self.bus.cartridge;
        if (!cartridge.saveNeeded()) return;
        const file = try dir.createFile(io, path, .{});
        defer file.close(io);
        _ = try file.writePositionalAll(io, cartridge.saveData(), 0);
        cartridge.markRamClean();
    }

    pub fn cycleCount(self: *Emulator) u64 {
        return self.total_cycles;
    }

    pub fn reset(self: *Emulator) void {
        self.cpu = .{};
        self.bus.ppu = .{};
        self.bus.apu = .{};
        self.bus.timer = .{};
        self.bus.joypad = .{};
        self.bus.dma = .{};
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

test "save file round-trip persists external RAM" {
    var image: [0x40000]u8 = [_]u8{0} ** 0x40000;
    image[0x147] = 0x03; // MBC1 + RAM + battery
    image[0x149] = 0x03; // 32KB external RAM

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const save_path = "save_test.sav";

    var emulator = try Emulator.init(std.testing.allocator, &image);
    defer emulator.deinit();
    try std.testing.expect(emulator.hasSaveData());

    // No save file yet: load reports false and RAM stays clear.
    try std.testing.expect(!try emulator.loadSaveFile(std.testing.io, tmp.dir, save_path));
    try std.testing.expect(!emulator.saveNeeded());

    // A RAM write marks the save needed; saving flushes and clears it.
    emulator.bus.write(0x0000, 0x0a);
    emulator.bus.write(0xa000, 0x5a);
    try std.testing.expect(emulator.saveNeeded());
    try emulator.saveSaveFile(std.testing.io, tmp.dir, save_path);
    try std.testing.expect(!emulator.saveNeeded());

    // A fresh emulator loads the saved byte back.
    var reloaded = try Emulator.init(std.testing.allocator, &image);
    defer reloaded.deinit();
    try std.testing.expect(try reloaded.loadSaveFile(std.testing.io, tmp.dir, save_path));
    reloaded.bus.write(0x0000, 0x0a);
    try std.testing.expectEqual(@as(u8, 0x5a), reloaded.bus.read(0xa000));
}

test "save is skipped for cartridges without battery RAM" {
    const rom = [_]u8{0} ** 0x8000;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var emulator = try Emulator.init(std.testing.allocator, &rom);
    defer emulator.deinit();
    try std.testing.expect(!emulator.hasSaveData());
    try emulator.saveSaveFile(std.testing.io, tmp.dir, "noop.sav");
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "noop.sav", .{}));
}
