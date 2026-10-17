const std = @import("std");

// Cartridge image loading and bank mapping.
//
// The emulator supports ROM-only carts and the MBC1, MBC2, MBC3, and MBC5
// mappers. Each mapper maps a ROM window and an optional external RAM
// window. MBC3 also carries a real-time clock that advances with the CPU
// cycle count.

pub const Cartridge = struct {
    allocator: std.mem.Allocator,
    rom: []u8,
    ram: []u8,
    mapper: Mapper,
    has_battery: bool = false,
    ram_dirty: bool = false,
    rom_bank_low: u8 = 1,
    rom_bank_high: u8 = 0,
    ram_bank: u8 = 0,
    ram_enabled: bool = false,
    banking_mode: u8 = 0,
    rtc_regs: [5]u8 = [_]u8{0} ** 5,
    rtc_total_seconds: u64 = 0,
    rtc_cycle_accumulator: u64 = 0,
    latch_state: u8 = 0,
    latched_regs: [5]u8 = [_]u8{0} ** 5,

    pub const cycles_per_second: u64 = 4_194_304;

    const Mapper = enum { rom_only, mbc1, mbc2, mbc3, mbc5 };

    pub fn init(allocator: std.mem.Allocator, image: []const u8) !Cartridge {
        const rom = try allocator.alloc(u8, image.len);
        std.mem.copyForwards(u8, rom, image);
        const mapper = mapperFor(image);
        const battery = batteryFor(image);
        const ram_size: usize = if (mapper == .mbc2) 0x200 else externalRamSize(image);
        const ram = try allocator.alloc(u8, ram_size);
        @memset(ram, 0);
        return .{ .allocator = allocator, .rom = rom, .ram = ram, .mapper = mapper, .has_battery = battery };
    }

    pub fn deinit(self: *Cartridge) void {
        self.allocator.free(self.rom);
        self.allocator.free(self.ram);
    }

    pub fn read(self: *Cartridge, address: u16) u8 {
        const raw = @as(usize, address);
        if (raw < 0x4000) {
            const bank: usize = if (self.mapper == .mbc1 and self.banking_mode == 1) @as(usize, self.rom_bank_high) << 5 else 0;
            return self.romByte(bank * 0x4000 + raw);
        }
        if (raw < 0x8000) {
            return self.romByte(self.selectedRomBank() * 0x4000 + raw - 0x4000);
        }
        if (raw >= 0xa000 and raw < 0xc000) {
            return self.readExternal(raw);
        }
        return 0xff;
    }

    pub fn write(self: *Cartridge, address: u16, value: u8) void {
        if (self.mapper == .rom_only) return;
        const raw = @as(usize, address);
        if (raw < 0x8000) {
            self.writeBankRegisters(raw, value);
            return;
        }
        if (raw >= 0xa000 and raw < 0xc000) {
            self.writeExternal(raw, value);
        }
    }

    // Advances the MBC3 real-time clock with the given cycle count.
    // Other mappers have no clock and do nothing.
    pub fn tick(self: *Cartridge, cycles: u64) void {
        if (self.mapper != .mbc3) return;
        if ((self.rtc_regs[4] & 0x40) != 0) return;
        self.rtc_cycle_accumulator += cycles;
        const seconds = self.rtc_cycle_accumulator / cycles_per_second;
        if (seconds == 0) return;
        self.rtc_cycle_accumulator -= seconds * cycles_per_second;
        self.rtc_total_seconds +%= seconds;
        self.refreshRtcRegs();
    }

    // True when the cartridge carries battery-backed RAM.
    pub fn hasBattery(self: *const Cartridge) bool {
        return self.has_battery;
    }

    // True when external RAM holds writes not yet written to disk.
    pub fn ramDirty(self: *const Cartridge) bool {
        return self.ram_dirty;
    }

    // A battery-backed cartridge with unflushed RAM needs a save.
    pub fn saveNeeded(self: *const Cartridge) bool {
        return self.has_battery and self.ram_dirty;
    }

    pub fn markRamClean(self: *Cartridge) void {
        self.ram_dirty = false;
    }

    // The external RAM bytes, stored verbatim in the .sav file.
    pub fn saveData(self: *const Cartridge) []const u8 {
        return self.ram;
    }

    // Restores external RAM from a .sav file. The file size must match the
    // cartridge RAM size exactly.
    pub fn loadSaveData(self: *Cartridge, bytes: []const u8) !void {
        if (bytes.len != self.ram.len) return error.SaveSizeMismatch;
        @memcpy(self.ram, bytes);
        self.markRamClean();
    }

    fn mapperFor(image: []const u8) Mapper {
        if (image.len <= 0x147) return .rom_only;
        return switch (image[0x147]) {
            0x01, 0x02, 0x03 => .mbc1,
            0x05, 0x06 => .mbc2,
            0x0f...0x13 => .mbc3,
            0x19...0x1e => .mbc5,
            else => .rom_only,
        };
    }

    // The cartridge type byte marks battery-backed carts. Save files only
    // make sense for these images.
    fn batteryFor(image: []const u8) bool {
        if (image.len <= 0x147) return false;
        return switch (image[0x147]) {
            0x03, 0x06, 0x0f, 0x10, 0x13, 0x1b, 0x1e => true,
            else => false,
        };
    }

    fn externalRamSize(image: []const u8) usize {
        if (image.len <= 0x149) return 0;
        return switch (image[0x149]) {
            0x02 => 0x2000,
            0x03 => 0x8000,
            0x04 => 0x20000,
            0x05 => 0x10000,
            else => 0,
        };
    }

    // Returns the bank selected for the 4000-7FFF ROM window.
    fn selectedRomBank(self: *const Cartridge) usize {
        var bank: usize = switch (self.mapper) {
            .mbc1 => self.rom_bank_low & 0x1f,
            .mbc2 => self.rom_bank_low & 0x0f,
            .mbc3 => self.rom_bank_low & 0x7f,
            .mbc5 => self.rom_bank_low,
            .rom_only => 0,
        };
        if (self.mapper == .mbc1) bank |= @as(usize, self.rom_bank_high) << 5;
        if (self.mapper == .mbc5) bank |= @as(usize, self.rom_bank_high) << 8;
        if (bank == 0 and self.mapper != .mbc5) bank = 1;
        return bank;
    }

    fn writeBankRegisters(self: *Cartridge, raw: usize, value: u8) void {
        if (raw < 0x4000) {
            // MBC2 folds both registers into 0000-3FFF. Address bit 8
            // selects the ROM bank register; clearing it selects the RAM
            // enable register.
            if (self.mapper == .mbc2) {
                if ((raw & 0x100) == 0) {
                    self.ram_enabled = (value & 0x0f) == 0x0a;
                } else {
                    self.rom_bank_low = value & 0x0f;
                    if (self.rom_bank_low == 0) self.rom_bank_low = 1;
                }
                return;
            }
            if (raw < 0x2000) {
                self.ram_enabled = (value & 0x0f) == 0x0a;
                return;
            }
            // MBC5 keeps the low eight bank bits at 2000-2FFF and the
            // ninth bit at 3000-3FFF.
            if (self.mapper == .mbc5) {
                if (raw < 0x3000) {
                    self.rom_bank_low = value;
                } else {
                    self.rom_bank_high = value & 1;
                }
                return;
            }
            // MBC1 uses a five-bit bank register; MBC3 uses seven bits.
            self.rom_bank_low = if (self.mapper == .mbc3) value & 0x7f else value & 0x1f;
            if (self.rom_bank_low == 0) self.rom_bank_low = 1;
            return;
        }
        switch (raw) {
            0x4000...0x5fff => switch (self.mapper) {
                .mbc1 => self.rom_bank_high = value & 0x03,
                .mbc3, .mbc5 => self.ram_bank = value & 0x0f,
                else => {},
            },
            0x6000...0x7fff => switch (self.mapper) {
                .mbc1 => self.banking_mode = value & 1,
                .mbc3 => self.latchRtc(value),
                else => {},
            },
            else => {},
        }
    }

    fn readExternal(self: *Cartridge, raw: usize) u8 {
        if (self.ram.len == 0 or !self.ram_enabled) return 0xff;
        return switch (self.mapper) {
            .mbc1 => blk: {
                var index = raw - 0xa000;
                if (self.banking_mode == 1) index += @as(usize, self.rom_bank_high) * 0x2000;
                break :blk if (index < self.ram.len) self.ram[index] else 0xff;
            },
            .mbc2 => blk: {
                const index = self.mbc2RamIndex(raw);
                break :blk 0xf0 | (self.ram[index] & 0x0f);
            },
            .mbc3 => blk: {
                if (self.ram_bank >= 8 and self.ram_bank <= 0x0c) break :blk self.readRtcRegister();
                const index = @as(usize, self.ram_bank & 0x03) * 0x2000 + (raw - 0xa000);
                break :blk if (index < self.ram.len) self.ram[index] else 0xff;
            },
            .mbc5 => blk: {
                const index = @as(usize, self.ram_bank & 0x0f) * 0x2000 + (raw - 0xa000);
                break :blk if (index < self.ram.len) self.ram[index] else 0xff;
            },
            .rom_only => 0xff,
        };
    }

    fn writeExternal(self: *Cartridge, raw: usize, value: u8) void {
        if (self.ram.len == 0 or !self.ram_enabled) return;
        switch (self.mapper) {
            .mbc1 => {
                var index = raw - 0xa000;
                if (self.banking_mode == 1) index += @as(usize, self.rom_bank_high) * 0x2000;
                if (index < self.ram.len) {
                    self.ram[index] = value;
                    self.ram_dirty = true;
                }
            },
            .mbc2 => {
                const index = self.mbc2RamIndex(raw);
                self.ram[index] = value & 0x0f;
                self.ram_dirty = true;
            },
            .mbc3 => {
                if (self.ram_bank >= 8 and self.ram_bank <= 0x0c) {
                    self.writeRtcRegister(value);
                    return;
                }
                const index = @as(usize, self.ram_bank & 0x03) * 0x2000 + (raw - 0xa000);
                if (index < self.ram.len) {
                    self.ram[index] = value;
                    self.ram_dirty = true;
                }
            },
            .mbc5 => {
                const index = @as(usize, self.ram_bank & 0x0f) * 0x2000 + (raw - 0xa000);
                if (index < self.ram.len) {
                    self.ram[index] = value;
                    self.ram_dirty = true;
                }
            },
            .rom_only => {},
        }
    }

    // MBC2 maps its 512-nibble internal RAM through the lower 9 address
    // bits, ignoring bit 0 of the byte address.
    fn mbc2RamIndex(self: *const Cartridge, raw: usize) usize {
        _ = self;
        return ((raw - 0xa000) >> 1) & 0x1ff;
    }

    fn readRtcRegister(self: *Cartridge) u8 {
        if (self.latch_state == 1) return self.latched_regs[self.ram_bank - 8];
        return self.rtc_regs[self.ram_bank - 8];
    }

    fn writeRtcRegister(self: *Cartridge, value: u8) void {
        // The control register is always writable. The time registers
        // only accept writes while the clock is halted.
        if (self.ram_bank == 0x0c) {
            const was_halted = (self.rtc_regs[4] & 0x40) != 0;
            self.rtc_regs[4] = value & 0xc0;
            if (was_halted and (value & 0x40) == 0) self.recomputeSeconds();
            return;
        }
        if ((self.rtc_regs[4] & 0x40) != 0) {
            self.rtc_regs[self.ram_bank - 8] = value;
            self.recomputeSeconds();
        }
    }

    // A write of 0 then 1 to 0x6000 latches the clock into the visible
    // registers. A trailing 0 releases the latch.
    fn latchRtc(self: *Cartridge, value: u8) void {
        if (value == 1 and self.latch_state == 0) {
            self.latched_regs = self.rtc_regs;
            self.latch_state = 1;
        } else if (value == 0) {
            self.latch_state = 0;
        }
    }

    // Rebuilds the running second count from the halted registers. The
    // clock resumes from this time when the halt bit clears.
    fn recomputeSeconds(self: *Cartridge) void {
        const days = (@as(u64, self.rtc_regs[4] >> 7) << 8) | (self.rtc_regs[3] & 0xff);
        const hours = bcdToBinary(self.rtc_regs[2]);
        const minutes = bcdToBinary(self.rtc_regs[1]);
        const seconds = bcdToBinary(self.rtc_regs[0]);
        self.rtc_total_seconds = @as(u64, days) * 86_400 + @as(u64, hours) * 3_600 + @as(u64, minutes) * 60 + seconds;
        self.rtc_cycle_accumulator = 0;
    }

    fn refreshRtcRegs(self: *Cartridge) void {
        const days = self.rtc_total_seconds / 86_400;
        const remainder = self.rtc_total_seconds % 86_400;
        const hours = remainder / 3_600;
        const minutes = (remainder % 3_600) / 60;
        const seconds = remainder % 60;
        self.rtc_regs[0] = binaryToBcd(seconds);
        self.rtc_regs[1] = binaryToBcd(minutes);
        self.rtc_regs[2] = binaryToBcd(hours);
        const day_bits = days & 0x1ff;
        self.rtc_regs[3] = (self.rtc_regs[3] & 0x80) | @as(u8, @intCast(day_bits & 0xff));
        if (days > 0x1ff) self.rtc_regs[3] |= 0x80;
        self.rtc_regs[4] = (self.rtc_regs[4] & 0x40) | (@as(u8, @intCast((day_bits >> 8) & 1)) << 7);
    }

    fn bcdToBinary(value: u8) u64 {
        return @as(u64, (value >> 4) * 10 + (value & 0x0f));
    }

    fn binaryToBcd(value: u64) u8 {
        return @as(u8, @intCast((value / 10) << 4 | (value % 10)));
    }

    fn romByte(self: *Cartridge, index: usize) u8 {
        return if (index < self.rom.len) self.rom[index] else 0xff;
    }
};

const testing = @import("std").testing;

// Builds an image with a marker byte at the start of every 16KB bank.
// The header claims the given mapper and RAM size.
fn bankedImage(allocator: std.mem.Allocator, size: usize, mapper_type: u8, ram_type: u8) ![]u8 {
    const image = try allocator.alloc(u8, size);
    @memset(image, 0);
    image[0x147] = mapper_type;
    image[0x149] = ram_type;
    for (0..size / 0x4000) |bank| {
        image[bank * 0x4000] = @intCast(bank + 1);
    }
    return image;
}

fn mbc1Image(allocator: std.mem.Allocator) ![]u8 {
    return bankedImage(allocator, 0x40000, 0x01, 0x03);
}

fn mbc2Image(allocator: std.mem.Allocator) ![]u8 {
    return bankedImage(allocator, 0x40000, 0x05, 0x00);
}

fn mbc3Image(allocator: std.mem.Allocator) ![]u8 {
    return bankedImage(allocator, 0x200000, 0x0f, 0x03);
}

fn mbc5Image(allocator: std.mem.Allocator) ![]u8 {
    return bankedImage(allocator, 0x200000, 0x19, 0x03);
}

fn romOnlyImage(allocator: std.mem.Allocator) ![]u8 {
    const image = try allocator.alloc(u8, 0x8000);
    @memset(image, 0);
    image[0x147] = 0x00; // ROM only
    return image;
}

test "ROM-only cartridge ignores mapper writes" {
    const image = try romOnlyImage(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    cartridge.write(0x2000, 0x03);
    cartridge.write(0x0000, 0x0a);
    cartridge.write(0xa000, 0x42);
    try testing.expectEqual(@as(u8, 0xff), cartridge.read(0xa000));
    try testing.expectEqual(@as(u8, 0x00), cartridge.read(0x4000));
}

test "MBC1 switches ROM banks through the low register" {
    const image = try mbc1Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    // Bank 1 is the default for the 4000-7FFF window.
    try testing.expectEqual(@as(u8, 2), cartridge.read(0x4000));

    cartridge.write(0x2000, 0x05);
    try testing.expectEqual(@as(u8, 6), cartridge.read(0x4000));

    // Writing zero selects bank 1 instead of bank 0.
    cartridge.write(0x2000, 0x00);
    try testing.expectEqual(@as(u8, 2), cartridge.read(0x4000));
}

test "MBC1 keeps the low window pinned to bank 0" {
    const image = try mbc1Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    cartridge.write(0x2000, 0x07);
    try testing.expectEqual(@as(u8, 1), cartridge.read(0x0000));
}

test "MBC1 gates external RAM writes on the enable register" {
    const image = try mbc1Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    // Disabled RAM ignores writes and reads open-bus.
    cartridge.write(0xa000, 0x42);
    try testing.expectEqual(@as(u8, 0xff), cartridge.read(0xa000));

    cartridge.write(0x0000, 0x0a);
    cartridge.write(0xa000, 0x42);
    try testing.expectEqual(@as(u8, 0x42), cartridge.read(0xa000));

    // Any other low nibble disables RAM again.
    cartridge.write(0x0000, 0x00);
    cartridge.write(0xa000, 0x43);
    cartridge.write(0x0000, 0x0a);
    try testing.expectEqual(@as(u8, 0x42), cartridge.read(0xa000));
}

test "MBC1 banking mode selects RAM banks" {
    const image = try mbc1Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    cartridge.write(0x0000, 0x0a);
    // Mode 1 uses the high ROM register to pick the RAM bank.
    cartridge.write(0x6000, 0x01);
    cartridge.write(0x4000, 0x02);
    cartridge.write(0xa000, 0x11);
    try testing.expectEqual(@as(u8, 0x11), cartridge.read(0xa000));

    // Mode 0 pins RAM to bank 0 and ignores the high register.
    cartridge.write(0x6000, 0x00);
    cartridge.write(0x4000, 0x00);
    cartridge.write(0xa000, 0x22);
    try testing.expectEqual(@as(u8, 0x22), cartridge.read(0xa000));

    // Back in mode 1, RAM bank 2 still holds its earlier byte.
    cartridge.write(0x6000, 0x01);
    cartridge.write(0x4000, 0x02);
    try testing.expectEqual(@as(u8, 0x11), cartridge.read(0xa000));

    // RAM bank 0 holds the mode-0 write.
    cartridge.write(0x4000, 0x00);
    try testing.expectEqual(@as(u8, 0x22), cartridge.read(0xa000));
}

test "MBC1 reads past the end of ROM as open bus" {
    const image = try mbc1Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    // 16 banks fill the image; selecting bank 31 reads past the end.
    cartridge.write(0x2000, 0x1f);
    cartridge.write(0x4000, 0x03);
    try testing.expectEqual(@as(u8, 0xff), cartridge.read(0x4000));
}

test "MBC2 selects ROM banks through the bit-8 address" {
    const image = try mbc2Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    // Bank 1 is the default for the 4000-7FFF window.
    try testing.expectEqual(@as(u8, 2), cartridge.read(0x4000));

    // Address bit 8 set means a ROM bank write.
    cartridge.write(0x2100, 0x03);
    try testing.expectEqual(@as(u8, 4), cartridge.read(0x4000));

    // A low bank value still maps to bank 1.
    cartridge.write(0x2100, 0x00);
    try testing.expectEqual(@as(u8, 2), cartridge.read(0x4000));
}

test "MBC2 gates its 4-bit RAM on the enable register" {
    const image = try mbc2Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    // Disabled RAM ignores writes.
    cartridge.write(0xa000, 0x0f);
    try testing.expectEqual(@as(u8, 0xff), cartridge.read(0xa000));

    cartridge.write(0x0000, 0x0a);
    cartridge.write(0xa000, 0x0f);
    // Only the low nibble is stored; the high nibble reads as 0xF.
    try testing.expectEqual(@as(u8, 0x0f), cartridge.read(0xa000) & 0x0f);

    // Address bit 8 picks the upper 256-nibble block.
    cartridge.write(0xa200, 0x0c);
    try testing.expectEqual(@as(u8, 0x0c), cartridge.read(0xa200) & 0x0f);

    // The two blocks are independent.
    try testing.expectEqual(@as(u8, 0x0f), cartridge.read(0xa000) & 0x0f);
}

test "MBC3 switches ROM banks and RAM banks" {
    const image = try mbc3Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    // Bank 1 is the default for the 4000-7FFF window.
    try testing.expectEqual(@as(u8, 2), cartridge.read(0x4000));

    cartridge.write(0x2000, 0x05);
    try testing.expectEqual(@as(u8, 6), cartridge.read(0x4000));

    // The seven-bit register reaches banks past the MBC1 range.
    cartridge.write(0x2000, 0x40);
    try testing.expectEqual(@as(u8, 0x41), cartridge.read(0x4000));

    // RAM is gated and banked by the 0x4000 register.
    cartridge.write(0x0000, 0x0a);
    cartridge.write(0x4000, 0x00);
    cartridge.write(0xa000, 0x11);
    try testing.expectEqual(@as(u8, 0x11), cartridge.read(0xa000));

    cartridge.write(0x4000, 0x02);
    cartridge.write(0xa000, 0x22);
    try testing.expectEqual(@as(u8, 0x22), cartridge.read(0xa000));

    cartridge.write(0x4000, 0x00);
    try testing.expectEqual(@as(u8, 0x11), cartridge.read(0xa000));
}

test "MBC3 RTC counts seconds in BCD and latches" {
    const image = try mbc3Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    cartridge.write(0x0000, 0x0a);
    // Select the control register and halt the clock before writing.
    cartridge.write(0x4000, 0x0c);
    cartridge.write(0xa000, 0x40); // halt bit set
    cartridge.write(0x4000, 0x08); // seconds
    cartridge.write(0xa000, 0x59);
    cartridge.write(0x4000, 0x09); // minutes
    cartridge.write(0xa000, 0x00);
    cartridge.write(0x4000, 0x0a); // hours
    cartridge.write(0xa000, 0x00);
    cartridge.write(0x4000, 0x0c); // clear halt
    cartridge.write(0xa000, 0x00);

    // One second later the minutes read one.
    cartridge.tick(Cartridge.cycles_per_second);
    cartridge.write(0x4000, 0x08);
    cartridge.write(0x6000, 0x00);
    cartridge.write(0x6000, 0x01);
    try testing.expectEqual(@as(u8, 0x00), cartridge.read(0xa000));
    cartridge.write(0x4000, 0x09);
    cartridge.write(0x6000, 0x00);
    cartridge.write(0x6000, 0x01);
    try testing.expectEqual(@as(u8, 0x01), cartridge.read(0xa000));

    // Halting freezes the clock.
    cartridge.write(0x4000, 0x0c);
    cartridge.write(0xa000, 0x40);
    cartridge.tick(Cartridge.cycles_per_second * 2);
    cartridge.write(0x4000, 0x09);
    cartridge.write(0x6000, 0x00);
    cartridge.write(0x6000, 0x01);
    try testing.expectEqual(@as(u8, 0x01), cartridge.read(0xa000));
}

test "MBC5 switches ROM banks through both registers" {
    const image = try mbc5Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    // Bank 1 is the default for the 4000-7FFF window.
    try testing.expectEqual(@as(u8, 2), cartridge.read(0x4000));

    cartridge.write(0x2000, 0x05);
    try testing.expectEqual(@as(u8, 6), cartridge.read(0x4000));

    // Bank 0 is addressable, unlike MBC1.
    cartridge.write(0x2000, 0x00);
    try testing.expectEqual(@as(u8, 1), cartridge.read(0x4000));

    // The 0x3000 register extends the bank to nine bits. Bank 0x20 fits
    // the image; bank 0x120 does not, so it reads as open bus.
    cartridge.write(0x2000, 0x20);
    cartridge.write(0x3000, 0x00);
    try testing.expectEqual(@as(u8, 0x21), cartridge.read(0x4000));
    cartridge.write(0x3000, 0x01);
    try testing.expectEqual(@as(u8, 0xff), cartridge.read(0x4000));
}

test "MBC5 banks external RAM up to 16 banks" {
    const image = try mbc5Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    cartridge.write(0x0000, 0x0a);
    cartridge.write(0x4000, 0x03);
    cartridge.write(0xa000, 0x42);
    try testing.expectEqual(@as(u8, 0x42), cartridge.read(0xa000));

    // RAM bank 0 stays fresh while bank 3 holds its byte.
    cartridge.write(0x4000, 0x00);
    try testing.expectEqual(@as(u8, 0x00), cartridge.read(0xa000));

    cartridge.write(0x4000, 0x03);
    try testing.expectEqual(@as(u8, 0x42), cartridge.read(0xa000));
}

test "battery flag matches the cartridge type byte" {
    const cases = [_]struct { byte: u8, battery: bool }{
        .{ .byte = 0x00, .battery = false },
        .{ .byte = 0x01, .battery = false },
        .{ .byte = 0x03, .battery = true },
        .{ .byte = 0x06, .battery = true },
        .{ .byte = 0x0f, .battery = true },
        .{ .byte = 0x12, .battery = false },
        .{ .byte = 0x13, .battery = true },
        .{ .byte = 0x1b, .battery = true },
        .{ .byte = 0x1e, .battery = true },
    };
    for (cases) |case| {
        var image: [0x8000]u8 = [_]u8{0} ** 0x8000;
        image[0x147] = case.byte;
        var cartridge = try Cartridge.init(testing.allocator, &image);
        defer cartridge.deinit();
        try testing.expectEqual(case.battery, cartridge.hasBattery());
    }
}

test "external RAM writes mark the save dirty" {
    var image: [0x40000]u8 = [_]u8{0} ** 0x40000;
    image[0x147] = 0x03; // MBC1 + RAM + battery
    image[0x149] = 0x03; // 32KB external RAM
    var cartridge = try Cartridge.init(testing.allocator, &image);
    defer cartridge.deinit();

    try testing.expect(!cartridge.saveNeeded());
    // RAM disabled: writes are dropped and stay clean.
    cartridge.write(0xa000, 0x42);
    try testing.expect(!cartridge.ramDirty());

    cartridge.write(0x0000, 0x0a);
    cartridge.write(0xa000, 0x42);
    try testing.expect(cartridge.saveNeeded());

    cartridge.markRamClean();
    try testing.expect(!cartridge.saveNeeded());
}

test "cart without battery never needs a save" {
    const image = try romOnlyImage(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();
    cartridge.write(0xa000, 0x42);
    try testing.expect(!cartridge.saveNeeded());
}

test "save data round-trips through loadSaveData" {
    const image = try mbc1Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();

    cartridge.write(0x0000, 0x0a);
    cartridge.write(0xa000, 0x11);
    cartridge.write(0xa001, 0x22);
    const saved = try testing.allocator.dupe(u8, cartridge.saveData());
    defer testing.allocator.free(saved);

    var reloaded = try Cartridge.init(testing.allocator, image);
    defer reloaded.deinit();
    try reloaded.loadSaveData(saved);
    reloaded.write(0x0000, 0x0a);
    try testing.expectEqual(@as(u8, 0x11), reloaded.read(0xa000));
    try testing.expectEqual(@as(u8, 0x22), reloaded.read(0xa001));
}

test "save data rejects a size mismatch" {
    const image = try mbc1Image(testing.allocator);
    defer testing.allocator.free(image);
    var cartridge = try Cartridge.init(testing.allocator, image);
    defer cartridge.deinit();
    const short = [_]u8{0x00} ** 4;
    try testing.expectError(error.SaveSizeMismatch, cartridge.loadSaveData(&short));
}
