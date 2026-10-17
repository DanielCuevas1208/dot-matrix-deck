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

// A physical key bound to a logical key. The physical key is an SDL
// scancode name such as "z", "return", or "left shift". Keeping SDL out
// of this file lets the parser and defaults run in headless tests.
pub const KeyBinding = struct {
    key: Key,
    scancode_name: []const u8,
};

// The built-in bindings. A config file overrides only named logical keys.
pub fn defaultKeyMap() []const KeyBinding {
    return &[_]KeyBinding{
        .{ .key = .a, .scancode_name = "z" },
        .{ .key = .b, .scancode_name = "x" },
        .{ .key = .select, .scancode_name = "left shift" },
        .{ .key = .select, .scancode_name = "right shift" },
        .{ .key = .start, .scancode_name = "return" },
        .{ .key = .right, .scancode_name = "right" },
        .{ .key = .left, .scancode_name = "left" },
        .{ .key = .up, .scancode_name = "up" },
        .{ .key = .down, .scancode_name = "down" },
        .{ .key = .pause, .scancode_name = "p" },
        .{ .key = .reset, .scancode_name = "r" },
        .{ .key = .fast_forward, .scancode_name = "f" },
    };
}

// Returns the logical key bound to a physical key, or null.
pub fn keyForScancodeName(map: []const KeyBinding, name: []const u8) ?Key {
    for (map) |binding| {
        if (std.mem.eql(u8, binding.scancode_name, name)) return binding.key;
    }
    return null;
}

pub const KeyConfigError = error{
    ExpectedEquals,
    UnknownKey,
    DuplicateKey,
    DuplicateScancode,
    EmptyBinding,
};

// Parses a key config file into bindings. Each line maps a logical key to
// one or more comma-separated SDL scancode names. Blank lines and lines
// that start with '#' are ignored. The returned bindings point into the
// input text, so the caller must keep the text alive.
pub fn parseKeyMap(allocator: std.mem.Allocator, text: []const u8) ![]KeyBinding {
    var entries: std.ArrayListUnmanaged(KeyBinding) = .empty;
    errdefer entries.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.ExpectedEquals;
        const key = std.meta.stringToEnum(Key, std.mem.trim(u8, line[0..equals], " \t")) orelse
            return error.UnknownKey;
        for (entries.items) |existing| {
            if (existing.key == key) return error.DuplicateKey;
        }
        var assigned = false;
        var names = std.mem.splitScalar(u8, line[equals + 1 ..], ',');
        while (names.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t\r");
            if (name.len == 0) continue;
            for (entries.items) |existing| {
                if (std.mem.eql(u8, existing.scancode_name, name)) return error.DuplicateScancode;
            }
            try entries.append(allocator, .{ .key = key, .scancode_name = name });
            assigned = true;
        }
        if (!assigned) return error.EmptyBinding;
    }
    return entries.toOwnedSlice(allocator);
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
    const rom = [_]u8{0} ** 0x8000;
    return try Bus.init(testing.allocator, &rom);
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
    try testing.expectEqual(@as(u8, 0xff), bus.read(0xff00));
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

test "default key map covers every logical key" {
    var seen = [_]bool{false} ** @as(usize, @typeInfo(Key).@"enum".fields.len);
    for (defaultKeyMap()) |binding| {
        seen[@intFromEnum(binding.key)] = true;
    }
    for (seen) |present| try testing.expect(present);
}

test "default key map keeps the arrow and shift defaults" {
    const map = defaultKeyMap();
    try testing.expectEqual(@as(Key, .a), keyForScancodeName(map, "z").?);
    try testing.expectEqual(@as(Key, .select), keyForScancodeName(map, "left shift").?);
    try testing.expectEqual(@as(Key, .select), keyForScancodeName(map, "right shift").?);
    try testing.expectEqual(@as(Key, .up), keyForScancodeName(map, "up").?);
    try testing.expectEqual(@as(Key, .reset), keyForScancodeName(map, "r").?);
    try testing.expectEqual(@as(?Key, null), keyForScancodeName(map, "k"));
}

test "key config parses comments, blanks, and key lists" {
    const text =
        \\# custom bindings
        \\a = k
        \\select = left shift, right shift
        \\start = space
        \\right = w
        \\
        \\left = a
    ;
    const parsed = try parseKeyMap(testing.allocator, text);
    defer testing.allocator.free(parsed);
    try testing.expectEqual(@as(usize, 6), parsed.len);
    try testing.expectEqual(@as(Key, .a), keyForScancodeName(parsed, "k").?);
    try testing.expectEqual(@as(Key, .select), keyForScancodeName(parsed, "right shift").?);
    try testing.expectEqual(@as(Key, .start), keyForScancodeName(parsed, "space").?);
    try testing.expectEqual(@as(Key, .right), keyForScancodeName(parsed, "w").?);
    try testing.expectEqual(@as(Key, .left), keyForScancodeName(parsed, "a").?);
    try testing.expectEqual(@as(?Key, null), keyForScancodeName(parsed, "z"));
}

test "remapped key config drives the joypad" {
    const text = "b = k\n";
    const parsed = try parseKeyMap(testing.allocator, text);
    defer testing.allocator.free(parsed);
    var bus = try testBus();
    defer bus.deinit();
    const key = keyForScancodeName(parsed, "k").?;
    try testing.expect(applyKey(&bus, key, true));
    try testing.expect(bus.joypad.isButtonPressed(Joypad.Button.b));
}

test "key config rejects malformed lines" {
    try testing.expectError(error.ExpectedEquals, parseKeyMap(testing.allocator, "a z\n"));
    try testing.expectError(error.UnknownKey, parseKeyMap(testing.allocator, "turbo = z\n"));
    try testing.expectError(error.DuplicateKey, parseKeyMap(testing.allocator, "a = z\na = x\n"));
    try testing.expectError(error.DuplicateScancode, parseKeyMap(testing.allocator, "a = z\nb = z\n"));
    try testing.expectError(error.EmptyBinding, parseKeyMap(testing.allocator, "a =\n"));
}

test "key config rejects an empty file without error" {
    const parsed = try parseKeyMap(testing.allocator, "# nothing\n\n");
    defer testing.allocator.free(parsed);
    try testing.expectEqual(@as(usize, 0), parsed.len);
}

// Combines partial overrides with the built-in map. The returned bindings
// point into the override text, so the caller must keep that text alive.
pub fn mergeKeyMap(allocator: std.mem.Allocator, overrides: []const KeyBinding) ![]KeyBinding {
    var merged: std.ArrayListUnmanaged(KeyBinding) = .empty;
    errdefer merged.deinit(allocator);

    for (defaultKeyMap()) |binding| {
        var overridden = false;
        for (overrides) |override| {
            if (override.key == binding.key) {
                overridden = true;
                break;
            }
        }
        if (!overridden) try merged.append(allocator, binding);
    }
    for (overrides) |override| try merged.append(allocator, override);

    for (merged.items, 0..) |binding, index| {
        for (merged.items[index + 1 ..]) |other| {
            if (std.mem.eql(u8, binding.scancode_name, other.scancode_name)) {
                return error.DuplicateScancode;
            }
        }
    }
    return merged.toOwnedSlice(allocator);
}

test "partial key config keeps unspecified defaults" {
    const overrides = try parseKeyMap(testing.allocator, "a = k\nselect = space\n");
    defer testing.allocator.free(overrides);
    const merged = try mergeKeyMap(testing.allocator, overrides);
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(Key, .a), keyForScancodeName(merged, "k").?);
    try testing.expectEqual(@as(?Key, null), keyForScancodeName(merged, "z"));
    try testing.expectEqual(@as(Key, .b), keyForScancodeName(merged, "x").?);
    try testing.expectEqual(@as(Key, .select), keyForScancodeName(merged, "space").?);
    try testing.expectEqual(@as(?Key, null), keyForScancodeName(merged, "left shift"));
    try testing.expectEqual(@as(Key, .start), keyForScancodeName(merged, "return").?);
}

test "merged key config rejects a physical key collision" {
    const overrides = try parseKeyMap(testing.allocator, "a = x\n");
    defer testing.allocator.free(overrides);
    try testing.expectError(error.DuplicateScancode, mergeKeyMap(testing.allocator, overrides));
}
