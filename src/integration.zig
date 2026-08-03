// End-to-end tests for the emulator core.
//
// The unit tests in the core modules check individual pieces. These
// tests load a real ROM image, run it, and check the observable result.
// The bundled smoke ROM is assembled from source by gbasm before the
// test step runs, so the same chain that a user runs in CI is tested.

const std = @import("std");
const options = @import("options");
const Emulator = @import("emulator.zig").Emulator;
const cartridge = @import("cartridge.zig");
const serial = @import("serial.zig");

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const buffer = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

fn readFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ options.fixture_dir, name });
    defer allocator.free(path);
    return readFile(std.testing.io, allocator, path);
}

test "smoke ROM prints a passing verdict" {
    const allocator = std.testing.allocator;
    const rom = try readFixture(allocator, "smoke.gb");
    defer allocator.free(rom);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();

    var steps: u64 = 0;
    while (steps < 5_000_000) : (steps += 1) {
        if (emulator.serialOutput().len >= "Passed\n".len) break;
        _ = emulator.step();
    }

    try std.testing.expectEqualStrings("Passed\n", emulator.serialOutput());
    try std.testing.expectEqual(serial.Verdict.pass, serial.verdictOf(emulator.serialOutput()));
    try std.testing.expect(emulator.cycleCount() > 0);
}

test "smoke ROM run is deterministic" {
    const allocator = std.testing.allocator;
    const rom = try readFixture(allocator, "smoke.gb");
    defer allocator.free(rom);

    var first = try Emulator.init(allocator, rom);
    defer first.deinit();
    first.runInstructions(20_000);
    const first_cycles = first.cycleCount();

    var second = try Emulator.init(allocator, rom);
    defer second.deinit();
    second.runInstructions(20_000);

    try std.testing.expectEqual(first_cycles, second.cycleCount());
    try std.testing.expectEqualSlices(u32, &first.bus.ppu.frame, &second.bus.ppu.frame);
}

test "serial port captures bytes written to the link register" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x8000;
    var emulator = try Emulator.init(allocator, &rom);
    defer emulator.deinit();

    emulator.bus.write(0xff01, 'P');
    emulator.bus.write(0xff02, 0x81);
    emulator.bus.write(0xff01, 'K');
    emulator.bus.write(0xff02, 0x81);

    try std.testing.expectEqualStrings("PK", emulator.bus.serialOutput());
    try std.testing.expectEqual(@as(u8, 0x08), emulator.bus.iflag & 0x08);
}

test "cartridge header reports the title and sizes" {
    var rom = [_]u8{0} ** 0x8000;
    std.mem.copyForwards(u8, rom[0x134 .. 0x134 + 9], "TESTGAME");
    rom[0x143] = 0x80; // CGB capable
    rom[0x147] = 0x01; // MBC1
    rom[0x148] = 0x02; // 128 KiB ROM
    rom[0x149] = 0x03; // 32 KiB RAM

    const header = cartridge.readHeader(&rom);
    try std.testing.expectEqualStrings("TESTGAME", std.mem.sliceTo(&header.title, 0));
    try std.testing.expectEqual(@as(u8, 0x80), header.cgb_flag);
    try std.testing.expectEqualStrings("MBC1", header.mapper);
    try std.testing.expectEqual(@as(u16, 128), header.rom_size_kib);
    try std.testing.expectEqual(@as(u16, 32), header.ram_size_kib);
}

test "joypad column selection exposes pressed buttons" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x8000;
    var emulator = try Emulator.init(allocator, &rom);
    defer emulator.deinit();

    // Right (bit 0) and A (bit 4) are pressed; everything else is up.
    emulator.bus.setButtons(0b0111_1110);
    try std.testing.expectEqual(@as(u8, 0xff), emulator.bus.read(0xff00));

    emulator.bus.write(0xff00, 0x20); // Select the D-pad column.
    try std.testing.expectEqual(@as(u8, 0xfe), emulator.bus.read(0xff00));

    emulator.bus.write(0xff00, 0x10); // Select the button column.
    try std.testing.expectEqual(@as(u8, 0xf7), emulator.bus.read(0xff00));
}
