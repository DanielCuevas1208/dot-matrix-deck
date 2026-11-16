pub const ScreenWidth = 160;
pub const ScreenHeight = 144;

pub const Ppu = struct {
    vram: [0x2000]u8 = [_]u8{0} ** 0x2000,
    oam: [0xa0]u8 = [_]u8{0} ** 0xa0,
    frame: [ScreenWidth * ScreenHeight]u32 = [_]u32{0xfff8f8f0} ** (ScreenWidth * ScreenHeight),
    lcdc: u8 = 0x91,
    stat: u8 = 0x85,
    scy: u8 = 0,
    scx: u8 = 0,
    ly: u8 = 0,
    lyc: u8 = 0,
    bgp: u8 = 0xfc,
    obp0: u8 = 0xff,
    obp1: u8 = 0xff,
    wy: u8 = 0,
    wx: u8 = 0,
    line_cycles: u16 = 0,
    mode: u8 = 2,
    window_line: u8 = 0,
    frame_ready: bool = false,
    stat_irq_line: bool = false,
    stat_irq_pending: bool = false,

    const shade = [_]u32{ 0xfff8f8f0, 0xffa8a8a0, 0xff505050, 0xff101010 };

    pub fn tick(self: *Ppu, cycles: u16, iflag: *u8) void {
        if ((self.lcdc & 0x80) == 0) {
            self.updateStatLine();
            self.deliverStatInterrupt(iflag);
            return;
        }
        var remaining = cycles;
        while (remaining != 0) : (remaining -= 1) {
            self.line_cycles += 1;
            const next_mode: u8 = if (self.ly >= ScreenHeight) 1 else if (self.line_cycles < 80) 2 else if (self.line_cycles < 252) 3 else 0;
            if (next_mode != self.mode) {
                self.mode = next_mode;
                if (next_mode == 0 and self.ly < ScreenHeight) self.renderLine();
            }
            if (self.line_cycles == 456) {
                self.line_cycles = 0;
                self.ly +%= 1;
                if (self.ly == ScreenHeight) {
                    self.frame_ready = true;
                    iflag.* |= 0x01;
                } else if (self.ly > 153) {
                    self.ly = 0;
                    self.window_line = 0;
                }
            }
            self.updateStatLine();
        }
        self.deliverStatInterrupt(iflag);
    }

    pub fn read(self: *const Ppu, address: u16) u8 {
        if (address >= 0x8000 and address < 0xa000) return self.vram[address - 0x8000];
        if (address >= 0xfe00 and address < 0xfea0) return self.oam[address - 0xfe00];
        return switch (address) {
            0xff40 => self.lcdc,
            0xff41 => (self.stat & 0x78) | 0x80 | (self.mode & 3) | (if (self.ly == self.lyc) @as(u8, 4) else 0),
            0xff42 => self.scy,
            0xff43 => self.scx,
            0xff44 => self.ly,
            0xff45 => self.lyc,
            0xff47 => self.bgp,
            0xff48 => self.obp0,
            0xff49 => self.obp1,
            0xff4a => self.wy,
            0xff4b => self.wx,
            else => 0xff,
        };
    }

    pub fn write(self: *Ppu, address: u16, value: u8) void {
        if (address >= 0x8000 and address < 0xa000) {
            self.vram[address - 0x8000] = value;
            return;
        }
        if (address >= 0xfe00 and address < 0xfea0) {
            self.oam[address - 0xfe00] = value;
            return;
        }
        switch (address) {
            0xff40 => {
                const old = self.lcdc;
                self.lcdc = value;
                if ((old & 0x80) == 0 and (value & 0x80) != 0) {
                    self.ly = 0;
                    self.line_cycles = 0;
                    self.mode = 2;
                    self.window_line = 0;
                    self.updateStatLine();
                } else if ((old & 0x80) != 0 and (value & 0x80) == 0) {
                    self.ly = 0;
                    self.line_cycles = 0;
                    self.mode = 0;
                    self.updateStatLine();
                }
            },
            0xff41 => {
                self.stat = value & 0x78;
                self.updateStatLine();
            },
            0xff42 => self.scy = value,
            0xff43 => self.scx = value,
            0xff45 => {
                self.lyc = value;
                self.updateStatLine();
            },
            0xff47 => self.bgp = value,
            0xff48 => self.obp0 = value,
            0xff49 => self.obp1 = value,
            0xff4a => self.wy = value,
            0xff4b => self.wx = value,
            else => {},
        }
    }

    pub fn takeFrame(self: *Ppu) bool {
        const ready = self.frame_ready;
        self.frame_ready = false;
        return ready;
    }

    // Returns and clears a STAT request caused by a register write. The bus
    // consumes this because Ppu.write has no interrupt-register argument.
    pub fn takeStatInterrupt(self: *Ppu) bool {
        const pending = self.stat_irq_pending;
        self.stat_irq_pending = false;
        return pending;
    }

    fn updateStatLine(self: *Ppu) void {
        const mode_enabled = switch (self.mode) {
            0 => (self.stat & 8) != 0,
            1 => (self.stat & 16) != 0,
            2 => (self.stat & 32) != 0,
            else => false,
        };
        const line = mode_enabled or ((self.stat & 0x40) != 0 and self.ly == self.lyc);
        if (line and !self.stat_irq_line) self.stat_irq_pending = true;
        self.stat_irq_line = line;
    }

    fn deliverStatInterrupt(self: *Ppu, iflag: *u8) void {
        if (self.takeStatInterrupt()) iflag.* |= 0x02;
    }

    fn renderLine(self: *Ppu) void {
        const y: usize = self.ly;
        const window_on_line = (self.lcdc & 0x20) != 0 and self.ly >= self.wy;
        var x: usize = 0;
        while (x < ScreenWidth) : (x += 1) {
            var color: u8 = 0;
            if ((self.lcdc & 1) != 0) {
                color = self.sampleBackgroundPixel(@intCast(x));
            }
            if (window_on_line) {
                if (self.sampleWindowPixel(@intCast(x))) |window_color| color = window_color;
            }
            const palette_index: usize = @intCast((self.bgp >> @intCast(color * 2)) & 3);
            self.frame[y * ScreenWidth + x] = shade[palette_index];
        }
        if (window_on_line) self.window_line +%= 1;
        if ((self.lcdc & 2) != 0) self.renderSprites();
    }

    fn sampleBackgroundPixel(self: *const Ppu, x: u8) u8 {
        const px: u8 = self.scx +% x;
        const py: u8 = self.scy +% self.ly;
        return self.sampleTilePixel(if ((self.lcdc & 8) != 0) 0x1c00 else 0x1800, px, py);
    }

    fn sampleWindowPixel(self: *const Ppu, x: u8) ?u8 {
        const wx_screen: i16 = @as(i16, self.wx) - 7;
        const px_i: i16 = @intCast(x);
        if (px_i < wx_screen) return null;
        const window_x: u8 = @intCast(px_i - wx_screen);
        return self.sampleTilePixel(if ((self.lcdc & 0x40) != 0) 0x1c00 else 0x1800, window_x, self.window_line);
    }

    fn sampleTilePixel(self: *const Ppu, map_base: usize, px: u8, py: u8) u8 {
        const tile = self.vram[map_base + @as(usize, py / 8) * 32 + @as(usize, px / 8)];
        const tile_offset: usize = if ((self.lcdc & 16) != 0) @as(usize, tile) * 16 else @intCast(0x1000 + @as(i16, @as(i8, @bitCast(tile))) * 16);
        const row: usize = @as(usize, py & 7) * 2;
        const lo = self.vram[tile_offset + row];
        const hi = self.vram[tile_offset + row + 1];
        const bit: u3 = @intCast(7 - (px & 7));
        return @intCast(((hi >> bit) & 1) * 2 + ((lo >> bit) & 1));
    }

    fn renderSprites(self: *Ppu) void {
        const line: i16 = self.ly;
        const height: i16 = if ((self.lcdc & 4) != 0) 16 else 8;
        var n: i16 = 39;
        while (n >= 0) : (n -= 1) {
            const index: usize = @intCast(n * 4);
            const sy: i16 = @as(i16, self.oam[index]) - 16;
            const sx: i16 = @as(i16, self.oam[index + 1]) - 8;
            if (line < sy or line >= sy + height) continue;
            var row: i16 = line - sy;
            const attr = self.oam[index + 3];
            if ((attr & 0x40) != 0) row = height - row - 1;
            const tile: usize = @as(usize, self.oam[index + 2] & (if (height == 16) @as(u8, 0xfe) else 0xff));
            const tile_row: usize = tile * 16 + @as(usize, @intCast(row)) * 2;
            const lo = self.vram[tile_row];
            const hi = self.vram[tile_row + 1];
            var col: i16 = 0;
            while (col < 8) : (col += 1) {
                const screen_x = sx + col;
                if (screen_x < 0 or screen_x >= ScreenWidth) continue;
                const source: u3 = @intCast(if ((attr & 0x20) != 0) 7 - col else col);
                const bit: u3 = 7 - source;
                const color = ((hi >> bit) & 1) * 2 + ((lo >> bit) & 1);
                if (color == 0) continue;
                const palette = if ((attr & 0x10) != 0) self.obp1 else self.obp0;
                const palette_index: usize = @intCast((palette >> @intCast(color * 2)) & 3);
                self.frame[@as(usize, @intCast(line)) * ScreenWidth + @as(usize, @intCast(screen_x))] = shade[palette_index];
            }
        }
    }
};

const testing = @import("std").testing;

test "LCD modes follow the scanline timing" {
    var ppu = Ppu{};
    var iflag: u8 = 0;

    ppu.tick(79, &iflag);
    try testing.expectEqual(@as(u8, 2), ppu.read(0xff41) & 3);
    ppu.tick(1, &iflag);
    try testing.expectEqual(@as(u8, 3), ppu.read(0xff41) & 3);
    ppu.tick(172, &iflag);
    try testing.expectEqual(@as(u8, 0), ppu.read(0xff41) & 3);
    ppu.tick(204, &iflag);
    try testing.expectEqual(@as(u8, 1), ppu.read(0xff44));
    try testing.expectEqual(@as(u8, 0), ppu.read(0xff41) & 3);
    ppu.tick(1, &iflag);
    try testing.expectEqual(@as(u8, 2), ppu.read(0xff41) & 3);
}

test "STAT requests an interrupt on each enabled rising edge" {
    var ppu = Ppu{};
    var iflag: u8 = 0;
    ppu.write(0xff41, 0x08); // Mode 0 source.

    ppu.tick(252, &iflag);
    try testing.expectEqual(@as(u8, 0x02), iflag & 0x02);
    iflag = 0;
    ppu.tick(100, &iflag);
    try testing.expectEqual(@as(u8, 0), iflag & 0x02);

    ppu.tick(104, &iflag); // Finish the line and enter mode 2.
    ppu.tick(80 + 172, &iflag);
    try testing.expectEqual(@as(u8, 0x02), iflag & 0x02);
}

test "LYC coincidence follows LY and LYC changes" {
    var ppu = Ppu{};
    var iflag: u8 = 0;
    ppu.write(0xff41, 0x40);
    ppu.tick(0, &iflag);
    try testing.expectEqual(@as(u8, 0x02), iflag & 0x02);

    iflag = 0;
    ppu.write(0xff45, 1);
    ppu.tick(0, &iflag);
    try testing.expectEqual(@as(u8, 0), iflag & 0x02);
    ppu.tick(456, &iflag);
    try testing.expectEqual(@as(u8, 0x02), iflag & 0x02);
}

test "window line counter increments only on visible window lines" {
    var ppu = Ppu{};
    ppu.write(0xff40, 0xa0); // LCD on, window enabled, background off.
    ppu.write(0xff4a, 10); // WY=10: scanlines 0-9 do not advance the counter.

    ppu.ly = 5;
    ppu.mode = 0;
    ppu.renderLine();
    try testing.expectEqual(@as(u8, 0), ppu.window_line);

    ppu.ly = 10;
    ppu.renderLine();
    try testing.expectEqual(@as(u8, 1), ppu.window_line);
}

test "window line counter resets at frame start and when the LCD turns on" {
    var ppu = Ppu{};
    ppu.write(0xff40, 0xa1);
    ppu.write(0xff4a, 0);
    ppu.window_line = 7;

    ppu.write(0xff40, 0x00);
    ppu.write(0xff40, 0xa1);
    try testing.expectEqual(@as(u8, 0), ppu.window_line);

    ppu.window_line = 5;
    ppu.ly = 153;
    ppu.line_cycles = 455;
    var iflag: u8 = 0;
    ppu.tick(1, &iflag);
    try testing.expectEqual(@as(u8, 0), ppu.ly);
    try testing.expectEqual(@as(u8, 0), ppu.window_line);
}

test "window layer draws over the background with a separate line counter" {
    var ppu = Ppu{};

    // Tile 0 is light (color 0). Tile 1 is dark (color 3).
    ppu.vram[0x10] = 0x00;
    ppu.vram[0x11] = 0xff;
    ppu.vram[0x20] = 0xff;
    ppu.vram[0x21] = 0xff;

    // Window map at $9800: row 0 uses tile 1, row 1 uses tile 0.
    ppu.vram[0x1800] = 1;
    ppu.vram[0x1820] = 0;

    ppu.write(0xff40, 0xb1); // LCD, bg, window, unsigned tiles, 9800 maps.
    ppu.write(0xff4a, 0);
    ppu.write(0xff4b, 7);

    // Line 4 uses window line 0 and draws a dark pixel from map row 0.
    ppu.ly = 4;
    ppu.mode = 0;
    ppu.renderLine();
    try testing.expectEqual(@as(u32, 0xff101010), ppu.frame[4 * ScreenWidth + 4]);

    // Line 12 uses window line 8 and draws a light pixel from map row 1.
    ppu.ly = 12;
    ppu.window_line = 8;
    ppu.renderLine();
    try testing.expectEqual(@as(u32, 0xfff8f8f0), ppu.frame[12 * ScreenWidth + 4]);
}
