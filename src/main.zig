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

const default_key_config = "dmd.keys.conf";

const ScancodeKey = struct {
    scancode: c.SDL_Scancode,
    key: frontend.Key,
};

// Resolves scancode names from the key map into SDL scancodes. Each name
// comes from the SDL scancode vocabulary, for example "z" or "left shift".
fn resolveKeyMap(allocator: std.mem.Allocator, bindings: []const frontend.KeyBinding) ![]ScancodeKey {
    var resolved: std.ArrayListUnmanaged(ScancodeKey) = .empty;
    errdefer resolved.deinit(allocator);
    for (bindings) |binding| {
        const name = try allocator.dupeZ(u8, binding.scancode_name);
        defer allocator.free(name);
        const scancode = c.SDL_GetScancodeFromName(name.ptr);
        if (scancode == c.SDL_SCANCODE_UNKNOWN) {
            std.debug.print("Unknown key name in config: {s}\n", .{binding.scancode_name});
            return error.UnknownKeyName;
        }
        try resolved.append(allocator, .{ .scancode = scancode, .key = binding.key });
    }
    return resolved.toOwnedSlice(allocator);
}

fn keyFor(resolved: []const ScancodeKey, scancode: c.SDL_Scancode) ?frontend.Key {
    for (resolved) |entry| {
        if (entry.scancode == scancode) return entry.key;
    }
    return null;
}

fn usage(program: []const u8) void {
    std.debug.print(
        \\Dot Matrix Deck - SDL2 windowed frontend
        \\Usage:
        \\  {s} <rom.gb> [--keys <path>]
        \\
        \\Keys: Z=A, X=B, Enter=Start, Shift=Select, arrows=d-pad.
        \\P pause, R reset, F fast forward, ESC quit.
        \\Battery RAM loads from and saves to a .sav file next to the ROM.
        \\Key bindings load from dmd.keys.conf in the working directory.
        \\Pass --keys to use another config file instead.
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

// Reads the key config file. When the path is explicit and the file is
// missing, returns an error. When no path is given and the default file
// is missing, returns null so the built-in defaults apply.
fn loadKeyConfig(io: std.Io, allocator: std.mem.Allocator, keys_path: ?[]const u8) !?[]u8 {
    const path = keys_path orelse default_key_config;
    const dir = std.Io.Dir.cwd();
    if (dir.access(io, path, .{})) |_| {
        return try readFile(io, allocator, path);
    } else |_| {
        if (keys_path != null) return error.MissingKeyConfig;
        return null;
    }
}

// A battery save file sits next to the ROM with a .sav extension.
fn savePathFor(allocator: std.mem.Allocator, rom_path: []const u8) ![]u8 {
    const extension = std.fs.path.extension(rom_path);
    if (extension.len == 0) return std.fmt.allocPrint(allocator, "{s}.sav", .{rom_path});
    return std.fmt.allocPrint(allocator, "{s}.sav", .{rom_path[0 .. rom_path.len - extension.len]});
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

// Draws faint lines between pixels to echo the DMG dot matrix.
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
fn syncHeldKeys(emulator: *Emulator, resolved: []const ScancodeKey) void {
    const keyboard = c.SDL_GetKeyboardState(null);
    for (resolved) |entry| {
        _ = frontend.applyKey(&emulator.bus, entry.key, false);
    }
    for (resolved) |entry| {
        const down = keyboard[entry.scancode] != 0;
        _ = frontend.applyKey(&emulator.bus, entry.key, down);
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

    var keys_path: ?[]const u8 = null;
    var rom_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.items.len) : (index += 1) {
        const arg = args.items[index];
        if (std.mem.eql(u8, arg, "--keys")) {
            index += 1;
            if (index >= args.items.len) {
                std.debug.print("--keys needs a path\n", .{});
                std.process.exit(2);
            }
            keys_path = args.items[index];
        } else if (rom_path == null) {
            rom_path = arg;
        } else {
            usage(args.items[0]);
            std.process.exit(2);
        }
    }

    if (rom_path == null) {
        usage(args.items[0]);
        std.process.exit(2);
    }

    const rom = try readFile(io, allocator, rom_path.?);
    defer allocator.free(rom);

    const key_text = loadKeyConfig(io, allocator, keys_path) catch |err| {
        std.debug.print("Could not read key config: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer if (key_text) |text| allocator.free(text);

    var bindings: []const frontend.KeyBinding = frontend.defaultKeyMap();
    var bindings_owned = false;
    if (key_text) |text| {
        const overrides = frontend.parseKeyMap(allocator, text) catch |err| {
            std.debug.print("Bad key config: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer allocator.free(overrides);
        bindings = frontend.mergeKeyMap(allocator, overrides) catch |err| {
            std.debug.print("Bad key config: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        bindings_owned = true;
    }
    defer if (bindings_owned) allocator.free(bindings);

    const resolved = resolveKeyMap(allocator, bindings) catch |err| {
        std.debug.print("Bad key config: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(resolved);

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

    const save_path = try savePathFor(allocator, rom_path.?);
    defer allocator.free(save_path);
    var loaded = false;
    if (emulator.loadSaveFile(io, std.Io.Dir.cwd(), save_path)) |ok| {
        loaded = ok;
    } else |err| {
        std.debug.print("Could not load save file {s}: {s}\n", .{ save_path, @errorName(err) });
    }
    if (emulator.hasSaveData()) {
        std.debug.print("{s}\n", .{if (loaded) "Loaded save data." else "No save data found; starting fresh."});
    }

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
                    const key = keyFor(resolved, scancode) orelse continue;
                    switch (key) {
                        .pause => run_state.togglePause(),
                        .fast_forward => run_state.toggleFastForward(),
                        .reset => {
                            emulator.reset();
                            syncHeldKeys(&emulator, resolved);
                        },
                        else => _ = frontend.applyKey(&emulator.bus, key, true),
                    }
                },
                c.SDL_KEYUP => {
                    if (event.key.repeat != 0) break;
                    const key = keyFor(resolved, event.key.keysym.scancode) orelse continue;
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

    emulator.saveSaveFile(io, std.Io.Dir.cwd(), save_path) catch |err| {
        std.debug.print("Could not write save file {s}: {s}\n", .{ save_path, @errorName(err) });
    };
}
