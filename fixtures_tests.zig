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
    .{ .name = "banking", .source = @embedFile("fixtures/asm/banking.asm"), .image = @embedFile("fixtures/roms/banking.gb") },
};

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
    const fixture = fixtures[0];
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
    const fixture = fixtures[1];
    var emulator = try Emulator.init(std.testing.allocator, fixture.image);
    defer emulator.deinit();
    var frame_index: u32 = 0;
    while (frame_index < 40) : (frame_index += 1) emulator.runFrame(1 << 24);
    try std.testing.expect(std.mem.indexOf(u8, emulator.serialOutput(), "PASS") != null);
}

test "banking ROM reports PASS" {
    const fixture = fixtures[2];
    var emulator = try Emulator.init(std.testing.allocator, fixture.image);
    defer emulator.deinit();
    var frame_index: u32 = 0;
    while (frame_index < 40) : (frame_index += 1) emulator.runFrame(1 << 24);
    try std.testing.expect(std.mem.indexOf(u8, emulator.serialOutput(), "PASS") != null);
}
