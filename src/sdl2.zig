// Minimal SDL2 bindings for the windowed frontend.
//
// The bindings declare the subset of the SDL2 C API that the frontend
// needs. They are hand-written against the stable SDL2 ABI. The build
// links the system SDL2 library, so a C header translator is not needed.

pub const InitFlags = struct {
    pub const video: u32 = 0x00000020;
};

pub const WindowFlags = struct {
    pub const shown: u32 = 0x00000004;
    pub const resizable: u32 = 0x00000020;
};

pub const RendererFlags = struct {
    pub const accelerated: u32 = 0x00000002;
    pub const present_vsync: u32 = 0x00000004;
};

pub const TextureAccess = struct {
    pub const streaming: c_int = 1;
};

pub const PixelFormat = struct {
    pub const bgra8888: u32 = 0x16862004;
};

pub const EventType = struct {
    pub const quit: u32 = 0x100;
    pub const key_down: u32 = 0x300;
    pub const key_up: u32 = 0x301;
};

pub const KeyCode = struct {
    pub const right: c_int = 0x4000004f;
    pub const left: c_int = 0x40000050;
    pub const down: c_int = 0x40000051;
    pub const up: c_int = 0x40000052;
    pub const enter: c_int = 0x40000028;
    pub const escape: c_int = 0x40000029;
    pub const backspace: c_int = 0x4000002a;
    pub const z: c_int = 0x7a;
    pub const x: c_int = 0x78;
};

pub const Keysym = extern struct {
    scancode: c_int,
    sym: c_int,
    mod: u16,
    unused: u32,
};

pub const KeyboardEvent = extern struct {
    event_type: u32,
    timestamp: u32,
    window_id: u32,
    state: u8,
    repeat: u8,
    padding: [2]u8,
    keysym: Keysym,
};

pub const Event = extern union {
    event_type: u32,
    key: KeyboardEvent,
    padding: [56]u8,
};

pub const Window = opaque {};
pub const Renderer = opaque {};
pub const Texture = opaque {};
pub const Rect = extern struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub extern "c" fn SDL_SetMainReady() void;
pub extern "c" fn SDL_Init(flags: u32) c_int;
pub extern "c" fn SDL_Quit() void;
pub extern "c" fn SDL_GetError() [*:0]const u8;
pub extern "c" fn SDL_GetTicks() u32;
pub extern "c" fn SDL_Delay(ms: u32) void;
pub extern "c" fn SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: u32) ?*Window;
pub extern "c" fn SDL_SetWindowTitle(window: ?*Window, title: [*:0]const u8) void;
pub extern "c" fn SDL_CreateRenderer(window: ?*Window, index: c_int, flags: u32) ?*Renderer;
pub extern "c" fn SDL_RenderSetLogicalSize(renderer: ?*Renderer, w: c_int, h: c_int) c_int;
pub extern "c" fn SDL_CreateTexture(renderer: ?*Renderer, format: u32, access: c_int, w: c_int, h: c_int) ?*Texture;
pub extern "c" fn SDL_UpdateTexture(texture: ?*Texture, rect: ?*const Rect, pixels: *const anyopaque, pitch: c_int) c_int;
pub extern "c" fn SDL_RenderClear(renderer: ?*Renderer) c_int;
pub extern "c" fn SDL_RenderCopy(renderer: ?*Renderer, texture: ?*Texture, src: ?*const Rect, dst: ?*const Rect) c_int;
pub extern "c" fn SDL_RenderPresent(renderer: ?*Renderer) void;
pub extern "c" fn SDL_PollEvent(event: *Event) c_int;
pub extern "c" fn SDL_DestroyTexture(texture: ?*Texture) void;
pub extern "c" fn SDL_DestroyRenderer(renderer: ?*Renderer) void;
pub extern "c" fn SDL_DestroyWindow(window: ?*Window) void;
