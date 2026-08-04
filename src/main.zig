const std = @import("std");
const Emulator = @import("emulator.zig").Emulator;
const Frontend = @import("frontend.zig").Frontend;

fn usage(program: []const u8) void {
    std.debug.print(
        \\Dot Matrix Deck - windowed frontend
        \\Usage:
        \\  {s} <rom.gb>
        \\
        \\Runs a ROM in an SDL2 window. Press Escape or close the window
        \\to quit. Arrow keys move; Z, X, Enter and Backspace map to A,
        \\B, Start and Select.
        \\
    , .{program});
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const buffer = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| {
        try args.append(allocator, arg);
    }
    const argv = args.items;

    if (argv.len < 2) {
        usage(argv[0]);
        std.process.exit(2);
    }

    const rom = readFile(io, allocator, argv[1]) catch |err| {
        std.debug.print("cannot read ROM: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(rom);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();

    var frontend = Frontend.init("Dot Matrix Deck") catch |err| {
        std.debug.print("cannot open SDL2 window: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer frontend.deinit();

    var frames: u64 = 0;
    while (frontend.poll()) {
        emulator.bus.setJoypadButtons(frontend.heldButtons());
        emulator.runFrame(200_000);
        frontend.present(emulator.bus.ppu.frame[0..]);
        frontend.throttle();
        frames += 1;
    }
    std.debug.print("Rendered {d} frames\n", .{frames});
}
