const std = @import("std");
const joypad = @import("joypad.zig");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});

const Emulator = @import("emulator.zig").Emulator;
const ppu = @import("ppu.zig");

// The windowed frontend. It opens an SDL2 window, blits the PPU frame
// through a streaming texture, and maps keyboard input to the joypad.
// The emulation core is shared with the headless runner; only input and
// presentation live here.

const frame_cycles: u64 = 70_224;
const target_fps: f64 = 59.7275;
const default_scale: u32 = 3;

fn usage(program: []const u8) void {
    std.debug.print(
        \\Dot Matrix Deck - windowed frontend
        \\Usage:
        \\  {s} <rom.gb> [--scale N]
        \\
        \\Controls:
        \\  Z            B button
        \\  X            A button
        \\  Enter        Start
        \\  Backspace    Select
        \\  Arrow keys   D-pad
        \\  Esc          Quit
        \\
    , .{program});
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

// Converts an SDL scancode to a joypad key. Returns null for keys that
// do not control the Game Boy.
fn keyOf(scancode: c.SDL_Scancode) ?joypad.Key {
    return switch (scancode) {
        c.SDL_SCANCODE_Z => .b,
        c.SDL_SCANCODE_X => .a,
        c.SDL_SCANCODE_RETURN => .start,
        c.SDL_SCANCODE_BACKSPACE => .select,
        c.SDL_SCANCODE_RIGHT => .right,
        c.SDL_SCANCODE_LEFT => .left,
        c.SDL_SCANCODE_UP => .up,
        c.SDL_SCANCODE_DOWN => .down,
        else => null,
    };
}

const Frontend = struct {
    emulator: *Emulator,
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,
    frame_time: i96 = 0,
    elapsed_frames: u32 = 0,

    fn fail(prefix: []const u8) noreturn {
        std.debug.print("{s}: {s}\n", .{ prefix, c.SDL_GetError() });
        std.process.exit(1);
    }

    fn init(emulator: *Emulator, scale: u32) Frontend {
        _ = c.SDL_SetMainReady();
        if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS) != 0) fail("SDL_Init failed");
        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "nearest");

        const width: c_int = @intCast(@as(u32, @intCast(ppu.ScreenWidth)) * scale);
        const height: c_int = @intCast(@as(u32, @intCast(ppu.ScreenHeight)) * scale);

        const title = "Dot Matrix Deck";
        const window = c.SDL_CreateWindow(
            title,
            c.SDL_WINDOWPOS_UNDEFINED,
            c.SDL_WINDOWPOS_UNDEFINED,
            width,
            height,
            c.SDL_WINDOW_SHOWN,
        ) orelse fail("SDL_CreateWindow failed");

        const renderer = c.SDL_CreateRenderer(
            window,
            -1,
            c.SDL_RENDERER_ACCELERATED,
        ) orelse c.SDL_CreateRenderer(window, -1, 0) orelse fail("SDL_CreateRenderer failed");

        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(ppu.ScreenWidth),
            @intCast(ppu.ScreenHeight),
        ) orelse fail("SDL_CreateTexture failed");

        return .{ .emulator = emulator, .window = window, .renderer = renderer, .texture = texture };
    }

    fn deinit(self: *Frontend) void {
        c.SDL_DestroyTexture(self.texture);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    // Returns true when the loop should stop.
    fn handleEvents(self: *Frontend) bool {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => return true,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.scancode == c.SDL_SCANCODE_ESCAPE) return true;
                    if (keyOf(event.key.keysym.scancode)) |key| {
                        joypad.apply(key, true, &self.emulator.bus.joypad);
                    }
                },
                c.SDL_KEYUP => {
                    if (keyOf(event.key.keysym.scancode)) |key| {
                        joypad.apply(key, false, &self.emulator.bus.joypad);
                    }
                },
                else => {},
            }
        }
        return false;
    }

    fn presentFrame(self: *Frontend) void {
        var pixels: ?*anyopaque = null;
        var pitch: c_int = 0;
        if (c.SDL_LockTexture(self.texture, null, &pixels, &pitch) == 0) {
            const dst = @as([*]u8, @ptrCast(pixels.?));
            const src = std.mem.sliceAsBytes(self.emulator.bus.ppu.frame[0..]);
            @memcpy(dst[0..src.len], src);
            c.SDL_UnlockTexture(self.texture);
        }
        _ = c.SDL_RenderClear(self.renderer);
        _ = c.SDL_RenderCopy(self.renderer, self.texture, null, null);
        c.SDL_RenderPresent(self.renderer);
    }

    fn updateTitle(self: *Frontend) void {
        var buffer: [48]u8 = undefined;
        const fps: f64 = if (self.frame_time != 0) @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(self.frame_time)) else 0;
        const text = std.fmt.bufPrint(&buffer, "Dot Matrix Deck - {d:.1} fps", .{fps}) catch return;
        c.SDL_SetWindowTitle(self.window, text.ptr);
    }

    fn run(self: *Frontend, io: std.Io) !void {
        var last_frame = std.Io.Clock.Timestamp.now(io, .awake);
        var last_title = last_frame;
        const frame_ns: i96 = @intFromFloat(@as(f64, std.time.ns_per_s) / target_fps);

        var running = true;
        while (running) {
            running = !self.handleEvents();
            if (!running) break;

            self.emulator.runFrame(frame_cycles);
            self.presentFrame();
            self.elapsed_frames += 1;

            const now = std.Io.Clock.Timestamp.now(io, .awake);
            const elapsed = last_frame.durationTo(now).raw.nanoseconds;
            const slack = frame_ns - elapsed;
            if (slack > 0) {
                const millis: u32 = @intCast(@divTrunc(slack, std.time.ns_per_ms));
                c.SDL_Delay(millis);
            }
            const paced = std.Io.Clock.Timestamp.now(io, .awake);
            self.frame_time = last_frame.durationTo(paced).raw.nanoseconds;
            last_frame = paced;

            if (paced.durationTo(last_title).raw.nanoseconds >= std.time.ns_per_s) {
                self.updateTitle();
                last_title = paced;
            }
        }
    }
};

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

    var rom_path: ?[]const u8 = null;
    var scale: u32 = default_scale;
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--scale")) {
            index += 1;
            if (index >= argv.len) {
                std.debug.print("--scale needs a value\n", .{});
                std.process.exit(2);
            }
            scale = std.fmt.parseInt(u32, argv[index], 10) catch {
                std.debug.print("bad scale value: {s}\n", .{argv[index]});
                std.process.exit(2);
            };
            if (scale == 0) scale = 1;
        } else if (rom_path == null) {
            rom_path = arg;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            usage(argv[0]);
            std.process.exit(2);
        }
    }

    const rom = try readFile(io, allocator, rom_path.?);
    defer allocator.free(rom);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();

    var frontend = Frontend.init(&emulator, scale);
    defer frontend.deinit();

    try frontend.run(io);
}
