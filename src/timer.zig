// The Game Boy timer.
//
// DIV is the top byte of a 16-bit counter that runs at the CPU clock
// (4,194,304 Hz). TIMA increments on the falling edge of a bit selected
// by TAC, with the increment delayed by 4 T-cycles. Overflow exposes zero
// for four T-cycles before it reloads TMA and raises IF bit 2.

pub const Timer = struct {
    divider_counter: u16 = 0,
    div: u8 = 0,
    tima: u8 = 0,
    tma: u8 = 0,
    tac: u8 = 0,
    tima_stage: u8 = 0,
    reload_stage: u8 = 0,

    const Frequencies = struct {
        const bit_for_clock = [_]u4{ 9, 3, 5, 7 };
    };

    pub fn tick(self: *Timer, cycles: u16, iflag: *u8) void {
        var remaining = cycles;
        while (remaining != 0) : (remaining -= 1) {
            self.advanceReload(iflag);

            const previous = self.divider_counter;
            self.divider_counter +%= 1;
            const current = self.divider_counter;
            self.div = @intCast(current >> 8);

            if (self.timerSignal(previous) and !self.timerSignal(current)) self.scheduleIncrement();

            if (self.tima_stage != 0) {
                self.tima_stage -= 1;
                if (self.tima_stage == 0) self.incrementTima();
            }
        }
    }

    fn incrementTima(self: *Timer) void {
        if (self.tima == 0xff) {
            self.tima = 0;
            self.reload_stage = 4;
        } else {
            self.tima +%= 1;
        }
    }

    fn advanceReload(self: *Timer, iflag: *u8) void {
        if (self.reload_stage == 0) return;
        self.reload_stage -= 1;
        if (self.reload_stage == 0) {
            self.tima = self.tma;
            iflag.* |= 0x04;
        }
    }

    fn timerSignal(self: *const Timer, divider: u16) bool {
        if ((self.tac & 0x04) == 0) return false;
        const bit = Frequencies.bit_for_clock[self.tac & 0x03];
        return ((divider >> bit) & 1) != 0;
    }

    fn scheduleIncrement(self: *Timer) void {
        if (self.tima_stage == 0 and self.reload_stage == 0) self.tima_stage = 4;
    }

    pub fn read(self: *const Timer, address: u16) u8 {
        return switch (address) {
            0xff04 => self.div,
            0xff05 => self.tima,
            0xff06 => self.tma,
            0xff07 => self.tac | 0xf8,
            else => 0xff,
        };
    }

    pub fn write(self: *Timer, address: u16, value: u8) void {
        switch (address) {
            0xff04 => {
                const was_high = self.timerSignal(self.divider_counter);
                self.div = 0;
                self.divider_counter = 0;
                if (was_high) self.scheduleIncrement();
            },
            0xff05 => {
                self.tima = value;
                self.tima_stage = 0;
                self.reload_stage = 0;
            },
            0xff06 => self.tma = value,
            0xff07 => {
                const was_high = self.timerSignal(self.divider_counter);
                self.tac = value & 0x07;
                if (was_high and !self.timerSignal(self.divider_counter)) self.scheduleIncrement();
            },
            else => {},
        }
    }
};

const std = @import("std");

test "DIV advances at 16384 Hz" {
    var timer = Timer{};
    var iflag: u8 = 0;
    timer.tick(256, &iflag);
    try std.testing.expectEqual(@as(u8, 1), timer.div);
    timer.tick(256, &iflag);
    try std.testing.expectEqual(@as(u8, 2), timer.div);
}

test "writing DIV resets the divider" {
    var timer = Timer{};
    var iflag: u8 = 0;
    timer.tick(700, &iflag);
    timer.write(0xff04, 0);
    try std.testing.expectEqual(@as(u8, 0), timer.div);
}

test "TIMA ticks at 262144 Hz" {
    var timer = Timer{};
    var iflag: u8 = 0;
    timer.write(0xff07, 0x05);
    timer.tick(20, &iflag);
    try std.testing.expectEqual(@as(u8, 1), timer.tima);
    timer.tick(16, &iflag);
    try std.testing.expectEqual(@as(u8, 2), timer.tima);
}

test "TIMA overflow reloads TMA and raises the interrupt" {
    var timer = Timer{};
    var iflag: u8 = 0;
    timer.write(0xff07, 0x05);
    timer.write(0xff06, 0x42);
    timer.write(0xff05, 0xfe);
    timer.tick(20, &iflag);
    try std.testing.expectEqual(@as(u8, 0xff), timer.tima);
    try std.testing.expectEqual(@as(u8, 0), iflag & 0x04);
    timer.tick(16, &iflag);
    try std.testing.expectEqual(@as(u8, 0x00), timer.tima);
    try std.testing.expectEqual(@as(u8, 0), iflag & 0x04);
    timer.tick(3, &iflag);
    try std.testing.expectEqual(@as(u8, 0x42), timer.tima);
    try std.testing.expectEqual(@as(u8, 0x04), iflag & 0x04);
}

test "timer disabled at TAC select 0 does not tick" {
    var timer = Timer{};
    var iflag: u8 = 0;
    timer.write(0xff07, 0x00);
    timer.tick(2048, &iflag);
    try std.testing.expectEqual(@as(u8, 0), timer.tima);
    try std.testing.expectEqual(@as(u8, 0), iflag & 0x04);
}

test "resetting DIV clocks TIMA on a falling timer edge" {
    var timer = Timer{};
    var iflag: u8 = 0;
    timer.write(0xff07, 0x05);
    timer.tick(8, &iflag);
    timer.write(0xff04, 0);
    timer.tick(4, &iflag);
    try std.testing.expectEqual(@as(u8, 1), timer.tima);
}

test "changing TAC clocks TIMA when the selected signal falls" {
    var timer = Timer{};
    var iflag: u8 = 0;
    timer.write(0xff07, 0x05);
    timer.tick(8, &iflag);
    timer.write(0xff07, 0x04);
    timer.tick(4, &iflag);
    try std.testing.expectEqual(@as(u8, 1), timer.tima);
}

test "writing TIMA cancels a delayed overflow reload" {
    var timer = Timer{};
    var iflag: u8 = 0;
    timer.write(0xff07, 0x05);
    timer.write(0xff06, 0x42);
    timer.write(0xff05, 0xff);
    timer.tick(20, &iflag);
    timer.write(0xff05, 0x77);
    timer.tick(8, &iflag);
    try std.testing.expectEqual(@as(u8, 0x77), timer.tima);
    try std.testing.expectEqual(@as(u8, 0), iflag & 0x04);
}
