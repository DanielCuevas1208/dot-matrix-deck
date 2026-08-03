// Frontend presentation logic that does not depend on SDL2.
//
// The windowed frontend maps keyboard keys to the joypad, lays out the
// window, and shades the LCD palette. Keeping this logic free of SDL2
// lets the unit tests run in headless builds.

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const Joypad = @import("joypad.zig").Joypad;
const ppu = @import("ppu.zig");

pub const screen_scale = 3;
pub const bezel_padding = 16;

pub const window_width = ppu.ScreenWidth * screen_scale + bezel_padding * 2;
pub const window_height = ppu.ScreenHeight * screen_scale + bezel_padding * 2;

pub const screen_rect = struct {
    pub const x: c_int = bezel_padding;
    pub const y: c_int = bezel_padding;
    pub const width: c_int = ppu.ScreenWidth * screen_scale;
    pub const height: c_int = ppu.ScreenHeight * screen_scale;
};

// Logical keys. The SDL2 frontend translates scancodes into these.
pub const Key = enum {
    right,
    left,
    up,
    down,
    a,
    b,
    select,
    start,
    pause,
    reset,
    fast_forward,
};

pub const key_count = @typeInfo(Key).@"enum".fields.len;

pub const KeyAction = enum { button, direction };

pub const Binding = struct {
    key: Key,
    action: KeyAction,
    bit: u3,
};

pub const bindings = [_]Binding{
    .{ .key = .a, .action = .button, .bit = 0 },
    .{ .key = .b, .action = .button, .bit = 1 },
    .{ .key = .select, .action = .button, .bit = 2 },
    .{ .key = .start, .action = .button, .bit = 3 },
    .{ .key = .right, .action = .direction, .bit = 0 },
    .{ .key = .left, .action = .direction, .bit = 1 },
    .{ .key = .up, .action = .direction, .bit = 2 },
    .{ .key = .down, .action = .direction, .bit = 3 },
};

pub const RunState = struct {
    paused: bool = false,
    fast_forward: bool = false,
    running: bool = true,

    pub fn togglePause(self: *RunState) void {
        self.paused = !self.paused;
    }

    pub fn toggleFastForward(self: *RunState) void {
        self.fast_forward = !self.fast_forward;
    }
};

// Applies one key event to the bus. Returns false for control keys that
// the frontend must handle itself.
pub fn applyKey(bus: *Bus, key: Key, pressed: bool) bool {
    if (key == .pause or key == .reset or key == .fast_forward) return false;
    for (bindings) |binding| {
        if (binding.key == key) {
            switch (binding.action) {
                .button => bus.setButton(@enumFromInt(binding.bit), pressed),
                .direction => bus.setDirection(@enumFromInt(binding.bit), pressed),
            }
            return true;
        }
    }
    return false;
}

// DMG-inspired presentation palette. The frame stores 0xAARRGGBB values.
pub const palette = struct {
    pub const shell: u32 = 0xffd9d9b8;
    pub const bezel: u32 = 0xff3a3a2e;
    pub const screen_back: u32 = 0xff9ca89a;
    pub const paused_bar: u32 = 0xff101010;
};

const testing = std.testing;

fn testBus() !Bus {
    const allocator = testing.allocator;
    const rom = [_]u8{0} ** 0x8000;
    return try Bus.init(allocator, &rom);
}

test "bindings cover the eight joypad inputs" {
    var seen_buttons: u8 = 0;
    var seen_directions: u8 = 0;
    for (bindings) |binding| {
        switch (binding.action) {
            .button => seen_buttons |= @as(u8, 1) << binding.bit,
            .direction => seen_directions |= @as(u8, 1) << binding.bit,
        }
    }
    try testing.expectEqual(@as(u8, 0x0f), seen_buttons);
    try testing.expectEqual(@as(u8, 0x0f), seen_directions);
}

test "applying a key presses the right joypad column" {
    var bus = try testBus();
    defer bus.deinit();
    try testing.expect(applyKey(&bus, .a, true));
    try testing.expect(bus.joypad.isButtonPressed(Joypad.Button.a));
    try testing.expect(!bus.joypad.isDirectionPressed(Joypad.Direction.right));
    try testing.expect(applyKey(&bus, .up, true));
    try testing.expect(bus.joypad.isDirectionPressed(Joypad.Direction.up));
}

test "releasing a key restores the released state" {
    var bus = try testBus();
    defer bus.deinit();
    try testing.expect(applyKey(&bus, .b, true));
    try testing.expect(applyKey(&bus, .b, false));
    try testing.expect(!bus.joypad.isButtonPressed(Joypad.Button.b));
}

test "control keys are not forwarded to the joypad" {
    var bus = try testBus();
    defer bus.deinit();
    try testing.expect(!applyKey(&bus, .pause, true));
    try testing.expect(!applyKey(&bus, .reset, true));
    try testing.expect(!applyKey(&bus, .fast_forward, true));
    try testing.expectEqual(@as(u8, 0xcf), bus.read(0xff00));
}

test "window layout keeps the screen centered" {
    try testing.expectEqual(@as(usize, 512), window_width);
    try testing.expectEqual(@as(usize, 464), window_height);
    try testing.expectEqual(@as(usize, ppu.ScreenWidth * screen_scale), @as(usize, @intCast(screen_rect.width)));
    try testing.expectEqual(@as(usize, ppu.ScreenHeight * screen_scale), @as(usize, @intCast(screen_rect.height)));
}

test "run state toggles stay independent" {
    var state = RunState{};
    state.togglePause();
    try testing.expect(state.paused);
    state.togglePause();
    try testing.expect(!state.paused);
    state.toggleFastForward();
    try testing.expect(state.fast_forward);
    try testing.expect(state.running);
}
