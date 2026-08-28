const std = @import("std");
const gbasm = @import("tools/gbasm.zig");
const Emulator = @import("src/emulator.zig").Emulator;

// Package-root shim for the fixture round-trip tests.
//
// The bundled ROMs must stay reproducible. Each test reassembles the
// source in fixtures/asm and compares the result to the committed image
// in fixtures/roms. `zig build fixtures` regenerates those images.

const Fixture = struct {
    name: []const u8,
    source: []const u8,
    image: []const u8,
};

const fixtures = [_]Fixture{
    .{ .name = "demo", .source = @embedFile("fixtures/asm/demo.asm"), .image = @embedFile("fixtures/roms/demo.gb") },
    .{ .name = "dma", .source = @embedFile("fixtures/asm/dma.asm"), .image = @embedFile("fixtures/roms/dma.gb") },
    .{ .name = "joypad", .source = @embedFile("fixtures/asm/joypad.asm"), .image = @embedFile("fixtures/roms/joypad.gb") },
    .{ .name = "banking", .source = @embedFile("fixtures/asm/banking.asm"), .image = @embedFile("fixtures/roms/banking.gb") },
    .{ .name = "mbc2", .source = @embedFile("fixtures/asm/mbc2.asm"), .image = @embedFile("fixtures/roms/mbc2.gb") },
    .{ .name = "mbc3", .source = @embedFile("fixtures/asm/mbc3.asm"), .image = @embedFile("fixtures/roms/mbc3.gb") },
    .{ .name = "mbc5", .source = @embedFile("fixtures/asm/mbc5.asm"), .image = @embedFile("fixtures/roms/mbc5.gb") },
    .{ .name = "sram", .source = @embedFile("fixtures/asm/sram.asm"), .image = @embedFile("fixtures/roms/sram.gb") },
};

fn fixtureNamed(comptime name: []const u8) Fixture {
    inline for (fixtures) |fixture| {
        if (comptime std.mem.eql(u8, fixture.name, name)) return fixture;
    }
    @compileError("unknown fixture name");
}

fn expectFixturePass(fixture: Fixture) !void {
    var emulator = try Emulator.init(std.testing.allocator, fixture.image);
    defer emulator.deinit();

    var frame_index: u32 = 0;
    while (frame_index < 40) : (frame_index += 1) emulator.runFrame(1 << 24);
    try std.testing.expect(std.mem.indexOf(u8, emulator.serialOutput(), "PASS") != null);
}

test "fixture images round-trip byte for byte" {
    for (fixtures) |fixture| {
        var assembler = gbasm.Assembler.init(std.testing.allocator);
        defer assembler.deinit();
        const image = try assembler.assemble(fixture.source);
        defer std.testing.allocator.free(image);
        try std.testing.expectEqualSlices(u8, fixture.image, image);
    }
}

test "demo ROM renders frames and reports PASS" {
    const fixture = fixtureNamed("demo");
    var emulator = try Emulator.init(std.testing.allocator, fixture.image);
    defer emulator.deinit();

    var frame_index: u32 = 0;
    while (frame_index < 4) : (frame_index += 1) emulator.runFrame(1 << 24);
    var lit_pixels: usize = 0;
    for (emulator.bus.ppu.frame) |pixel| {
        if (pixel != 0xfff8f8f0) lit_pixels += 1;
    }
    try std.testing.expect(lit_pixels > 1000);

    while (frame_index < 80) : (frame_index += 1) emulator.runFrame(1 << 24);
    try std.testing.expect(std.mem.indexOf(u8, emulator.serialOutput(), "PASS") != null);
}

test "DMA ROM reports PASS" {
    try expectFixturePass(fixtureNamed("dma"));
}

test "joypad ROM reports PASS" {
    try expectFixturePass(fixtureNamed("joypad"));
}

test "joypad button press is visible through FF00" {
    const Joypad = @import("src/joypad.zig").Joypad;
    const rom = [_]u8{0} ** 0x8000;
    var emulator = try Emulator.init(std.testing.allocator, &rom);
    defer emulator.deinit();
    emulator.bus.write(0xff00, 0x10);
    try std.testing.expectEqual(@as(u8, 0x10), emulator.bus.read(0xff00) & 0x30);
    emulator.bus.setButton(Joypad.Button.a, true);
    try std.testing.expectEqual(@as(u8, 0x0e), emulator.bus.read(0xff00) & 0x0f);
}

test "banking ROM reports PASS" {
    try expectFixturePass(fixtureNamed("banking"));
}

test "MBC2 ROM reports PASS" {
    try expectFixturePass(fixtureNamed("mbc2"));
}

test "MBC3 ROM reports PASS" {
    try expectFixturePass(fixtureNamed("mbc3"));
}

test "MBC5 ROM reports PASS" {
    try expectFixturePass(fixtureNamed("mbc5"));
}

test "SRAM ROM save data round-trips through a file" {
    const fixture = fixtureNamed("sram");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const save_path = "sram.sav";

    // Run 1: fresh RAM writes the marker and reports PASS.
    var first = try Emulator.init(std.testing.allocator, fixture.image);
    defer first.deinit();
    var frame_index: u32 = 0;
    while (frame_index < 40) : (frame_index += 1) first.runFrame(1 << 24);
    try std.testing.expect(std.mem.indexOf(u8, first.serialOutput(), "PASS") != null);
    first.bus.write(0x0000, 0x0a);
    try std.testing.expectEqual(@as(u8, 0x5a), first.bus.read(0xa000));
    try first.saveSaveFile(std.testing.io, tmp.dir, save_path);

    // Run 2: the marker loads back before the ROM runs.
    var second = try Emulator.init(std.testing.allocator, fixture.image);
    defer second.deinit();
    try std.testing.expect(try second.loadSaveFile(std.testing.io, tmp.dir, save_path));
    second.bus.write(0x0000, 0x0a);
    try std.testing.expectEqual(@as(u8, 0x5a), second.bus.read(0xa000));
    frame_index = 0;
    while (frame_index < 40) : (frame_index += 1) second.runFrame(1 << 24);
    try std.testing.expect(std.mem.indexOf(u8, second.serialOutput(), "PASS") != null);
}
