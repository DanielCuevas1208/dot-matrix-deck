const std = @import("std");
const Emulator = @import("emulator").Emulator;

const max_steps: usize = 100_000;

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const bytes = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

fn usage(program: []const u8) void {
    std.debug.print("Usage: {s} <left.gb> <right.gb>\n", .{program});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| try args.append(allocator, arg);
    if (args.items.len != 3) {
        usage(args.items[0]);
        std.process.exit(2);
    }

    const left_rom = try readFile(io, allocator, args.items[1]);
    defer allocator.free(left_rom);
    const right_rom = try readFile(io, allocator, args.items[2]);
    defer allocator.free(right_rom);

    var left = try Emulator.init(allocator, left_rom);
    defer left.deinit();
    var right = try Emulator.init(allocator, right_rom);
    defer right.deinit();
    Emulator.connectSerial(&left, &right);

    var steps: usize = 0;
    while (steps < max_steps) : (steps += 1) {
        _ = left.step();
        _ = right.step();
        if (left.bus.read(0xc001) == 'B' and right.bus.read(0xc001) == 'A' and
            std.mem.indexOf(u8, left.serialOutput(), "PASS") != null and
            std.mem.indexOf(u8, right.serialOutput(), "PASS") != null) break;
    }

    if (steps == max_steps) {
        std.debug.print("Serial link demo did not complete.\n", .{});
        std.process.exit(1);
    }

    std.debug.print(
        "Serial link demo:\nA received: B\nB received: A\nVerdict: pass\n",
        .{},
    );
}
