const std = @import("std");

pub const CartridgeHeader = struct {
    title: [16]u8,
    cgb_flag: u8,
    mapper: []const u8,
    rom_size_kib: u16,
    ram_size_kib: u16,
};

// Parses the fixed header block of a ROM image. The emulator does not
// validate the Nintendo logo or the checksums, so only the fields that
// the frontend and the --info flag display are read.
pub fn readHeader(rom: []const u8) CartridgeHeader {
    var title = [_]u8{0} ** 16;
    if (rom.len > 0x134 + 16) std.mem.copyForwards(u8, &title, rom[0x134 .. 0x134 + 16]);
    const cgb_flag: u8 = if (rom.len > 0x143) rom[0x143] else 0;
    const mapper: []const u8 = if (rom.len > 0x147) switch (rom[0x147]) {
        0x01, 0x02, 0x03 => "MBC1",
        else => "ROM only",
    } else "ROM only";
    const rom_size_kib: u16 = if (rom.len > 0x148) switch (rom[0x148]) {
        0 => 32,
        1 => 64,
        2 => 128,
        3 => 256,
        4 => 512,
        5 => 1024,
        6 => 2048,
        7 => 4096,
        else => 32,
    } else 32;
    const ram_size_kib: u16 = if (rom.len > 0x149) switch (rom[0x149]) {
        0 => 0,
        1 => 2,
        2 => 8,
        3 => 32,
        4 => 128,
        5 => 64,
        else => 0,
    } else 0;
    return .{ .title = title, .cgb_flag = cgb_flag, .mapper = mapper, .rom_size_kib = rom_size_kib, .ram_size_kib = ram_size_kib };
}

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
