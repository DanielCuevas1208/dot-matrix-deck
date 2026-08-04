// The Game Boy joypad device.
//
// The register at 0xff00 reports key state through the low nibble.
// Bit 4 and bit 5 of the register select which column is active.
// A zero bit selects a column. A pressed key drives its bit low.
// When both columns are selected, the read is the AND of the two.

const std = @import("std");

pub const Joypad = struct {
    buttons: u8 = 0x0f,
    dpad: u8 = 0x0f,
    select: u8 = 0x30,

    // Low-nibble bit positions, active low.
    pub const Button = enum(u3) { a = 0, b = 1, select = 2, start = 3 };

    pub const Direction = enum(u3) { right = 0, left = 1, up = 2, down = 3 };

    pub fn setButton(self: *Joypad, bit: Button, pressed: bool) void {
        const mask: u8 = @as(u8, 1) << @intFromEnum(bit);
        self.buttons = if (pressed) self.buttons & ~mask else self.buttons | mask;
    }

    pub fn setDirection(self: *Joypad, bit: Direction, pressed: bool) void {
        const mask: u8 = @as(u8, 1) << @intFromEnum(bit);
        self.dpad = if (pressed) self.dpad & ~mask else self.dpad | mask;
    }

    pub fn isButtonPressed(self: *const Joypad, bit: Button) bool {
        return (self.buttons & (@as(u8, 1) << @intFromEnum(bit))) == 0;
    }

    pub fn isDirectionPressed(self: *const Joypad, bit: Direction) bool {
        return (self.dpad & (@as(u8, 1) << @intFromEnum(bit))) == 0;
    }

    // Reading FF00. Unselected columns report 1 (released).
    // A set bit 4 activates the D-pad; a set bit 5 activates the buttons.
    pub fn read(self: *const Joypad) u8 {
        var value: u8 = 0x0f;
        if ((self.select & 0x10) != 0) value &= self.dpad;
        if ((self.select & 0x20) != 0) value &= self.buttons;
        return 0xc0 | value;
    }

    // Writing FF00. Only the two select bits are stored.
    pub fn write(self: *Joypad, value: u8) void {
        self.select = value & 0x30;
    }
};

const testing = std.testing;

test "default state reads as all released" {
    const joypad = Joypad{};
    try testing.expectEqual(@as(u8, 0xcf), joypad.read());
}

test "buttons column reflects pressed keys" {
    var joypad = Joypad{};
    joypad.write(0x20);
    joypad.setButton(.a, true);
    joypad.setButton(.start, true);
    const value = joypad.read();
    // a (bit 0) and start (bit 3) are low; B and select stay high.
    try testing.expectEqual(@as(u8, 0x06), value & 0x0f);
}

test "dpad column reflects pressed directions" {
    var joypad = Joypad{};
    joypad.write(0x10);
    joypad.setDirection(.up, true);
    joypad.setDirection(.down, true);
    const value = joypad.read();
    // up (bit 2) and down (bit 3) are low; right and left stay high.
    try testing.expectEqual(@as(u8, 0x03), value & 0x0f);
}

test "unselected column reads released" {
    var joypad = Joypad{};
    joypad.setButton(.a, true);
    joypad.setDirection(.right, true);
    joypad.write(0x00);
    try testing.expectEqual(@as(u8, 0xcf), joypad.read());
}

test "both columns selected reads the AND of both" {
    var joypad = Joypad{};
    joypad.write(0x30);
    joypad.setButton(.a, true);
    joypad.setDirection(.right, true);
    // bit 0 is driven low by both columns.
    try testing.expectEqual(@as(u8, 0x0e), joypad.read() & 0x0f);
}

test "release restores the released state" {
    var joypad = Joypad{};
    joypad.write(0x10);
    joypad.setButton(.b, true);
    joypad.setButton(.b, false);
    try testing.expectEqual(@as(u8, 0xcf), joypad.read());
}

test "query helpers reflect active low storage" {
    var joypad = Joypad{};
    joypad.setButton(.a, true);
    joypad.setDirection(.left, true);
    try testing.expect(joypad.isButtonPressed(.a));
    try testing.expect(!joypad.isButtonPressed(.b));
    try testing.expect(joypad.isDirectionPressed(.left));
    try testing.expect(!joypad.isDirectionPressed(.up));
}
