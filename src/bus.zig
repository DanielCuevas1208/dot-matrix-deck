const Cartridge = @import("cartridge.zig").Cartridge;
const Dma = @import("dma.zig").Dma;
const Joypad = @import("joypad.zig").Joypad;
const Ppu = @import("ppu.zig").Ppu;
const Timer = @import("timer.zig").Timer;

pub const Bus = struct {
    allocator: @import("std").mem.Allocator,
    cartridge: Cartridge,
    dma: Dma = .{},
    joypad: Joypad = .{},
    ppu: Ppu = .{},
    timer: Timer = .{},
    wram: [0x2000]u8 = [_]u8{0} ** 0x2000,
    hram: [0x7f]u8 = [_]u8{0} ** 0x7f,
    sb: u8 = 0,
    sc: u8 = 0,
    iflag: u8 = 0xe1,
    ie: u8 = 0,
    serial: [4096]u8 = [_]u8{0} ** 4096,
    serial_len: usize = 0,

    pub fn init(allocator: @import("std").mem.Allocator, rom: []const u8) !Bus {
        return .{ .allocator = allocator, .cartridge = try Cartridge.init(allocator, rom) };
    }

    pub fn deinit(self: *Bus) void {
        self.cartridge.deinit();
    }

    pub fn read(self: *Bus, address: u16) u8 {
        if (address < 0x8000 or (address >= 0xa000 and address < 0xc000)) return self.cartridge.read(address);
        if (address >= 0x8000 and address < 0xa000) return self.ppu.read(address);
        if (address >= 0xc000 and address < 0xe000) return self.wram[address - 0xc000];
        if (address >= 0xe000 and address < 0xfe00) return self.wram[address - 0xe000];
        if (address >= 0xfe00 and address < 0xfea0) return self.ppu.read(address);
        if (address >= 0xff80 and address < 0xffff) return self.hram[address - 0xff80];
        return switch (address) {
            0xff00 => self.joypad.read(),
            0xff01 => self.sb,
            0xff02 => self.sc,
            0xff0f => self.iflag | 0xe0,
            0xff04...0xff07 => self.timer.read(address),
            0xff40...0xff45 => self.ppu.read(address),
            0xff46 => self.dma.read(),
            0xff47...0xff4b => self.ppu.read(address),
            0xffff => self.ie,
            else => 0xff,
        };
    }

    pub fn write(self: *Bus, address: u16, value: u8) void {
        if (address < 0x8000 or (address >= 0xa000 and address < 0xc000)) {
            self.cartridge.write(address, value);
            return;
        }
        if (address >= 0x8000 and address < 0xa000) {
            self.ppu.write(address, value);
            return;
        }
        if (address >= 0xc000 and address < 0xe000) {
            self.wram[address - 0xc000] = value;
            return;
        }
        if (address >= 0xe000 and address < 0xfe00) {
            self.wram[address - 0xe000] = value;
            return;
        }
        if (address >= 0xfe00 and address < 0xfea0) {
            self.ppu.write(address, value);
            return;
        }
        if (address >= 0xff80 and address < 0xffff) {
            self.hram[address - 0xff80] = value;
            return;
        }
        switch (address) {
            0xff00 => self.joypad.write(value),
            0xff01 => self.sb = value,
            0xff02 => {
                self.sc = value;
                if ((value & 0x81) == 0x81) {
                    if (self.serial_len < self.serial.len) {
                        self.serial[self.serial_len] = self.sb;
                        self.serial_len += 1;
                    }
                    self.iflag |= 0x08;
                    self.sc = 0x01;
                }
            },
            0xff0f => self.iflag = value & 0x1f,
            0xff04...0xff07 => self.timer.write(address, value),
            0xff40...0xff45 => self.ppu.write(address, value),
            0xff46 => self.dma.start(value),
            0xff47...0xff4b => self.ppu.write(address, value),
            0xffff => self.ie = value,
            else => {},
        }
    }

    pub fn tick(self: *Bus, cycles: u16) void {
        self.timer.tick(cycles, &self.iflag);
        self.ppu.tick(cycles, &self.iflag);
    }

    // Runs one DMA machine cycle. Copies one byte from the source page
    // into OAM and advances the timer and PPU. Returns cycles consumed.
    pub fn dmaStep(self: *Bus) u16 {
        const source = self.dma.next() orelse return 0;
        const index = self.dma.offset - 1;
        self.ppu.oam[index] = self.read(source);
        self.timer.tick(Dma.cycles_per_byte, &self.iflag);
        self.ppu.tick(Dma.cycles_per_byte, &self.iflag);
        return Dma.cycles_per_byte;
    }

    pub fn pendingInterrupts(self: *const Bus) u8 {
        return self.iflag & self.ie & 0x1f;
    }

    pub fn clearInterrupt(self: *Bus, bit: u3) void {
        self.iflag &= ~(@as(u8, 1) << bit);
    }

    // A button press edge raises the joypad interrupt (IF bit 4).
    pub fn setButton(self: *Bus, bit: Joypad.Button, pressed: bool) void {
        const was_pressed = self.joypad.isButtonPressed(bit);
        self.joypad.setButton(bit, pressed);
        if (pressed and !was_pressed) self.iflag |= 0x10;
    }

    // A direction press edge raises the joypad interrupt (IF bit 4).
    pub fn setDirection(self: *Bus, bit: Joypad.Direction, pressed: bool) void {
        const was_pressed = self.joypad.isDirectionPressed(bit);
        self.joypad.setDirection(bit, pressed);
        if (pressed and !was_pressed) self.iflag |= 0x10;
    }

    pub fn serialOutput(self: *const Bus) []const u8 {
        return self.serial[0..self.serial_len];
    }
};

const testing = @import("std").testing;

test "joypad reads the selected button column" {
    const rom = [_]u8{0} ** 0x8000;
    var bus = try Bus.init(testing.allocator, &rom);
    defer bus.deinit();
    bus.write(0xff00, 0x10); // bit 5 low selects the buttons column.
    bus.setButton(Joypad.Button.a, true);
    try testing.expectEqual(@as(u8, 0x0e), bus.read(0xff00) & 0x0f);
}

test "joypad press edge raises the joypad interrupt" {
    const rom = [_]u8{0} ** 0x8000;
    var bus = try Bus.init(testing.allocator, &rom);
    defer bus.deinit();
    bus.write(0xff00, 0x20); // bit 4 low selects the D-pad column.
    bus.setDirection(Joypad.Direction.right, true);
    try testing.expectEqual(@as(u8, 0x10), bus.iflag & 0x10);
    bus.setDirection(Joypad.Direction.right, false);
    bus.setDirection(Joypad.Direction.right, true);
    try testing.expectEqual(@as(u8, 0x10), bus.iflag & 0x10);
}

test "DMA transfers a WRAM page into OAM" {
    const rom = [_]u8{0} ** 0x8000;
    var bus = try Bus.init(testing.allocator, &rom);
    defer bus.deinit();
    for (0..Dma.byte_count) |i| {
        bus.write(0xc000 + @as(u16, @intCast(i)), @intCast(i & 0xff));
    }
    bus.write(0xff46, 0xc0);
    try testing.expectEqual(@as(u8, 0xc0), bus.read(0xff46));
    var steps: u32 = 0;
    while (bus.dma.active()) : (steps += 1) {
        try testing.expectEqual(@as(u16, 4), bus.dmaStep());
    }
    try testing.expectEqual(@as(u32, 160), steps);
    for (0..Dma.byte_count) |i| {
        try testing.expectEqual(@as(u8, @intCast(i & 0xff)), bus.read(0xfe00 + @as(u16, @intCast(i))));
    }
}

test "DMA register reads back the last source page" {
    const rom = [_]u8{0} ** 0x8000;
    var bus = try Bus.init(testing.allocator, &rom);
    defer bus.deinit();
    bus.write(0xff46, 0x80);
    try testing.expectEqual(@as(u8, 0x80), bus.read(0xff46));
    while (bus.dma.active()) _ = bus.dmaStep();
    try testing.expectEqual(@as(u8, 0x80), bus.read(0xff46));
}
