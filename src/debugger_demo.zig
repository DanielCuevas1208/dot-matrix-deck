const std = @import("std");
const Emulator = @import("emulator.zig").Emulator;
const debugger = @import("debugger.zig");

const demo_init_pc: u16 = 0x0150;
const max_resume_steps: u64 = 2_000_000;

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const bytes = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const rom = try readFile(io, allocator, "fixtures/roms/demo.gb");
    defer allocator.free(rom);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();

    var dbg = debugger.Debugger.init(allocator, &emulator);
    defer dbg.deinit();

    try dbg.addBreakpoint(demo_init_pc);

    const hit = dbg.continueExecution(50_000);
    if (hit != .breakpoint) {
        std.debug.print("Debugger demo: expected breakpoint at ${X:0>4}, got {s}\n", .{ demo_init_pc, @tagName(hit) });
        std.process.exit(1);
    }
    if (dbg.breakpoint_hit != demo_init_pc or dbg.inspect().pc != demo_init_pc) {
        std.debug.print("Debugger demo: breakpoint address mismatch.\n", .{});
        std.process.exit(1);
    }

    var report: [256]u8 = undefined;
    const report_text = dbg.formatReport(&report);
    if (std.mem.indexOf(u8, report_text, "PC: 0150") == null) {
        std.debug.print("Debugger demo: register report missing PC.\n", .{});
        std.process.exit(1);
    }

    _ = dbg.step();
    const after = dbg.inspect();
    if (after.pc != 0x0152 or after.a != 0x00) {
        std.debug.print("Debugger demo: init step did not load A with zero (pc={X:0>4} a={X:0>2}).\n", .{ after.pc, after.a });
        std.process.exit(1);
    }

    _ = dbg.continueExecution(max_resume_steps);
    const serial = emulator.serialOutput();
    if (std.mem.indexOf(u8, serial, "PASS") == null) {
        std.debug.print("Debugger demo: demo ROM did not report PASS.\n", .{});
        std.process.exit(1);
    }

    std.debug.print(
        "Debugger demo:\nBreakpoint: ${X:0>4}\nAfter step: PC ${X:0>4} A ${X:0>2}\nSerial: PASS\nVerdict: pass\n",
        .{ demo_init_pc, after.pc, after.a },
    );
}
