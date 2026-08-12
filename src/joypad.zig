// The Game Boy joypad device.
//
// The register at 0xff00 reports key state through the low nibble.
// Bit 4 and bit 5 of the register select which column is active.
// A zero bit selects a column. A pressed key drives its bit low.
// When both columns are selected, the read is the AND of the two.

const std = @import("std");

pub const Joypad = struct {
    const dpad_select_bit: u8 = 0x10;
    const button_select_bit: u8 = 0x20;
    const select_mask: u8 = dpad_select_bit | button_select_bit;
    const register_high_bits: u8 = 0xc0;
    const released_nibble: u8 = 0x0f;

    buttons: u8 = 0x0f,
    dpad: u8 = 0x0f,
    select: u8 = select_mask,

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

    // Reading FF00. The stored select bits come back in bits 4 and 5.
    // A cleared bit 4 activates the D-pad; a cleared bit 5 activates the
    // buttons. Unselected columns report 1 (released).
    pub fn read(self: *const Joypad) u8 {
        var value: u8 = released_nibble;
        if (self.columnSelected(dpad_select_bit)) value &= self.dpad;
        if (self.columnSelected(button_select_bit)) value &= self.buttons;
        return register_high_bits | (self.select & select_mask) | value;
    }

    // Writing FF00. Only the two select bits are stored.
    pub fn write(self: *Joypad, value: u8) void {
        self.select = value & select_mask;
    }

    fn columnSelected(self: *const Joypad, bit: u8) bool {
        // The hardware uses active-low column selection.
        return (self.select & bit) == 0;
    }
};

const testing = std.testing;

test "default state reads as all released" {
    const joypad = Joypad{};
    // No column is selected, so the whole register reads released.
    try testing.expectEqual(@as(u8, 0xff), joypad.read());
}

test "reading returns the stored select bits" {
    var joypad = Joypad{};
    joypad.write(0x20);
    try testing.expectEqual(@as(u8, 0x20), joypad.read() & 0x30);
    try testing.expectEqual(@as(u8, 0xef), joypad.read());
    joypad.write(0x10);
    try testing.expectEqual(@as(u8, 0x10), joypad.read() & 0x30);
    try testing.expectEqual(@as(u8, 0xdf), joypad.read());
}

test "writes ignore unrelated register bits" {
    var joypad = Joypad{};
    joypad.write(0x8f);
    try testing.expectEqual(@as(u8, 0xcf), joypad.read());
}

test "buttons column reflects pressed keys" {
    var joypad = Joypad{};
    joypad.write(0x10); // bit 5 low selects the buttons column.
    joypad.setButton(.a, true);
    joypad.setButton(.start, true);
    const value = joypad.read();
    // a (bit 0) and start (bit 3) are low; B and select stay high.
    try testing.expectEqual(@as(u8, 0x06), value & 0x0f);
}

test "dpad column reflects pressed directions" {
    var joypad = Joypad{};
    joypad.write(0x20); // bit 4 low selects the D-pad column.
    joypad.setDirection(.up, true);
    joypad.setDirection(.down, true);
    const value = joypad.read();
    // up (bit 2) and down (bit 3) are low; right and left stay high.
    try testing.expectEqual(@as(u8, 0x03), value & 0x0f);
}

test "unselected column reads released" {
    var joypad = Joypad{};
    joypad.write(0x20); // only the D-pad column is selected.
    joypad.setButton(.a, true);
    // The button press hides in the unselected buttons column.
    try testing.expectEqual(@as(u8, 0x0f), joypad.read() & 0x0f);
}

test "both columns selected reads the AND of both" {
    var joypad = Joypad{};
    joypad.write(0x00); // both columns are selected.
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
    try testing.expectEqual(@as(u8, 0x0f), joypad.read() & 0x0f);
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
