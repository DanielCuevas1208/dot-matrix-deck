const std = @import("std");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});

const Emulator = @import("emulator.zig").Emulator;
const cartridge = @import("cartridge.zig");
const ppu = @import("ppu.zig");

// The windowed frontend. It opens an SDL2 window, blits the PPU frame
// through a streaming texture, and maps keyboard input to the joypad.
// The emulation core is shared with the headless runner; only input and
// presentation live here.

const frame_cycles: u64 = 70_224;
const target_fps: f64 = 59.7275;

const joypad_bits = struct {
    const right: u8 = 1 << 0;
    const left: u8 = 1 << 1;
    const up: u8 = 1 << 2;
    const down: u8 = 1 << 3;
    const a: u8 = 1 << 4;
    const b: u8 = 1 << 5;
    const select: u8 = 1 << 6;
    const start: u8 = 1 << 7;
};

fn usage(program: []const u8) void {
    std.debug.print(
        \\Dot Matrix Deck - windowed frontend
        \\Usage:
        \\  {s} <rom.gb>
        \\
        \\Controls:
        \\  Z         B button
        \\  X         A button
        \\  Enter     Start
        \\  Backspace Select
        \\  Arrows    D-pad
        \\  Esc       Quit
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

// Applies a key event to the joypad. Pressed bits are cleared, released
// bits are set, matching the low-active register on the Game Boy.
fn scancodeToButtons(scancode: c.SDL_Scancode, buttons: *u8, pressed: bool) bool {
    const bit: ?u8 = switch (scancode) {
        c.SDL_SCANCODE_Z => joypad_bits.b,
        c.SDL_SCANCODE_X => joypad_bits.a,
        c.SDL_SCANCODE_RETURN => joypad_bits.start,
        c.SDL_SCANCODE_BACKSPACE => joypad_bits.select,
        c.SDL_SCANCODE_RIGHT => joypad_bits.right,
        c.SDL_SCANCODE_LEFT => joypad_bits.left,
        c.SDL_SCANCODE_UP => joypad_bits.up,
        c.SDL_SCANCODE_DOWN => joypad_bits.down,
        else => null,
    };
    if (bit) |mask| {
        if (pressed) {
            buttons.* &= ~mask;
        } else {
            buttons.* |= mask;
        }
        return true;
    }
    return false;
}

const Frontend = struct {
    emulator: *Emulator,
    window: ?*c.SDL_Window,
    renderer: ?*c.SDL_Renderer,
    texture: ?*c.SDL_Texture,

    fn fail(message: []const u8) noreturn {
        std.debug.print("{s}: {s}\n", .{ message, c.SDL_GetError() });
        std.process.exit(1);
    }

    fn init(emulator: *Emulator, scale: u32) Frontend {
        _ = c.SDL_SetMainReady();
        if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS) != 0) fail("SDL_Init failed");
        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "nearest");

        const width: c_int = @intCast(@as(u32, @intCast(ppu.ScreenWidth)) * scale);
        const height: c_int = @intCast(@as(u32, @intCast(ppu.ScreenHeight)) * scale);

        var title_buf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Dot Matrix Deck", .{}) catch "Dot Matrix Deck";

        const window = c.SDL_CreateWindow(
            title.ptr,
            c.SDL_WINDOWPOS_UNDEFINED,
            c.SDL_WINDOWPOS_UNDEFINED,
            width,
            height,
            c.SDL_WINDOW_SHOWN,
        ) orelse fail("SDL_CreateWindow failed");

        const renderer = c.SDL_CreateRenderer(
            window,
            -1,
            c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
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
        if (self.texture) |texture| c.SDL_DestroyTexture(texture);
        if (self.renderer) |renderer| c.SDL_DestroyRenderer(renderer);
        if (self.window) |window| c.SDL_DestroyWindow(window);
        c.SDL_Quit();
    }

    // Returns true when the loop should stop.
    fn handleEvents(self: *Frontend) bool {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => return true,
                c.SDL_KEYDOWN => {
                    const handled = scancodeToButtons(event.key.keysym.scancode, &self.emulator.bus.joypad, true);
                    if (!handled and event.key.keysym.scancode == c.SDL_SCANCODE_ESCAPE) return true;
                },
                c.SDL_KEYUP => _ = scancodeToButtons(event.key.keysym.scancode, &self.emulator.bus.joypad, false),
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

    fn run(self: *Frontend, io: std.Io) !void {
        var last_frame = std.Io.Clock.Timestamp.now(io, .awake);
        const frame_ns: i128 = @intFromFloat(@as(f64, std.time.ns_per_s) / target_fps);

        var running = true;
        while (running) {
            running = !self.handleEvents();
            if (!running) break;

            self.emulator.runFrame(frame_cycles * 2);
            self.presentFrame();

            const now = std.Io.Clock.Timestamp.now(io, .awake);
            const elapsed = last_frame.durationTo(now).raw.nanoseconds;
            const slack = frame_ns - elapsed;
            if (slack > 0) {
                const millis: u32 = @intCast(@divTrunc(slack, std.time.ns_per_ms));
                c.SDL_Delay(millis);
            }
            last_frame = now;
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

    const rom = try readFile(io, allocator, argv[1]);
    defer allocator.free(rom);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();

    var frontend = Frontend.init(&emulator, 3);
    defer frontend.deinit();

    try frontend.run(io);
}
