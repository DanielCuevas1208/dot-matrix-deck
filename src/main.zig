const std = @import("std");
const Emulator = @import("emulator.zig").Emulator;
const ppu = @import("ppu.zig");
const sdl = @import("sdl2.zig");

// The windowed frontend. It opens an SDL2 window, renders the PPU frame,
// and maps keyboard input to the Game Boy joypad. The emulation core is
// shared with the headless runner; only presentation and input live here.

const ScreenWidth = 160;
const ScreenHeight = 144;
const WindowScale = 3;
const FrameMs: u32 = 1000 / 60;

const Gamepad = struct {
    dpad: u8 = 0x0f,
    buttons: u8 = 0x0f,

    fn keyDown(self: *Gamepad, sym: c_int, running: *bool) void {
        const mask = switch (sym) {
            sdl.KeyCode.right => @as(u8, 0x01),
            sdl.KeyCode.left => @as(u8, 0x02),
            sdl.KeyCode.up => @as(u8, 0x04),
            sdl.KeyCode.down => @as(u8, 0x08),
            else => 0,
        };
        if (mask != 0) {
            self.dpad &= ~mask;
            return;
        }
        const button_mask = switch (sym) {
            sdl.KeyCode.z => @as(u8, 0x01), // A
            sdl.KeyCode.x => @as(u8, 0x02), // B
            sdl.KeyCode.backspace => @as(u8, 0x04), // Select
            sdl.KeyCode.enter => @as(u8, 0x08), // Start
            else => 0,
        };
        if (button_mask != 0) {
            self.buttons &= ~button_mask;
            return;
        }
        if (sym == sdl.KeyCode.escape) running.* = false;
    }

    fn keyUp(self: *Gamepad, sym: c_int) void {
        const mask = switch (sym) {
            sdl.KeyCode.right => @as(u8, 0x01),
            sdl.KeyCode.left => @as(u8, 0x02),
            sdl.KeyCode.up => @as(u8, 0x04),
            sdl.KeyCode.down => @as(u8, 0x08),
            else => 0,
        };
        if (mask != 0) {
            self.dpad |= mask;
            return;
        }
        const button_mask = switch (sym) {
            sdl.KeyCode.z => @as(u8, 0x01),
            sdl.KeyCode.x => @as(u8, 0x02),
            sdl.KeyCode.backspace => @as(u8, 0x04),
            sdl.KeyCode.enter => @as(u8, 0x08),
            else => 0,
        };
        if (button_mask != 0) self.buttons |= button_mask;
    }
};

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const buffer = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

fn usage(program: []const u8) void {
    std.debug.print(
        \\Dot Matrix Deck - windowed frontend
        \\Usage: {s} <rom.gb>
        \\
        \\Arrow keys move the D-pad. Z is A, X is B.
        \\Enter is Start, Backspace is Select. Esc quits.
        \\
    , .{program});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| try args.append(allocator, arg);
    const argv = args.items;

    const program = if (argv.len != 0) argv[0] else "dot-matrix-deck";
    if (argv.len < 2 or argv.len > 2) {
        usage(program);
        std.process.exit(2);
    }
    const rom_path = argv[1];

    const rom = readFile(io, allocator, rom_path) catch |err| {
        fail("could not read {s}: {s}", .{ rom_path, @errorName(err) });
    };
    defer allocator.free(rom);

    var emulator = Emulator.init(allocator, rom) catch |err| {
        fail("could not start emulator: {s}", .{@errorName(err)});
    };
    defer emulator.deinit();

    sdl.SDL_SetMainReady();
    if (sdl.SDL_Init(sdl.InitFlags.video) != 0) {
        fail("SDL_Init failed: {s}", .{sdl.SDL_GetError()});
    }
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow(
        "Dot Matrix Deck",
        0x1fff0000, // SDL_WINDOWPOS_UNDEFINED
        0x1fff0000, // SDL_WINDOWPOS_UNDEFINED
        ScreenWidth * WindowScale,
        ScreenHeight * WindowScale,
        sdl.WindowFlags.shown | sdl.WindowFlags.resizable,
    ) orelse {
        fail("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
    };
    defer sdl.SDL_DestroyWindow(window);

    const renderer = sdl.SDL_CreateRenderer(
        window,
        -1,
        sdl.RendererFlags.accelerated | sdl.RendererFlags.present_vsync,
    ) orelse {
        fail("SDL_CreateRenderer failed: {s}", .{sdl.SDL_GetError()});
    };
    defer sdl.SDL_DestroyRenderer(renderer);

    _ = sdl.SDL_RenderSetLogicalSize(renderer, ScreenWidth, ScreenHeight);

    const texture = sdl.SDL_CreateTexture(
        renderer,
        sdl.PixelFormat.bgra8888,
        sdl.TextureAccess.streaming,
        ScreenWidth,
        ScreenHeight,
    ) orelse {
        fail("SDL_CreateTexture failed: {s}", .{sdl.SDL_GetError()});
    };
    defer sdl.SDL_DestroyTexture(texture);

    var gamepad = Gamepad{};
    var running = true;
    var last_frame = sdl.SDL_GetTicks();

    while (running) {
        var event: sdl.Event = undefined;
        while (sdl.SDL_PollEvent(&event) != 0) {
            switch (event.event_type) {
                sdl.EventType.quit => running = false,
                sdl.EventType.key_down => gamepad.keyDown(event.key.keysym.sym, &running),
                sdl.EventType.key_up => gamepad.keyUp(event.key.keysym.sym),
                else => {},
            }
        }

        emulator.bus.setJoypad(gamepad.dpad, gamepad.buttons);
        emulator.runFrame(1_000_000);

        _ = sdl.SDL_UpdateTexture(
            texture,
            null,
            @ptrCast(&emulator.bus.ppu.frame),
            ScreenWidth * @sizeOf(u32),
        );
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderCopy(renderer, texture, null, null);
        sdl.SDL_RenderPresent(renderer);

        const now = sdl.SDL_GetTicks();
        const elapsed = now -% last_frame;
        if (elapsed < FrameMs) sdl.SDL_Delay(FrameMs - elapsed);
        last_frame = now;
    }
}
