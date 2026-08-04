const std = @import("std");

pub const Cartridge = struct {
    allocator: std.mem.Allocator,
    rom: []u8,
    ram: []u8,
    mapper: Mapper,
    rom_bank_low: u8 = 1,
    rom_bank_high: u8 = 0,
    ram_enabled: bool = false,
    banking_mode: u8 = 0,

    const Mapper = enum { rom_only, mbc1 };

    pub fn init(allocator: std.mem.Allocator, image: []const u8) !Cartridge {
        const rom = try allocator.alloc(u8, image.len);
        std.mem.copyForwards(u8, rom, image);
        const mapper = if (image.len > 0x147 and (image[0x147] == 0x01 or image[0x147] == 0x02 or image[0x147] == 0x03)) Mapper.mbc1 else Mapper.rom_only;
        const ram_size: usize = if (image.len > 0x149) switch (image[0x149]) {
            0x02 => 0x2000,
            0x03 => 0x8000,
            0x04 => 0x20000,
            0x05 => 0x10000,
            else => 0,
        } else 0;
        const ram = try allocator.alloc(u8, ram_size);
        @memset(ram, 0);
        return .{ .allocator = allocator, .rom = rom, .ram = ram, .mapper = mapper };
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
            var bank: usize = self.rom_bank_low & 0x1f;
            if (bank == 0) bank = 1;
            if (self.mapper == .mbc1) bank |= @as(usize, self.rom_bank_high) << 5;
            return self.romByte(bank * 0x4000 + raw - 0x4000);
        }
        if (raw >= 0xa000 and raw < 0xc000 and self.ram.len != 0 and self.ram_enabled) {
            var index = raw - 0xa000;
            if (self.mapper == .mbc1 and self.banking_mode == 1) index += @as(usize, self.rom_bank_high) * 0x2000;
            return if (index < self.ram.len) self.ram[index] else 0xff;
        }
        return 0xff;
    }

    pub fn write(self: *Cartridge, address: u16, value: u8) void {
        if (self.mapper == .rom_only) return;
        switch (address) {
            0x0000...0x1fff => self.ram_enabled = (value & 0x0f) == 0x0a,
            0x2000...0x3fff => {
                self.rom_bank_low = value & 0x1f;
                if (self.rom_bank_low == 0) self.rom_bank_low = 1;
            },
            0x4000...0x5fff => self.rom_bank_high = value & 0x03,
            0x6000...0x7fff => self.banking_mode = value & 1,
            0xa000...0xbfff => if (self.ram.len != 0 and self.ram_enabled) {
                var index = @as(usize, address - 0xa000);
                if (self.mapper == .mbc1 and self.banking_mode == 1) index += @as(usize, self.rom_bank_high) * 0x2000;
                if (index < self.ram.len) self.ram[index] = value;
            },
            else => {},
        }
    }

    fn romByte(self: *Cartridge, index: usize) u8 {
        return if (index < self.rom.len) self.rom[index] else 0xff;
    }
};

const testing = @import("std").testing;

// Builds a 256KB MBC1 image with a distinct marker byte at the start of
// every 16KB bank. The header claims MBC1 and 32KB of RAM.
fn mbc1Image(allocator: std.mem.Allocator) ![]u8 {
    const image = try allocator.alloc(u8, 0x40000);
    @memset(image, 0);
    image[0x147] = 0x01; // MBC1
    image[0x149] = 0x03; // 32KB RAM
    for (0..16) |bank| {
        image[bank * 0x4000] = @intCast(bank + 1);
    }
    return image;
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
