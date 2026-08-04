const std = @import("std");

// Joypad key model for the frontend.
//
// The Game Boy joypad register is low-active. A pressed button reads 0
// and a released button reads 1. The windowed frontend converts SDL
// scancodes into `Key` values, then `apply` updates the button byte that
// the memory bus exposes at 0xff00.

pub const Key = enum {
    a,
    b,
    start,
    select,
    up,
    down,
    left,
    right,
};

pub const Button = struct {
    pub const right: u8 = 1 << 0;
    pub const left: u8 = 1 << 1;
    pub const up: u8 = 1 << 2;
    pub const down: u8 = 1 << 3;
    pub const a: u8 = 1 << 4;
    pub const b: u8 = 1 << 5;
    pub const select: u8 = 1 << 6;
    pub const start: u8 = 1 << 7;
};

pub fn mask(key: Key) u8 {
    return switch (key) {
        .a => Button.a,
        .b => Button.b,
        .start => Button.start,
        .select => Button.select,
        .up => Button.up,
        .down => Button.down,
        .left => Button.left,
        .right => Button.right,
    };
}

// Updates the button byte for one key. A press clears the low-active bit.
// A release sets the bit back to 1.
pub fn apply(key: Key, pressed: bool, buttons: *u8) void {
    const bit = mask(key);
    if (pressed) {
        buttons.* &= ~bit;
    } else {
        buttons.* |= bit;
    }
}

test "each key maps to its own bit" {
    try std.testing.expectEqual(@as(u8, 0x01), mask(.right));
    try std.testing.expectEqual(@as(u8, 0x02), mask(.left));
    try std.testing.expectEqual(@as(u8, 0x04), mask(.up));
    try std.testing.expectEqual(@as(u8, 0x08), mask(.down));
    try std.testing.expectEqual(@as(u8, 0x10), mask(.a));
    try std.testing.expectEqual(@as(u8, 0x20), mask(.b));
    try std.testing.expectEqual(@as(u8, 0x40), mask(.select));
    try std.testing.expectEqual(@as(u8, 0x80), mask(.start));
}

test "a press clears the button bit" {
    var buttons: u8 = 0xff;
    apply(.a, true, &buttons);
    try std.testing.expectEqual(@as(u8, 0xef), buttons);
    apply(.right, true, &buttons);
    try std.testing.expectEqual(@as(u8, 0xee), buttons);
}

test "a release restores the button bit" {
    var buttons: u8 = 0x00;
    apply(.start, false, &buttons);
    try std.testing.expectEqual(@as(u8, 0x80), buttons);
    apply(.down, false, &buttons);
    try std.testing.expectEqual(@as(u8, 0x88), buttons);
}

test "keys do not disturb each other" {
    var buttons: u8 = 0xff;
    apply(.b, true, &buttons);
    apply(.select, true, &buttons);
    apply(.up, false, &buttons);
    try std.testing.expectEqual(@as(u8, 0x9b), buttons);
}
