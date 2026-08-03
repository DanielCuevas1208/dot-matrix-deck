const std = @import("std");
const Emulator = @import("emulator.zig").Emulator;
const cartridge = @import("cartridge.zig");
const gbasm = @import("gbasm");

// Deterministic end-to-end checks for the bundled smoke ROM. The ROM is
// assembled from its assembly source at test time and compared to the
// committed image, then run through the full pipeline. Every expected value
// below is fixed, so a change in the CPU, the bus, the PPU, or the assembler
// that alters observable output fails the suite. The fixtures are read from
// the repository root, which is the working directory for `zig build test`.

const smoke_source_path = "fixtures/asm/smoke.asm";
const smoke_rom_path = "fixtures/roms/smoke.gb";

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const buffer = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

// FNV-1a over the raw frame bytes. It matches the hash the headless runner
// prints for --dump-frame.
fn frameChecksum(frame: []const u32) u32 {
    var hash: u32 = 0x811c9dc5;
    for (frame) |pixel| {
        const bytes = [4]u8{
            @truncate(pixel),
            @truncate(pixel >> 8),
            @truncate(pixel >> 16),
            @truncate(pixel >> 24),
        };
        for (bytes) |byte| {
            hash ^= byte;
            hash *%= 0x01000193;
        }
    }
    return hash;
}

test "gbasm rebuilds the committed smoke ROM byte for byte" {
    const allocator = std.testing.allocator;
    const source = try readFixture(allocator, smoke_source_path);
    defer allocator.free(source);
    const committed = try readFixture(allocator, smoke_rom_path);
    defer allocator.free(committed);

    const rom = try gbasm.assemble(allocator, source);
    defer allocator.free(rom);
    try std.testing.expectEqualSlices(u8, committed, rom);
}

test "smoke ROM carries a valid cartridge header" {
    const allocator = std.testing.allocator;
    const rom = try readFixture(allocator, smoke_rom_path);
    defer allocator.free(rom);

    const header = cartridge.readHeader(rom);
    try std.testing.expect(header.header_checksum_ok);
    try std.testing.expectEqualStrings("SMOKE TEST", std.mem.sliceTo(&header.title, 0));
    try std.testing.expectEqualStrings("ROM only", header.mapper);
}

test "smoke ROM passes through the full pipeline" {
    const allocator = std.testing.allocator;
    const rom = try readFixture(allocator, smoke_rom_path);
    defer allocator.free(rom);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();
    emulator.runFrame(1_000_000);
    emulator.runFrame(1_000_000);
    emulator.runFrame(1_000_000);
    try std.testing.expectEqualStrings("PASS\n", emulator.serialOutput());
}

test "smoke ROM frame checksum is deterministic" {
    const allocator = std.testing.allocator;
    const rom = try readFixture(allocator, smoke_rom_path);
    defer allocator.free(rom);

    const runFrames = struct {
        fn call(alloc: std.mem.Allocator, image: []const u8) !u32 {
            var emulator = try Emulator.init(alloc, image);
            defer emulator.deinit();
            var frame_index: usize = 0;
            while (frame_index < 3) : (frame_index += 1) emulator.runFrame(1_000_000);
            return frameChecksum(&emulator.bus.ppu.frame);
        }
    }.call;

    const first = try runFrames(allocator, rom);
    const second = try runFrames(allocator, rom);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u32, 0x5CCE8DC5), first);
}
