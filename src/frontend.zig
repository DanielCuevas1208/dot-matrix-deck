// Frontend presentation logic that does not depend on SDL2.
//
// The windowed frontend maps keyboard keys to the joypad, lays out the
// window, and shades the LCD palette. Keeping this logic free of SDL2
// lets the unit tests run in headless builds.

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const Cpu = @import("cpu.zig").Cpu;
const Joypad = @import("joypad.zig").Joypad;
const disasm = @import("disasm.zig");
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
    debugger_overlay,
    step,
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
    debugger_overlay: bool = false,

    pub fn togglePause(self: *RunState) void {
        self.paused = !self.paused;
    }

    pub fn toggleFastForward(self: *RunState) void {
        self.fast_forward = !self.fast_forward;
    }

    pub fn toggleDebuggerOverlay(self: *RunState) void {
        self.debugger_overlay = !self.debugger_overlay;
    }
};

// Applies one key event to the bus. Returns false for control keys that
// the frontend must handle itself.
pub fn applyKey(bus: *Bus, key: Key, pressed: bool) bool {
    if (key == .pause or key == .reset or key == .fast_forward or key == .debugger_overlay or key == .step) return false;
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
        .{ .key = .debugger_overlay, .scancode_name = "d" },
        .{ .key = .step, .scancode_name = "s" },
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
    pub const overlay_back: u32 = 0xee161e16;
    pub const overlay_border: u32 = 0xff485840;
    pub const overlay_text: u32 = 0xffe8f0d8;
    pub const overlay_muted: u32 = 0xff889880;
    pub const overlay_highlight: u32 = 0xfff8d040;
    pub const overlay_accent: u32 = 0xffa0d878;
};

// 5x7 bitmap font for ASCII 32 (' ') through 95 ('_').
const font_5x7 = [64][7]u8{
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 32 ' '
    .{ 0x04, 0x04, 0x04, 0x04, 0x00, 0x00, 0x04 }, // 33 '!'
    .{ 0x0A, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x00 }, // 34 '"'
    .{ 0x0A, 0x0A, 0x1F, 0x0A, 0x1F, 0x0A, 0x0A }, // 35 '#'
    .{ 0x04, 0x0F, 0x14, 0x0E, 0x05, 0x1E, 0x04 }, // 36 '$'
    .{ 0x19, 0x19, 0x02, 0x04, 0x08, 0x13, 0x13 }, // 37 '%'
    .{ 0x0C, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0D }, // 38 '&'
    .{ 0x04, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00 }, // 39 '\''
    .{ 0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02 }, // 40 '('
    .{ 0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08 }, // 41 ')'
    .{ 0x00, 0x04, 0x15, 0x0E, 0x15, 0x04, 0x00 }, // 42 '*'
    .{ 0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00 }, // 43 '+'
    .{ 0x00, 0x00, 0x00, 0x00, 0x04, 0x04, 0x08 }, // 44 ','
    .{ 0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00 }, // 45 '-'
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x06 }, // 46 '.'
    .{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x00, 0x00 }, // 47 '/'
    .{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E }, // 48 '0'
    .{ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E }, // 49 '1'
    .{ 0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F }, // 50 '2'
    .{ 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E }, // 51 '3'
    .{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 }, // 52 '4'
    .{ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E }, // 53 '5'
    .{ 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E }, // 54 '6'
    .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 }, // 55 '7'
    .{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E }, // 56 '8'
    .{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C }, // 57 '9'
    .{ 0x00, 0x04, 0x00, 0x00, 0x04, 0x00, 0x00 }, // 58 ':'
    .{ 0x00, 0x04, 0x00, 0x00, 0x04, 0x04, 0x08 }, // 59 ';'
    .{ 0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02 }, // 60 '<'
    .{ 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00, 0x00 }, // 61 '='
    .{ 0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08 }, // 62 '>'
    .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04 }, // 63 '?'
    .{ 0x0E, 0x11, 0x01, 0x0D, 0x15, 0x15, 0x0E }, // 64 '@'
    .{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 }, // 65 'A'
    .{ 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E }, // 66 'B'
    .{ 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E }, // 67 'C'
    .{ 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E }, // 68 'D'
    .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F }, // 69 'E'
    .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 }, // 70 'F'
    .{ 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F }, // 71 'G'
    .{ 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 }, // 72 'H'
    .{ 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E }, // 73 'I'
    .{ 0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C }, // 74 'J'
    .{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 }, // 75 'K'
    .{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F }, // 76 'L'
    .{ 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 }, // 77 'M'
    .{ 0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11 }, // 78 'N'
    .{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E }, // 79 'O'
    .{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 }, // 80 'P'
    .{ 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D }, // 81 'Q'
    .{ 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 }, // 82 'R'
    .{ 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E }, // 83 'S'
    .{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 }, // 84 'T'
    .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E }, // 85 'U'
    .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 }, // 86 'V'
    .{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A }, // 87 'W'
    .{ 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11 }, // 88 'X'
    .{ 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 }, // 89 'Y'
    .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F }, // 90 'Z'
    .{ 0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E }, // 91 '['
    .{ 0x10, 0x08, 0x04, 0x02, 0x01, 0x00, 0x00 }, // 92 '\'
    .{ 0x0E, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0E }, // 93 ']'
    .{ 0x04, 0x0A, 0x11, 0x00, 0x00, 0x00, 0x00 }, // 94 '^'
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F }, // 95 '_'
};

pub fn blendPixel(base: u32, overlay: u32) u32 {
    const alpha: u32 = (overlay >> 24) & 0xff;
    if (alpha == 0xff) return overlay;
    if (alpha == 0) return base;
    const inv: u32 = 255 - alpha;
    const r = (((base >> 16) & 0xff) * inv + ((overlay >> 16) & 0xff) * alpha) / 255;
    const g = (((base >> 8) & 0xff) * inv + ((overlay >> 8) & 0xff) * alpha) / 255;
    const b = ((base & 0xff) * inv + (overlay & 0xff) * alpha) / 255;
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

pub fn drawChar(target: []u32, stride: usize, x: usize, y: usize, raw_char: u8, text_color: u32) void {
    const c = if (raw_char >= 'a' and raw_char <= 'z') raw_char - ('a' - 'A') else raw_char;
    if (c < 32 or c > 95) return;
    const glyph = font_5x7[c - 32];
    for (glyph, 0..) |row_bits, row| {
        const py = y + row;
        if (py >= ppu.ScreenHeight) break;
        for (0..5) |col| {
            const px = x + col;
            if (px >= ppu.ScreenWidth) break;
            const bit = @as(u8, 0x10) >> @intCast(col);
            if ((row_bits & bit) != 0) {
                target[py * stride + px] = blendPixel(target[py * stride + px], text_color);
            }
        }
    }
}

pub fn drawText(target: []u32, stride: usize, x: usize, y: usize, text: []const u8, text_color: u32) void {
    var cur_x = x;
    for (text) |ch| {
        drawChar(target, stride, cur_x, y, ch, text_color);
        cur_x += 6;
        if (cur_x + 5 > ppu.ScreenWidth) break;
    }
}

pub fn renderDebuggerOverlay(
    target: []u32,
    cpu: *const Cpu,
    bus: *Bus,
    breakpoints: []const u16,
    paused: bool,
    breakpoint_hit: ?u16,
) void {
    const stride = ppu.ScreenWidth;
    const box_x: usize = 2;
    const box_y: usize = 84;
    const box_w: usize = 156;
    const box_h: usize = 58;

    // Semi-transparent backdrop
    var y: usize = box_y;
    while (y < box_y + box_h and y < ppu.ScreenHeight) : (y += 1) {
        var x: usize = box_x;
        while (x < box_x + box_w and x < ppu.ScreenWidth) : (x += 1) {
            target[y * stride + x] = blendPixel(target[y * stride + x], palette.overlay_back);
        }
    }

    // Border
    var bx: usize = box_x;
    while (bx < box_x + box_w and bx < ppu.ScreenWidth) : (bx += 1) {
        target[box_y * stride + bx] = palette.overlay_border;
        target[(box_y + box_h - 1) * stride + bx] = palette.overlay_border;
    }
    var by: usize = box_y;
    while (by < box_y + box_h and by < ppu.ScreenHeight) : (by += 1) {
        target[by * stride + box_x] = palette.overlay_border;
        target[by * stride + (box_x + box_w - 1)] = palette.overlay_border;
    }

    // Line 0: Header and Breakpoint status
    if (breakpoint_hit) |hit_addr| {
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "BP HIT ${X:0>4}", .{hit_addr}) catch "BP HIT";
        drawText(target, stride, box_x + 4, box_y + 2, msg, palette.overlay_highlight);
    } else if (paused) {
        drawText(target, stride, box_x + 4, box_y + 2, "PAUSED", palette.overlay_highlight);
    } else {
        drawText(target, stride, box_x + 4, box_y + 2, "RUNNING", palette.overlay_muted);
    }

    if (breakpoints.len > 0) {
        var bp_buf: [32]u8 = undefined;
        const bp_msg = std.fmt.bufPrint(&bp_buf, "BP:${X:0>4}", .{breakpoints[0]}) catch "";
        drawText(target, stride, box_x + 94, box_y + 2, bp_msg, palette.overlay_accent);
    }

    // Line 1: PC & SP
    {
        var line_buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "PC:{X:0>4}  SP:{X:0>4}", .{ cpu.pc, cpu.sp }) catch "";
        drawText(target, stride, box_x + 4, box_y + 11, line, palette.overlay_text);
    }

    // Line 2: AF & Flags & BC
    {
        const flags = [4]u8{
            if (cpu.flagZ()) 'Z' else '-',
            if (cpu.flagN()) 'N' else '-',
            if (cpu.flagH()) 'H' else '-',
            if (cpu.flagC()) 'C' else '-',
        };
        var line_buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "AF:{X:0>4} [{s}] BC:{X:0>4}", .{ cpu.af(), flags, cpu.bc() }) catch "";
        drawText(target, stride, box_x + 4, box_y + 20, line, palette.overlay_text);
    }

    // Line 3: DE & HL
    {
        var line_buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "DE:{X:0>4}  HL:{X:0>4}", .{ cpu.de(), cpu.hl() }) catch "";
        drawText(target, stride, box_x + 4, box_y + 29, line, palette.overlay_text);
    }

    // Line 4: Current Instruction
    {
        const inst = disasm.formatAt(bus, cpu.pc);
        const mnemonic = std.mem.trimEnd(u8, &inst.text, "\x00");
        var line_buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{X:0>4}: {s}", .{ cpu.pc, mnemonic }) catch "";
        drawText(target, stride, box_x + 4, box_y + 38, line, palette.overlay_accent);
    }

    // Line 5: Control Hints
    drawText(target, stride, box_x + 4, box_y + 48, "[P]RESUME [S]STEP [D]HIDE", palette.overlay_muted);
}

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
    try testing.expect(!applyKey(&bus, .debugger_overlay, true));
    try testing.expect(!applyKey(&bus, .step, true));
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
    state.toggleDebuggerOverlay();
    try testing.expect(state.debugger_overlay);
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

test "blendPixel blends colors with alpha" {
    try testing.expectEqual(@as(u32, 0xff123456), blendPixel(0xff000000, 0xff123456));
    try testing.expectEqual(@as(u32, 0xff123456), blendPixel(0xff123456, 0x00ffffff));
    const blended = blendPixel(0xff000000, 0x80ffffff);
    // About half brightness for each RGB channel
    const r = (blended >> 16) & 0xff;
    try testing.expect(r >= 0x7e and r <= 0x82);
}

test "drawText writes character glyphs into buffer" {
    var buffer = [_]u32{0xff000000} ** (ppu.ScreenWidth * ppu.ScreenHeight);
    drawText(&buffer, ppu.ScreenWidth, 10, 10, "PC:0100", 0xffffffff);
    var lit: usize = 0;
    for (buffer) |pixel| {
        if (pixel == 0xffffffff) lit += 1;
    }
    try testing.expect(lit > 30);
}

test "renderDebuggerOverlay renders registers and border into frame" {
    var buffer = [_]u32{0xffffffff} ** (ppu.ScreenWidth * ppu.ScreenHeight);
    const cpu = Cpu{
        .pc = 0x0150,
        .sp = 0xfffe,
        .a = 0x42,
        .b = 0x10,
        .c = 0x20,
    };
    var bus = try testBus();
    defer bus.deinit();
    const breakpoints = [_]u16{0x0150};

    renderDebuggerOverlay(&buffer, &cpu, &bus, &breakpoints, true, 0x0150);

    // Border pixel check at (2, 84)
    try testing.expectEqual(palette.overlay_border, buffer[84 * ppu.ScreenWidth + 2]);
    // Outside box pixel remains unaffected at (0, 0)
    try testing.expectEqual(@as(u32, 0xffffffff), buffer[0]);
    // Inner box pixels are modified from white
    var modified: usize = 0;
    for (buffer[84 * ppu.ScreenWidth .. 142 * ppu.ScreenWidth]) |pixel| {
        if (pixel != 0xffffffff) modified += 1;
    }
    try testing.expect(modified > 1000);
}
