const std = @import("std");
const Emulator = @import("emulator.zig").Emulator;
const frontend = @import("frontend.zig");
const ppu = @import("ppu.zig");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});

const frame_cap: u64 = 1 << 24;
const frame_ms: u32 = 16;
const fast_forward_frames: u32 = 4;

const ScancodeKey = struct {
    scancode: c.SDL_Scancode,
    key: frontend.Key,
};

const scancode_map = [_]ScancodeKey{
    .{ .scancode = c.SDL_SCANCODE_RIGHT, .key = .right },
    .{ .scancode = c.SDL_SCANCODE_LEFT, .key = .left },
    .{ .scancode = c.SDL_SCANCODE_UP, .key = .up },
    .{ .scancode = c.SDL_SCANCODE_DOWN, .key = .down },
    .{ .scancode = c.SDL_SCANCODE_Z, .key = .a },
    .{ .scancode = c.SDL_SCANCODE_X, .key = .b },
    .{ .scancode = c.SDL_SCANCODE_RSHIFT, .key = .select },
    .{ .scancode = c.SDL_SCANCODE_LSHIFT, .key = .select },
    .{ .scancode = c.SDL_SCANCODE_RETURN, .key = .start },
    .{ .scancode = c.SDL_SCANCODE_P, .key = .pause },
    .{ .scancode = c.SDL_SCANCODE_R, .key = .reset },
    .{ .scancode = c.SDL_SCANCODE_F, .key = .fast_forward },
};

fn keyFor(scancode: c.SDL_Scancode) ?frontend.Key {
    for (scancode_map) |mapping| {
        if (mapping.scancode == scancode) return mapping.key;
    }
    return null;
}

fn usage(program: []const u8) void {
    std.debug.print(
        \\Dot Matrix Deck - SDL2 windowed frontend
        \\Usage:
        \\  {s} <rom.gb>
        \\
        \\Keys: Z=A, X=B, Enter=Start, Shift=Select, arrows=d-pad.
        \\P pause, R reset, F fast forward, ESC quit.
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

fn sdlError(context: []const u8) noreturn {
    std.debug.print("{s}: {s}\n", .{ context, std.mem.span(c.SDL_GetError()) });
    std.process.exit(1);
}

fn rect(x: c_int, y: c_int, width: c_int, height: c_int) c.SDL_Rect {
    return .{ .x = x, .y = y, .w = width, .h = height };
}

const color = struct {
    fn set(renderer: *c.SDL_Renderer, value: u32) void {
        _ = c.SDL_SetRenderDrawColor(renderer, @truncate(value >> 16), @truncate(value >> 8), @truncate(value), 0xff);
    }
};

fn drawPauseOverlay(renderer: *c.SDL_Renderer) void {
    const bar_w: c_int = 6;
    const bar_h: c_int = @intCast(frontend.screen_rect.height / 3);
    const gap: c_int = 14;
    const y = frontend.screen_rect.y + (frontend.screen_rect.height - bar_h) / 2;
    const x1 = frontend.screen_rect.x + frontend.screen_rect.width / 2 - gap - bar_w;
    const x2 = frontend.screen_rect.x + frontend.screen_rect.width / 2 + gap;
    color.set(renderer, frontend.palette.paused_bar);
    _ = c.SDL_RenderFillRect(renderer, &rect(x1, y, bar_w, bar_h));
    _ = c.SDL_RenderFillRect(renderer, &rect(x2, y, bar_w, bar_h));
}

fn drawPixelGrid(renderer: *c.SDL_Renderer) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, 0x10, 0x14, 0x10, 0x26);
    var index: usize = 1;
    while (index < ppu.ScreenWidth) : (index += 1) {
        const x = frontend.screen_rect.x + @as(c_int, @intCast(index * frontend.screen_scale));
        _ = c.SDL_RenderDrawLine(renderer, x, frontend.screen_rect.y, x, frontend.screen_rect.y + frontend.screen_rect.height - 1);
    }
    index = 1;
    while (index < ppu.ScreenHeight) : (index += 1) {
        const y = frontend.screen_rect.y + @as(c_int, @intCast(index * frontend.screen_scale));
        _ = c.SDL_RenderDrawLine(renderer, frontend.screen_rect.x, y, frontend.screen_rect.x + frontend.screen_rect.width - 1, y);
    }
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
}

// Re-applies held keys after a reset so the joypad state stays in sync.
fn syncHeldKeys(emulator: *Emulator) void {
    const keyboard = c.SDL_GetKeyboardState(null);
    for (scancode_map) |mapping| {
        _ = frontend.applyKey(&emulator.bus, mapping.key, false);
    }
    for (scancode_map) |mapping| {
        const down = keyboard[mapping.scancode] != 0;
        _ = frontend.applyKey(&emulator.bus, mapping.key, down);
    }
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

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) sdlError("SDL_Init failed");
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "Dot Matrix Deck",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        @intCast(frontend.window_width),
        @intCast(frontend.window_height),
        c.SDL_WINDOW_SHOWN,
    ) orelse sdlError("SDL_CreateWindow failed");
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse
        sdlError("SDL_CreateRenderer failed");
    defer c.SDL_DestroyRenderer(renderer);

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ARGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        ppu.ScreenWidth,
        ppu.ScreenHeight,
    ) orelse sdlError("SDL_CreateTexture failed");
    defer c.SDL_DestroyTexture(texture);

    var emulator = try Emulator.init(allocator, rom);
    defer emulator.deinit();

    var run_state = frontend.RunState{};
    var last_tick = c.SDL_GetTicks();

    while (run_state.running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => run_state.running = false,
                c.SDL_KEYDOWN => {
                    if (event.key.repeat != 0) break;
                    const scancode = event.key.keysym.scancode;
                    if (scancode == c.SDL_SCANCODE_ESCAPE) {
                        run_state.running = false;
                        break;
                    }
                    const key = keyFor(scancode) orelse continue;
                    switch (key) {
                        .pause => run_state.togglePause(),
                        .fast_forward => run_state.toggleFastForward(),
                        .reset => {
                            emulator.reset();
                            syncHeldKeys(&emulator);
                        },
                        else => _ = frontend.applyKey(&emulator.bus, key, true),
                    }
                },
                c.SDL_KEYUP => {
                    if (event.key.repeat != 0) break;
                    const key = keyFor(event.key.keysym.scancode) orelse continue;
                    _ = frontend.applyKey(&emulator.bus, key, false);
                },
                else => {},
            }
        }

        if (!run_state.paused) {
            const frames: u32 = if (run_state.fast_forward) fast_forward_frames else 1;
            var frame_index: u32 = 0;
            while (frame_index < frames) : (frame_index += 1) {
                emulator.runFrame(frame_cap);
            }
        }

        const frame = emulator.bus.ppu.frame;
        _ = c.SDL_UpdateTexture(texture, null, &frame, @as(c_int, @intCast(ppu.ScreenWidth * @sizeOf(u32))));
        color.set(renderer, frontend.palette.shell);
        _ = c.SDL_RenderClear(renderer);
        color.set(renderer, frontend.palette.bezel);
        _ = c.SDL_RenderFillRect(renderer, &rect(
            frontend.screen_rect.x - 6,
            frontend.screen_rect.y - 6,
            frontend.screen_rect.width + 12,
            frontend.screen_rect.height + 12,
        ));
        _ = c.SDL_RenderCopy(renderer, texture, null, &rect(
            frontend.screen_rect.x,
            frontend.screen_rect.y,
            frontend.screen_rect.width,
            frontend.screen_rect.height,
        ));
        drawPixelGrid(renderer);
        if (run_state.paused) drawPauseOverlay(renderer);
        c.SDL_RenderPresent(renderer);

        const now = c.SDL_GetTicks();
        const elapsed = now -% last_tick;
        if (elapsed < frame_ms) c.SDL_Delay(frame_ms - elapsed);
        last_tick = now;
    }
}
