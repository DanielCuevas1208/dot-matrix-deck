const std = @import("std");
const gbasm = @import("tools/gbasm.zig");
const Emulator = @import("src/emulator.zig").Emulator;

// Package-root shim for the fixture round-trip test.
//
// The bundled demo ROM must stay reproducible. This test reassembles the
// source in fixtures/asm and compares the result to the committed image in
// fixtures/roms. `zig build fixtures` regenerates that image.

test "demo fixture round-trips byte for byte" {
    const source = @embedFile("fixtures/asm/demo.asm");
    const expected = @embedFile("fixtures/roms/demo.gb");
    var assembler = gbasm.Assembler.init(std.testing.allocator);
    defer assembler.deinit();
    const image = try assembler.assemble(source);
    defer std.testing.allocator.free(image);
    try std.testing.expectEqualSlices(u8, expected, image);
}

test "demo ROM renders frames and reports PASS" {
    const image = @embedFile("fixtures/roms/demo.gb");
    var emulator = try Emulator.init(std.testing.allocator, image);
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
