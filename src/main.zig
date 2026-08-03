const std = @import("std");
const Emulator = @import("emulator.zig").Emulator;
const ppu = @import("ppu.zig");

// The windowed frontend. It renders the emulated screen in an SDL2 window
// and maps a small set of keys to the joypad. The headless runner and the
// windowed frontend share the same core; only presentation lives here.

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});

const window_scale = 3;
const window_width = ppu.ScreenWidth * window_scale;
const window_height = ppu.ScreenHeight * window_scale;

const Joypad = struct {
    // Low nibble, active low, matches the SM83 joypad register.
    d_pad: u8 = 0x0f,
    buttons: u8 = 0x0f,

    fn set(self: *Joypad, bit: u3, pressed: bool) void {
        const mask: u8 = @as(u8, 1) << bit;
        if (pressed) {
            self.buttons &= ~mask;
        } else {
            self.buttons |= mask;
        }
    }

    fn setDpad(self: *Joypad, bit: u3, pressed: bool) void {
        const mask: u8 = @as(u8, 1) << bit;
        if (pressed) {
            self.d_pad &= ~mask;
        } else {
            self.d_pad |= mask;
        }
    }

    fn writeRegisters(self: *Joypad, emulator: *Emulator) void {
        emulator.bus.write(0xff00, 0x20 | self.d_pad);
        emulator.bus.write(0xff00, 0x10 | self.buttons);
    }
};

const KeyBinding = struct {
    scancode: c.SDL_Scancode,
    kind: enum { button, dpad },
    bit: u3,
};

const bindings = [_]KeyBinding{
    .{ .scancode = c.SDL_SCANCODE_Z, .kind = .button, .bit = 0 }, // A
    .{ .scancode = c.SDL_SCANCODE_X, .kind = .button, .bit = 1 }, // B
    .{ .scancode = c.SDL_SCANCODE_RSHIFT, .kind = .button, .bit = 2 }, // Select
    .{ .scancode = c.SDL_SCANCODE_RETURN, .kind = .button, .bit = 3 }, // Start
    .{ .scancode = c.SDL_SCANCODE_RIGHT, .kind = .dpad, .bit = 0 },
    .{ .scancode = c.SDL_SCANCODE_LEFT, .kind = .dpad, .bit = 1 },
    .{ .scancode = c.SDL_SCANCODE_UP, .kind = .dpad, .bit = 2 },
    .{ .scancode = c.SDL_SCANCODE_DOWN, .kind = .dpad, .bit = 3 },
};

fn keyPressed(joypad: *Joypad, scancode: c.SDL_Scancode, pressed: bool) bool {
    for (bindings) |binding| {
        if (binding.scancode == scancode) {
            switch (binding.kind) {
                .button => joypad.set(binding.bit, pressed),
                .dpad => joypad.setDpad(binding.bit, pressed),
            }
            return true;
        }
    }
    return false;
}

fn usage(program: []const u8) void {
    std.debug.print(
        \\Dot Matrix Deck - SDL2 windowed frontend
        \\Usage:
        \\  {s} <rom.gb>
        \\
        \\Keys: Z=A, X=B, Enter=Start, Shift=Select, arrows=d-pad. ESC quits.
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| try args.append(allocator, arg);

    if (args.items.len != 2) {
        usage(args.items[0]);
        std.process.exit(2);
    }

    const rom = try readFile(io, allocator, args.items[1]);
    defer allocator.free(rom);

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        std.process.exit(1);
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "Dot Matrix Deck",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        window_width,
        window_height,
        c.SDL_WINDOW_SHOWN,
    ) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        std.process.exit(1);
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        std.process.exit(1);
    };
    defer c.SDL_DestroyRenderer(renderer);

    _ = c.SDL_RenderSetLogicalSize(renderer, ppu.ScreenWidth, ppu.ScreenHeight);

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ARGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        ppu.ScreenWidth,
        ppu.ScreenHeight,
    ) orelse {
        std.debug.print("SDL_CreateTexture failed: {s}\n", .{c.SDL_GetError()});
        std.process.exit(1);
    };
    defer c.SDL_DestroyTexture(texture);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();

    var joypad = Joypad{};
    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.scancode == c.SDL_SCANCODE_ESCAPE) {
                        running = false;
                    } else {
                        _ = keyPressed(&joypad, event.key.keysym.scancode, true);
                    }
                },
                c.SDL_KEYUP => {
                    _ = keyPressed(&joypad, event.key.keysym.scancode, false);
                },
                else => {},
            }
        }

        joypad.writeRegisters(&emulator);
        emulator.runFrame(1 << 24);

        const frame = emulator.bus.ppu.frame;
        _ = c.SDL_UpdateTexture(texture, null, &frame, @as(c_int, @intCast(ppu.ScreenWidth)) * 4);
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
        c.SDL_RenderPresent(renderer);
        c.SDL_Delay(16);
    }
}
