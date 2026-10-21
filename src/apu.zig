const std = @import("std");

pub const clock_hz: u64 = 4_194_304;
pub const sample_rate: u32 = 44_100;

const frame_step_cycles: u32 = 8_192;
const envelope_step: u3 = 7;
const duty_patterns = [_]u8{
    0b00000001,
    0b10000001,
    0b10000111,
    0b01111110,
};

// This slice models channel 2: one programmable square wave with length and
// volume envelope control. It produces centered signed PCM samples.
pub const Apu = struct {
    powered: bool = true,
    channel: SquareChannel = .{},
    frame_cycles: u32 = 0,
    frame_step: u3 = 0,
    sample_phase: u64 = 0,

    pub fn read(self: *const Apu, address: u16) u8 {
        return switch (address) {
            0xff16 => self.channel.readDutyLength(),
            0xff17 => self.channel.envelope_register,
            0xff18 => 0xff,
            0xff19 => 0xbf,
            0xff26 => 0x70 | (if (self.powered) @as(u8, 0x80) else 0) |
                (if (self.channel.enabled) @as(u8, 0x02) else 0),
            else => 0xff,
        };
    }

    pub fn write(self: *Apu, address: u16, value: u8) void {
        if (address == 0xff26) {
            if ((value & 0x80) == 0) {
                self.powered = false;
                self.channel = .{};
                self.frame_cycles = 0;
                self.frame_step = 0;
                self.sample_phase = 0;
            } else if (!self.powered) {
                self.powered = true;
            }
            return;
        }
        if (!self.powered) return;

        switch (address) {
            0xff16 => self.channel.writeDutyLength(value),
            0xff17 => self.channel.writeEnvelope(value),
            0xff18 => self.channel.writeFrequencyLow(value),
            0xff19 => self.channel.writeFrequencyHigh(value),
            else => {},
        }
    }

    pub fn tick(self: *Apu, cycles: u16) void {
        if (!self.powered) return;

        var remaining: u32 = cycles;
        while (remaining != 0) {
            const until_frame = frame_step_cycles - self.frame_cycles;
            const slice = @min(remaining, until_frame);
            self.channel.tick(slice);
            self.frame_cycles += slice;
            remaining -= slice;

            if (self.frame_cycles == frame_step_cycles) {
                self.frame_cycles = 0;
                self.frame_step +%= 1;
                self.clockFrameSequencer();
            }
        }
    }

    pub fn sample(self: *const Apu) i16 {
        if (!self.powered) return 0;
        return self.channel.sample();
    }

    // Renders samples with integer clock conversion. The result is repeatable
    // on every host and does not depend on wall-clock time.
    pub fn renderSamples(self: *Apu, output: []i16) void {
        for (output) |*sample_value| {
            self.sample_phase += clock_hz;
            const cycles = self.sample_phase / sample_rate;
            self.sample_phase %= sample_rate;
            self.tick(@intCast(cycles));
            sample_value.* = self.sample();
        }
    }

    fn clockFrameSequencer(self: *Apu) void {
        switch (self.frame_step) {
            0, 2, 4, 6 => self.channel.clockLength(),
            else => {},
        }
        if (self.frame_step == envelope_step) self.channel.clockEnvelope();
    }
};

const SquareChannel = struct {
    duty: u2 = 0,
    length_load: u8 = 0,
    length_counter: u8 = 0,
    envelope_register: u8 = 0,
    envelope_volume: u8 = 0,
    envelope_timer: u4 = 0,
    frequency_low: u8 = 0,
    frequency_high: u3 = 0,
    length_enabled: bool = false,
    dac_enabled: bool = false,
    enabled: bool = false,
    timer: u16 = 0,
    duty_index: u3 = 0,

    fn readDutyLength(self: *const SquareChannel) u8 {
        return (@as(u8, self.duty) << 6) | 0x3f;
    }

    fn writeDutyLength(self: *SquareChannel, value: u8) void {
        self.duty = @intCast(value >> 6);
        self.length_load = value & 0x3f;
    }

    fn writeEnvelope(self: *SquareChannel, value: u8) void {
        self.envelope_register = value;
        self.dac_enabled = (value & 0xf8) != 0;
        if (!self.dac_enabled) self.enabled = false;
    }

    fn writeFrequencyLow(self: *SquareChannel, value: u8) void {
        self.frequency_low = value;
    }

    fn writeFrequencyHigh(self: *SquareChannel, value: u8) void {
        self.frequency_high = @intCast(value & 0x07);
        self.length_enabled = (value & 0x40) != 0;
        if ((value & 0x80) != 0) self.trigger();
    }

    fn trigger(self: *SquareChannel) void {
        if (!self.dac_enabled) {
            self.enabled = false;
            return;
        }

        self.enabled = true;
        if (self.length_counter == 0) self.length_counter = 64 - self.length_load;
        self.envelope_volume = self.envelope_register >> 4;
        self.envelope_timer = self.envelopePeriod();
        self.timer = self.frequencyPeriod();
        self.duty_index = 0;
    }

    fn tick(self: *SquareChannel, cycles: u32) void {
        if (!self.enabled) return;

        var remaining = cycles;
        while (remaining != 0) : (remaining -= 1) {
            if (self.timer > 0) self.timer -= 1;
            if (self.timer == 0) {
                self.timer = self.frequencyPeriod();
                self.duty_index +%= 1;
            }
        }
    }

    fn clockLength(self: *SquareChannel) void {
        if (!self.length_enabled or self.length_counter == 0) return;
        self.length_counter -= 1;
        if (self.length_counter == 0) self.enabled = false;
    }

    fn clockEnvelope(self: *SquareChannel) void {
        const period = self.envelope_register & 0x07;
        if (period == 0) {
            self.envelope_timer = 8;
            return;
        }
        if (self.envelope_timer > 1) {
            self.envelope_timer -= 1;
            return;
        }

        self.envelope_timer = @intCast(period);
        if ((self.envelope_register & 0x08) != 0) {
            if (self.envelope_volume < 15) self.envelope_volume += 1;
        } else if (self.envelope_volume > 0) {
            self.envelope_volume -= 1;
        }
    }

    fn envelopePeriod(self: *const SquareChannel) u4 {
        const period = self.envelope_register & 0x07;
        return if (period == 0) 8 else @intCast(period);
    }

    fn frequencyPeriod(self: *const SquareChannel) u16 {
        const frequency = (@as(u16, self.frequency_high) << 8) | self.frequency_low;
        return @intCast((@as(u16, 2048) - @min(frequency, @as(u16, 2047))) * 4);
    }

    fn sample(self: *const SquareChannel) i16 {
        if (!self.enabled or !self.dac_enabled or self.envelope_volume == 0) return 0;
        const pattern = duty_patterns[self.duty];
        const high = ((pattern >> self.duty_index) & 1) != 0;
        const amplitude: i16 = @intCast(@as(u16, self.envelope_volume) * 2048);
        return if (high) amplitude else -amplitude;
    }
};

test "register writes trigger channel 2 and expose status" {
    var apu = Apu{};
    apu.write(0xff16, 0x81);
    apu.write(0xff17, 0xa2);
    apu.write(0xff18, 0x34);
    apu.write(0xff19, 0xc5);

    try std.testing.expectEqual(@as(u8, 0xbf), apu.read(0xff16));
    try std.testing.expectEqual(@as(u8, 0xa2), apu.read(0xff17));
    try std.testing.expectEqual(@as(u8, 0xff), apu.read(0xff18));
    try std.testing.expectEqual(@as(u8, 0xbf), apu.read(0xff19));
    try std.testing.expectEqual(@as(u8, 0xf2), apu.read(0xff26));
    try std.testing.expectEqual(@as(u8, 63), apu.channel.length_counter);
    try std.testing.expectEqual(@as(u8, 10), apu.channel.envelope_volume);
}

test "square duty phase changes at the selected frequency" {
    var apu = Apu{};
    apu.write(0xff16, 0x00);
    apu.write(0xff17, 0xf0);
    apu.write(0xff18, 0xff);
    apu.write(0xff19, 0x87);

    try std.testing.expectEqual(@as(i16, 30_720), apu.sample());
    apu.tick(4);
    try std.testing.expectEqual(@as(i16, -30_720), apu.sample());
}

test "envelope clocks at 64 hertz and respects direction" {
    var apu = Apu{};
    apu.write(0xff16, 0x80);
    apu.write(0xff17, 0x39); // volume 3, increase, period 1
    apu.write(0xff19, 0x80);

    try std.testing.expectEqual(@as(u8, 3), apu.channel.envelope_volume);
    apu.tick(7 * frame_step_cycles);
    try std.testing.expectEqual(@as(u8, 4), apu.channel.envelope_volume);
}

test "power off clears channel output and ignores register writes" {
    var apu = Apu{};
    apu.write(0xff17, 0xf0);
    apu.write(0xff19, 0x80);
    apu.write(0xff26, 0x00);
    apu.write(0xff17, 0xf0);

    try std.testing.expectEqual(@as(u8, 0x70), apu.read(0xff26));
    try std.testing.expectEqual(@as(i16, 0), apu.sample());
    try std.testing.expectEqual(@as(u8, 0), apu.read(0xff17));
}

test "sample rendering uses a stable integer clock conversion" {
    var apu = Apu{};
    apu.write(0xff16, 0x80);
    apu.write(0xff17, 0xf0);
    apu.write(0xff18, 0x40);
    apu.write(0xff19, 0x87);

    var samples = [_]i16{0} ** 8;
    apu.renderSamples(&samples);
    try std.testing.expectEqual(@as(i16, 30_720), samples[0]);
    try std.testing.expectEqual(@as(i16, 30_720), samples[1]);
    try std.testing.expectEqual(@as(i16, 30_720), samples[2]);
    try std.testing.expectEqual(@as(i16, 30_720), samples[3]);
    try std.testing.expectEqual((8 * clock_hz) % sample_rate, apu.sample_phase);
}
