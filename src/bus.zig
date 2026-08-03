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
    joypad: u8 = 0xcf,
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
            0xff00 => self.joypad,
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
            0xff00 => self.joypad = (self.joypad & 0xcf) | (value & 0x30),
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
};
