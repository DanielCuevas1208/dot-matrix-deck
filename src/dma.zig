// The Game Boy OAM DMA controller.
//
// Writing FF46 copies one page of memory into object attribute memory.
// The transfer copies 0xa0 bytes from page XX00 into FE00-FE9F. It runs
// for 640 T-cycles and blocks the CPU while it works.

pub const Dma = struct {
    source_page: u8 = 0,
    offset: u16 = 0,
    cycles_left: u16 = 0,

    pub const byte_count: u16 = 0xa0;
    pub const cycles_per_byte: u16 = 4;
    pub const transfer_cycles: u16 = byte_count * cycles_per_byte;

    pub fn start(self: *Dma, value: u8) void {
        self.source_page = value;
        self.offset = 0;
        self.cycles_left = transfer_cycles;
    }

    pub fn active(self: *const Dma) bool {
        return self.cycles_left != 0;
    }

    // Reading FF46 returns the last page written.
    pub fn read(self: *const Dma) u8 {
        return self.source_page;
    }

    // Returns the source address of the byte for the next machine cycle
    // and advances the transfer. Returns null when the transfer is done.
    pub fn next(self: *Dma) ?u16 {
        if (!self.active()) return null;
        const address = @as(u16, self.source_page) << 8 | self.offset;
        self.offset += 1;
        self.cycles_left -= cycles_per_byte;
        return address;
    }
};

const std = @import("std");

test "a fresh controller is idle" {
    var dma = Dma{};
    try std.testing.expect(!dma.active());
    try std.testing.expectEqual(@as(?u16, null), dma.next());
    try std.testing.expectEqual(@as(u8, 0), dma.read());
}

test "start begins a full transfer" {
    var dma = Dma{};
    dma.start(0xc0);
    try std.testing.expect(dma.active());
    try std.testing.expectEqual(@as(u8, 0xc0), dma.read());
    var count: usize = 0;
    while (dma.next()) |address| {
        try std.testing.expectEqual(@as(u16, 0xc000) + @as(u16, @intCast(count)), address);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0xa0), count);
    try std.testing.expect(!dma.active());
}

test "restarting replaces an in-flight transfer" {
    var dma = Dma{};
    dma.start(0x80);
    _ = dma.next();
    dma.start(0x40);
    try std.testing.expectEqual(@as(u8, 0x40), dma.read());
    const first = dma.next();
    try std.testing.expectEqual(@as(u16, 0x4000), first);
}
