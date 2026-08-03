// The windowed frontend.
//
// It opens an SDL2 window and shows the screen rendered by the PPU.
// Keyboard input maps to the joypad, and the loop runs at the console
// refresh rate. The emulation core is shared with the headless runner;
// only input and presentation live here.

const std = @import("std");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});

const Emulator = @import("emulator.zig").Emulator;
const cartridge = @import("cartridge.zig");
const ppu = @import("ppu.zig");

// A full frame of the pixel pipeline takes 70,224 T-cycles. The cap
// bounds how far a single runFrame call can advance.
const frame_cycles: u64 = 70_224;
const target_fps: f64 = 59.7275;

// Game Boy buttons are low active: a pressed button clears its bit.
const Joypad = struct {
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
        \\  {s} <rom.gb> [--scale N]
        \\
        \\Controls:
        \\  X           A button
        \\  Z           B button
        \\  Enter       Start
        \\  Backspace   Select
        \\  Arrows      D-pad
        \\  Esc         Quit
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

// Applies one key event to the button state. Returns true when the key
// maps to a joypad button.
fn applyScancode(scancode: c.SDL_Scancode, buttons: *u8, pressed: bool) bool {
    const mask: ?u8 = switch (scancode) {
        c.SDL_SCANCODE_Z => Joypad.b,
        c.SDL_SCANCODE_X => Joypad.a,
        c.SDL_SCANCODE_RETURN => Joypad.start,
        c.SDL_SCANCODE_BACKSPACE => Joypad.select,
        c.SDL_SCANCODE_RIGHT => Joypad.right,
        c.SDL_SCANCODE_LEFT => Joypad.left,
        c.SDL_SCANCODE_UP => Joypad.up,
        c.SDL_SCANCODE_DOWN => Joypad.down,
        else => null,
    };
    if (mask) |bit| {
        if (pressed) {
            buttons.* &= ~bit;
        } else {
            buttons.* |= bit;
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

        const header = cartridge.readHeader(emulator.bus.cartridge.rom);
        var caption_buffer: [64]u8 = undefined;
        const raw_title = std.mem.sliceTo(&header.title, 0);
        const caption = std.fmt.bufPrint(&caption_buffer, "Dot Matrix Deck - {s}", .{raw_title}) catch "Dot Matrix Deck";

        const window = c.SDL_CreateWindow(
            caption.ptr,
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

    // Polls events and updates the joypad. Returns true when the loop
    // should stop.
    fn handleEvents(self: *Frontend, buttons: *u8) bool {
        var event: c.SDL_Event = undefined;
        var quit = false;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => quit = true,
                c.SDL_KEYDOWN => {
                    const scancode = event.key.keysym.scancode;
                    if (scancode == c.SDL_SCANCODE_ESCAPE) {
                        quit = true;
                    } else {
                        _ = applyScancode(scancode, buttons, true);
                    }
                },
                c.SDL_KEYUP => _ = applyScancode(event.key.keysym.scancode, buttons, false),
                else => {},
            }
        }
        self.emulator.bus.setButtons(buttons.*);
        return quit;
    }

    // Copies the PPU frame into the texture and presents it. SDL may
    // pad each row with unused bytes, so rows are copied separately.
    fn presentFrame(self: *Frontend) void {
        const bytes_per_row = ppu.ScreenWidth * @sizeOf(u32);
        var pixels: ?*anyopaque = null;
        var pitch: c_int = 0;
        if (c.SDL_LockTexture(self.texture, null, &pixels, &pitch) == 0) {
            const dst = @as([*]u8, @ptrCast(pixels.?));
            const frame = &self.emulator.bus.ppu.frame;
            for (0..ppu.ScreenHeight) |row| {
                const src = std.mem.sliceAsBytes(frame[row * ppu.ScreenWidth ..][0..ppu.ScreenWidth]);
                @memcpy(dst[@as(usize, @intCast(pitch)) * row ..][0..bytes_per_row], src);
            }
            c.SDL_UnlockTexture(self.texture);
        }
        _ = c.SDL_RenderClear(self.renderer);
        _ = c.SDL_RenderCopy(self.renderer, self.texture, null, null);
        c.SDL_RenderPresent(self.renderer);
    }

    fn run(self: *Frontend, io: std.Io) void {
        var buttons: u8 = 0xff;
        var last_frame = std.Io.Clock.Timestamp.now(io, .awake);
        const frame_ns: i96 = @intFromFloat(@as(f64, std.time.ns_per_s) / target_fps);

        while (true) {
            if (self.handleEvents(&buttons)) break;
            self.emulator.runFrame(frame_cycles);
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

    var argument_iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer argument_iterator.deinit();

    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    while (argument_iterator.next()) |arg| try arguments.append(allocator, arg);
    const argv = arguments.items;

    var rom_path: ?[]const u8 = null;
    var scale: u32 = 3;
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--scale") and index + 1 < argv.len) {
            index += 1;
            scale = std.fmt.parseInt(u32, argv[index], 10) catch {
                std.debug.print("bad scale value: {s}\n", .{argv[index]});
                std.process.exit(2);
            };
            if (scale == 0 or scale > 8) {
                std.debug.print("scale must be between 1 and 8\n", .{});
                std.process.exit(2);
            }
        } else if (rom_path == null) {
            rom_path = arg;
        } else {
            usage(argv[0]);
            std.process.exit(2);
        }
    }

    if (rom_path == null) {
        usage(argv[0]);
        std.process.exit(2);
    }

    const rom = try readFile(io, allocator, rom_path.?);
    defer allocator.free(rom);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();

    var frontend = Frontend.init(&emulator, scale);
    defer frontend.deinit();

    frontend.run(io);
}
