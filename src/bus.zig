const Cartridge = @import("cartridge.zig").Cartridge;
const Ppu = @import("ppu.zig").Ppu;
const Timer = @import("timer.zig").Timer;

pub const Bus = struct {
    allocator: @import("std").mem.Allocator,
    cartridge: Cartridge,
    ppu: Ppu = .{},
    timer: Timer = .{},
    wram: [0x2000]u8 = [_]u8{0} ** 0x2000,
    hram: [0x7f]u8 = [_]u8{0} ** 0x7f,
    joypad: u8 = 0x30,
    dpad: u8 = 0x0f,
    buttons: u8 = 0x0f,
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
            0xff00 => blk: {
                const select = self.joypad & 0x30;
                const low: u8 = (if ((select & 0x10) == 0) self.dpad else 0x0f) & (if ((select & 0x20) == 0) self.buttons else 0x0f);
                break :blk 0xc0 | select | low;
            },
            0xff01 => self.sb,
            0xff02 => self.sc,
            0xff0f => self.iflag | 0xe0,
            0xff04...0xff07 => self.timer.read(address),
            0xff40...0xff4b => self.ppu.read(address),
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
            0xff00 => self.joypad = 0xc0 | (value & 0x30),
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
            0xff40...0xff4b => self.ppu.write(address, value),
            0xffff => self.ie = value,
            else => {},
        }
    }

    pub fn tick(self: *Bus, cycles: u16) void {
        self.timer.tick(cycles, &self.iflag);
        self.ppu.tick(cycles, &self.iflag);
    }

    pub fn pendingInterrupts(self: *const Bus) u8 {
        return self.iflag & self.ie & 0x1f;
    }

    pub fn clearInterrupt(self: *Bus, bit: u3) void {
        self.iflag &= ~(@as(u8, 1) << bit);
    }

    pub fn serialOutput(self: *const Bus) []const u8 {
        return self.serial[0..self.serial_len];
    }

    // Sets the joypad state. A cleared bit (0) means the button is pressed.
    // dpad bits: 0 right, 1 left, 2 up, 3 down.
    // button bits: 0 A, 1 B, 2 select, 3 start.
    pub fn setJoypad(self: *Bus, dpad: u8, buttons: u8) void {
        self.dpad = dpad & 0x0f;
        self.buttons = buttons & 0x0f;
    }
};

const std = @import("std");
const testing = std.testing;

test "joypad returns D-pad when selected" {
    const allocator = testing.allocator;
    const rom = [_]u8{0} ** 0x8000;
    var bus = try Bus.init(allocator, &rom);
    defer bus.deinit();
    bus.setJoypad(0x0b, 0x0f);
    bus.write(0xff00, 0x20);
    try testing.expectEqual(@as(u8, 0xeb), bus.read(0xff00));
}

test "joypad returns buttons when selected" {
    const allocator = testing.allocator;
    const rom = [_]u8{0} ** 0x8000;
    var bus = try Bus.init(allocator, &rom);
    defer bus.deinit();
    bus.setJoypad(0x0f, 0x07);
    bus.write(0xff00, 0x10);
    try testing.expectEqual(@as(u8, 0xd7), bus.read(0xff00));
}

test "joypad returns all released when nothing selected" {
    const allocator = testing.allocator;
    const rom = [_]u8{0} ** 0x8000;
    var bus = try Bus.init(allocator, &rom);
    defer bus.deinit();
    bus.setJoypad(0x00, 0x00);
    bus.write(0xff00, 0x30);
    try testing.expectEqual(@as(u8, 0xff), bus.read(0xff00));
}

test "serial captures bytes written with transfer bit set" {
    const allocator = testing.allocator;
    const rom = [_]u8{0} ** 0x8000;
    var bus = try Bus.init(allocator, &rom);
    defer bus.deinit();
    bus.write(0xff01, 'A');
    bus.write(0xff02, 0x81);
    bus.write(0xff01, 'B');
    bus.write(0xff02, 0x81);
    try testing.expectEqualStrings("AB", bus.serialOutput());
}
