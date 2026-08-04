const std = @import("std");
const Emulator = @import("emulator.zig").Emulator;
const serial = @import("serial.zig");
const disasm = @import("disasm.zig");

const default_max_cycles: u64 = 2_000_000_000;

const Options = struct {
    rom_path: ?[]const u8 = null,
    blargg_suite: ?[]const u8 = null,
    max_cycles: u64 = default_max_cycles,
    trace: bool = false,
    expect: ?serial.Verdict = null,
    timeout_ms: u64 = 120_000,
    load_save: ?[]const u8 = null,
    save: ?[]const u8 = null,
};

fn usage(program: []const u8) void {
    std.debug.print(
        \\Dot Matrix Deck - headless runner
        \\Usage:
        \\  {s} <rom.gb> [--max-cycles N] [--trace] [--expect pass|fail|any]
        \\       [--load-save <path>] [--save <path>]
        \\  {s} --blargg-suite <directory>
        \\
        \\Runs a ROM without a window, prints its serial output, and sets the
        \\exit code from the test verdict. --load-save restores battery RAM
        \\before the run; --save writes battery RAM to a file after the run.
        \\
    , .{ program, program });
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const buffer = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

const Runner = struct {
    emulator: *Emulator,
    options: Options,
    io: std.Io,
    start: std.Io.Clock.Timestamp,
    last_serial_len: usize = 0,
    silent_cycles: u64 = 0,

    fn tick(self: *Runner) bool {
        if (self.emulator.total_cycles >= self.options.max_cycles) return true;
        const elapsed_ms = self.start.durationTo(std.Io.Clock.Timestamp.now(self.io, .real)).raw.toMilliseconds();
        if (elapsed_ms >= @as(i64, @intCast(self.options.timeout_ms))) return true;
        const bytes = self.emulator.serialOutput();
        if (bytes.len != self.last_serial_len) {
            self.last_serial_len = bytes.len;
            self.silent_cycles = 0;
        } else {
            self.silent_cycles += 1;
        }
        return false;
    }

    fn done(self: *Runner) bool {
        const verdict = serial.verdictOf(self.emulator.serialOutput());
        if (verdict != .pending) return self.silent_cycles > 100_000;
        return false;
    }

    fn run(self: *Runner) void {
        while (!self.tick() and !self.done()) {
            const pc = self.emulator.cpu.pc;
            if (self.options.trace) {
                const instruction = disasm.formatAt(&self.emulator.bus, pc);
                std.debug.print("{X:0>4}: {s}\n", .{ pc, std.mem.trim(u8, &instruction.text, "\x00") });
            }
            _ = self.emulator.step();
        }
    }
};

fn runRom(io: std.Io, allocator: std.mem.Allocator, options: Options) !u8 {
    const rom = try readFile(io, allocator, options.rom_path.?);
    defer allocator.free(rom);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();

    if (options.load_save) |path| {
        if (!emulator.hasSaveData()) {
            std.debug.print("Cartridge has no battery RAM; save file ignored.\n", .{});
        } else {
            const loaded = emulator.loadSaveFile(io, std.Io.Dir.cwd(), path) catch |err| {
                std.debug.print("Could not load save file {s}: {s}\n", .{ path, @errorName(err) });
                return 1;
            };
            std.debug.print("{s}\n", .{if (loaded) "Loaded save data." else "No save file found; starting fresh."});
        }
    }

    var runner = Runner{
        .emulator = &emulator,
        .options = options,
        .io = io,
        .start = std.Io.Clock.Timestamp.now(io, .real),
    };
    runner.run();

    const output = emulator.serialOutput();
    const verdict = serial.verdictOf(output);
    const printable = serial.trim(serial.printable(output));

    if (printable.len != 0) {
        std.debug.print("Serial output:\n{s}\n", .{printable});
    }

    const wanted = options.expect orelse verdict;
    const ok = wanted == verdict;
    std.debug.print("Verdict: {s}\n", .{@tagName(verdict)});

    if (options.save) |path| {
        emulator.saveSaveFile(io, std.Io.Dir.cwd(), path) catch |err| {
            std.debug.print("Could not write save file {s}: {s}\n", .{ path, @errorName(err) });
            return 1;
        };
    }
    return if (ok) 0 else 1;
}

fn runSuite(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var failures: usize = 0;
    var total: usize = 0;

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".gb")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (names.items) |name| {
        total += 1;
        const path = try std.fs.path.join(allocator, &.{ directory, name });
        defer allocator.free(path);
        const options = Options{ .rom_path = path, .max_cycles = default_max_cycles };
        const code = runRom(io, allocator, options) catch |err| blk: {
            std.debug.print("{s}: error {s}\n", .{ name, @errorName(err) });
            break :blk 1;
        };
        const ok = code == 0;
        std.debug.print("{s}: {s}\n", .{ name, if (ok) "OK" else "FAIL" });
        if (!ok) failures += 1;
        allocator.free(name);
    }

    std.debug.print("\n{d}/{d} ROMs passed\n", .{ total - failures, total });
    return if (failures == 0) 0 else 1;
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

    var options = Options{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--trace")) {
            options.trace = true;
        } else if (std.mem.eql(u8, arg, "--max-cycles")) {
            index += 1;
            if (index >= argv.len) {
                std.debug.print("--max-cycles needs a value\n", .{});
                std.process.exit(2);
            }
            options.max_cycles = std.fmt.parseInt(u64, argv[index], 10) catch {
                std.debug.print("bad cycle count: {s}\n", .{argv[index]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--expect")) {
            index += 1;
            if (index >= argv.len) {
                std.debug.print("--expect needs a value\n", .{});
                std.process.exit(2);
            }
            if (std.mem.eql(u8, argv[index], "pass")) {
                options.expect = .pass;
            } else if (std.mem.eql(u8, argv[index], "fail")) {
                options.expect = .fail;
            } else if (std.mem.eql(u8, argv[index], "any")) {
                options.expect = .pass;
            } else {
                std.debug.print("bad --expect value: {s}\n", .{argv[index]});
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, arg, "--blargg-suite")) {
            index += 1;
            if (index >= argv.len) {
                std.debug.print("--blargg-suite needs a directory\n", .{});
                std.process.exit(2);
            }
            options.blargg_suite = argv[index];
        } else if (std.mem.eql(u8, arg, "--load-save")) {
            index += 1;
            if (index >= argv.len) {
                std.debug.print("--load-save needs a path\n", .{});
                std.process.exit(2);
            }
            options.load_save = argv[index];
        } else if (std.mem.eql(u8, arg, "--save")) {
            index += 1;
            if (index >= argv.len) {
                std.debug.print("--save needs a path\n", .{});
                std.process.exit(2);
            }
            options.save = argv[index];
        } else if (options.rom_path == null) {
            options.rom_path = arg;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            usage(argv[0]);
            std.process.exit(2);
        }
    }

    if (options.blargg_suite) |directory| {
        const code = try runSuite(io, allocator, directory);
        std.process.exit(code);
    }
    if (options.rom_path == null) {
        usage(argv[0]);
        std.process.exit(2);
    }

    const code = try runRom(io, allocator, options);
    std.process.exit(code);
}
