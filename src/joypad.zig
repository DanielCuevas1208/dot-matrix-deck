//! Joypad handling for the dot-matrix-deck frontend.
//!
//! The Game Boy joypad register (FF00) reports two button sets on one
//! low nibble. Bit 4 selects the direction buttons. Bit 5 selects the
//! action buttons. The frontend writes the union of pressed buttons and
//! the bus masks them per the active select line.

const std = @import("std");

pub const buttons = struct {
    pub const right: u8 = 0x01; // also A
    pub const left: u8 = 0x02; // also B
    pub const up: u8 = 0x04; // also Select
    pub const down: u8 = 0x08; // also Start

    pub const action_a: u8 = 0x01;
    pub const action_b: u8 = 0x02;
    pub const action_select: u8 = 0x04;
    pub const action_start: u8 = 0x08;
};

// Combines a bitmask of held buttons into the joypad register. A set
// bit means the button is held; the register stores the inverse because
// a low bit reports a press. Bits 5-4 (the select lines) are left
// untouched so the caller can preserve what software wrote to FF00.
pub fn registerValue(held: u8) u8 {
    return 0xc0 | ((~held) & 0x0f);
}

// Masks the low nibble by the select lines. Bit 4 low selects the
// direction buttons; bit 5 low selects the action buttons. The result
// is what software sees when it reads FF00.
pub fn readRegister(register: u8) u8 {
    const direction = if ((register & 0x10) == 0) register & 0x0f else 0x0f;
    const action = if ((register & 0x20) == 0) register & 0x0f else 0x0f;
    return 0xc0 | (register & 0x30) | (direction & action);
}

test "register stores the inverse of held buttons" {
    try std.testing.expectEqual(@as(u8, 0xce), registerValue(buttons.right));
    try std.testing.expectEqual(@as(u8, 0xcf), registerValue(0));
    try std.testing.expectEqual(@as(u8, 0xc0), registerValue(0x0f));
}

test "read masks by the active select line" {
    const held = buttons.action_a | buttons.right; // 0x01
    // Software selects both lines and the right button is held.
    const both_selected = registerValue(held);
    try std.testing.expectEqual(@as(u8, 0xce), readRegister(both_selected));

    // Software selects only the direction line (FF00 written with 0x20).
    const direction_selected = (0x20 & 0x30) | registerValue(held);
    try std.testing.expectEqual(@as(u8, 0xee), readRegister(direction_selected));

    // Software selects only the action line (FF00 written with 0x10).
    const action_selected = (0x10 & 0x30) | registerValue(held);
    try std.testing.expectEqual(@as(u8, 0xde), readRegister(action_selected));
}
