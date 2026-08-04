//! SDL2 windowed frontend for dot-matrix-deck.
//!
//! The frontend owns the window, renderer, and texture. Each loop
//! iteration presents one emulated frame and reads the keyboard into a
//! held-buttons bitmask for the joypad. Everything SDL-specific lives
//! here so the emulator core stays portable.

const std = @import("std");
const joypad = @import("joypad.zig");
const ppu = @import("ppu.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub const Frontend = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,

    pub fn init(title: [:0]const u8) !Frontend {
        if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) return error.SdlInitFailed;
        errdefer c.SDL_Quit();

        const window = c.SDL_CreateWindow(
            title,
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            480,
            432,
            c.SDL_WINDOW_RESIZABLE,
        ) orelse return error.SdlWindowFailed;
        errdefer c.SDL_DestroyWindow(window);

        const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse
            c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_SOFTWARE) orelse return error.SdlRendererFailed;
        errdefer c.SDL_DestroyRenderer(renderer);

        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            ppu.ScreenWidth,
            ppu.ScreenHeight,
        ) orelse return error.SdlTextureFailed;

        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "nearest");
        _ = c.SDL_RenderSetLogicalSize(renderer, ppu.ScreenWidth, ppu.ScreenHeight);
        _ = c.SDL_RenderSetIntegerScale(renderer, 1);

        return .{ .window = window, .renderer = renderer, .texture = texture };
    }

    pub fn deinit(self: *Frontend) void {
        c.SDL_DestroyTexture(self.texture);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    // Uploads one emulated frame and shows it scaled to the window.
    pub fn present(self: *Frontend, frame: []const u32) void {
        _ = c.SDL_UpdateTexture(self.texture, null, frame.ptr, @as(c_int, @intCast(ppu.ScreenWidth * @sizeOf(u32))));
        _ = c.SDL_RenderClear(self.renderer);
        _ = c.SDL_RenderCopy(self.renderer, self.texture, null, null);
        c.SDL_RenderPresent(self.renderer);
    }

    // Throttles the loop to roughly 60 frames per second.
    pub fn throttle(self: *Frontend) void {
        _ = self;
        c.SDL_Delay(16);
    }

    // Polls the event queue. Returns false when the user closes the
    // window or presses Escape.
    pub fn poll(self: *Frontend) bool {
        _ = self;
        var running = true;
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) running = false;
                },
                else => {},
            }
        }
        return running;
    }

    // Reads the keyboard into a held-buttons bitmask for the joypad.
    pub fn heldButtons(self: *Frontend) u8 {
        _ = self;
        const state = c.SDL_GetKeyboardState(null);
        var held: u8 = 0;
        if (state[@as(usize, @intCast(c.SDL_SCANCODE_LEFT))] != 0) held |= joypad.buttons.left;
        if (state[@as(usize, @intCast(c.SDL_SCANCODE_RIGHT))] != 0) held |= joypad.buttons.right;
        if (state[@as(usize, @intCast(c.SDL_SCANCODE_UP))] != 0) held |= joypad.buttons.up;
        if (state[@as(usize, @intCast(c.SDL_SCANCODE_DOWN))] != 0) held |= joypad.buttons.down;
        if (state[@as(usize, @intCast(c.SDL_SCANCODE_Z))] != 0) held |= joypad.buttons.action_a;
        if (state[@as(usize, @intCast(c.SDL_SCANCODE_X))] != 0) held |= joypad.buttons.action_b;
        if (state[@as(usize, @intCast(c.SDL_SCANCODE_RETURN))] != 0) held |= joypad.buttons.action_start;
        if (state[@as(usize, @intCast(c.SDL_SCANCODE_BACKSPACE))] != 0) held |= joypad.buttons.action_select;
        return held;
    }
};
