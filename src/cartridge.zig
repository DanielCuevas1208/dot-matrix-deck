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

pub const Header = struct {
    title: [16]u8,
    mapper: []const u8,
    rom_size_kib: u32,
    ram_size_kib: u32,
    cgb: bool,
    sgb: bool,
    header_checksum_ok: bool,
    global_checksum: u16,
};

fn mapperName(code: u8) []const u8 {
    return switch (code) {
        0x00 => "ROM only",
        0x01...0x03 => "MBC1",
        0x05, 0x06 => "MBC2",
        0x0f...0x13 => "MBC3",
        0x19...0x1e => "MBC5",
        else => "Unknown",
    };
}

fn romSizeKib(code: u8) u32 {
    return switch (code) {
        0x00 => 32,
        0x01 => 64,
        0x02 => 128,
        0x03 => 256,
        0x04 => 512,
        0x05 => 1024,
        0x06 => 2048,
        else => 0,
    };
}

fn ramSizeKib(code: u8) u32 {
    return switch (code) {
        0x01 => 2,
        0x02 => 8,
        0x03 => 32,
        0x04 => 128,
        0x05 => 64,
        else => 0,
    };
}

// Reads the 80-byte cartridge header at $0134. The header checksum is the
// sum of bytes $0134..$014D plus $19, which must wrap to zero on hardware.
pub fn readHeader(image: []const u8) Header {
    var title = [_]u8{0} ** 16;
    if (image.len >= 0x0144) {
        const raw = image[0x0134..0x0144];
        var index: usize = 0;
        while (index < title.len) : (index += 1) {
            const byte = raw[index];
            if (byte < 0x20 or byte == 0x7f) break;
            title[index] = byte;
        }
    }
    var checksum: u8 = 0x19;
    if (image.len >= 0x014e) {
        for (image[0x0134..0x014e]) |byte| checksum +%= byte;
    }
    const global = if (image.len >= 0x0150) @as(u16, image[0x014f]) << 8 | image[0x014e] else 0;
    const mapper = if (image.len >= 0x0148) image[0x0147] else 0;
    const cgb = if (image.len >= 0x0144) (image[0x0143] == 0x80 or image[0x0143] == 0xc0) else false;
    const sgb = if (image.len >= 0x0147) image[0x0146] == 0x03 else false;
    const rom_size = if (image.len >= 0x0149) image[0x0148] else 0;
    const ram_size = if (image.len >= 0x014a) image[0x0149] else 0;
    return .{
        .title = title,
        .mapper = mapperName(mapper),
        .rom_size_kib = romSizeKib(rom_size),
        .ram_size_kib = ramSizeKib(ram_size),
        .cgb = cgb,
        .sgb = sgb,
        .header_checksum_ok = checksum == 0,
        .global_checksum = global,
    };
}

// Formats the header for the headless --info flag. Returns a slice into
// `buffer`; callers keep the buffer alive while they print the result.
pub fn formatHeader(header: Header, buffer: []u8) []const u8 {
    const title = std.mem.sliceTo(&header.title, 0);
    const cgb = if (header.cgb) "yes" else "no";
    const sgb = if (header.sgb) "yes" else "no";
    const checksum = if (header.header_checksum_ok) "valid" else "invalid";
    return std.fmt.bufPrint(buffer, "Title:  {s}\nMapper: {s}\nROM:    {d} KiB\nRAM:    {d} KiB\nCGB:    {s}\nSGB:    {s}\nHeader: {s} checksum\nGlobal: ${X:0>4}\n", .{
        if (title.len == 0) "(none)" else title,
        header.mapper,
        header.rom_size_kib,
        header.ram_size_kib,
        cgb,
        sgb,
        checksum,
        header.global_checksum,
    }) catch buffer[0..0];
}

test "readHeader parses a known ROM image" {
    var image: [0x8000]u8 = [_]u8{0} ** 0x8000;
    image[0x0147] = 0x01; // MBC1
    image[0x0148] = 0x01; // 64 KiB
    image[0x0149] = 0x03; // 32 KiB RAM
    image[0x0143] = 0x80; // CGB
    image[0x0146] = 0x03; // SGB
    _ = std.fmt.bufPrint(image[0x0134..0x0144], "TEST ROM", .{}) catch unreachable;
    const header = readHeader(&image);
    try std.testing.expectEqualStrings("TEST ROM", std.mem.sliceTo(&header.title, 0));
    try std.testing.expectEqualStrings("MBC1", header.mapper);
    try std.testing.expectEqual(@as(u32, 64), header.rom_size_kib);
    try std.testing.expectEqual(@as(u32, 32), header.ram_size_kib);
    try std.testing.expect(header.cgb);
    try std.testing.expect(header.sgb);
}

test "readHeader verifies the header checksum" {
    var image: [0x8000]u8 = [_]u8{0} ** 0x8000;
    _ = std.fmt.bufPrint(image[0x0134..0x0144], "SMOKE", .{}) catch unreachable;
    const before = readHeader(&image);
    try std.testing.expect(!before.header_checksum_ok);
    var checksum: u8 = 0x19;
    for (image[0x0134..0x014d]) |byte| checksum +%= byte;
    image[0x014d] = 0 -% checksum;
    const after = readHeader(&image);
    try std.testing.expect(after.header_checksum_ok);
}

test "formatHeader prints a readable block" {
    var image: [0x8000]u8 = [_]u8{0} ** 0x8000;
    _ = std.fmt.bufPrint(image[0x0134..0x0144], "SMOKE", .{}) catch unreachable;
    var checksum: u8 = 0x19;
    for (image[0x0134..0x014d]) |byte| checksum +%= byte;
    image[0x014d] = 0 -% checksum;
    var buffer: [256]u8 = undefined;
    const text = formatHeader(readHeader(&image), &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "Title:  SMOKE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Mapper: ROM only") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "valid checksum") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Global: $0000") != null);
}
