const Bus = @import("bus.zig").Bus;

// The SM83 CPU core.
//
// Registers start in the state left by the Game Boy boot ROM. The IME
// (interrupt master enable) flag becomes active one instruction after EI,
// matching the hardware delay. HALT wakes on a pending interrupt; with
// IME clear it resumes the following instruction without serving the
// interrupt.
pub const Cpu = struct {
    a: u8 = 0x01,
    f: u8 = 0xb0,
    b: u8 = 0x00,
    c: u8 = 0x13,
    d: u8 = 0x00,
    e: u8 = 0xd8,
    h: u8 = 0x01,
    l: u8 = 0x4d,
    sp: u16 = 0xfffe,
    pc: u16 = 0x0100,
    ime: bool = false,
    ei_pending: bool = false,
    halted: bool = false,

    const Z: u8 = 0x80;
    const N: u8 = 0x40;
    const H: u8 = 0x20;
    const C: u8 = 0x10;

    pub fn step(self: *Cpu, bus: *Bus) u16 {
        const enable_after = self.ei_pending;
        self.ei_pending = false;
        const pending = bus.pendingInterrupts();
        if (self.halted) {
            if (pending == 0) return self.finish(bus, 4, enable_after);
            self.halted = false;
        }
        if (self.ime and pending != 0) return self.serviceInterrupt(bus, pending);

        const opcode = self.fetch8(bus);
        if (opcode == 0xcb) return self.finish(bus, self.executeCb(bus), enable_after);
        if ((opcode & 0xc0) == 0x40 and opcode != 0x76) {
            const value = self.readReg(bus, @intCast(opcode & 7));
            self.writeReg(bus, @intCast((opcode >> 3) & 7), value);
            return self.finish(bus, if ((opcode & 7) == 6 or ((opcode >> 3) & 7) == 6) 8 else 4, enable_after);
        }
        if ((opcode & 0xc0) == 0x80) {
            const value = self.readReg(bus, @intCast(opcode & 7));
            self.alu(@intCast((opcode >> 3) & 7), value);
            return self.finish(bus, if ((opcode & 7) == 6) 8 else 4, enable_after);
        }
        const cycles = switch (opcode) {
            0x00 => 4,
            0x01 => self.loadPair(bus, 0),
            0x02 => self.writePair(bus, self.bc(), self.a),
            0x03 => self.incPair(0),
            0x04 => self.incReg(bus, 0),
            0x05 => self.decReg(bus, 0),
            0x06 => self.loadImmReg(bus, 0),
            0x07 => self.rotateA(0),
            0x08 => self.writeWord(bus),
            0x09 => self.addHl(self.bc()),
            0x0a => self.readA(bus, self.bc()),
            0x0b => self.decPair(0),
            0x0c => self.incReg(bus, 1),
            0x0d => self.decReg(bus, 1),
            0x0e => self.loadImmReg(bus, 1),
            0x0f => self.rotateA(1),
            0x10 => self.stop(),
            0x11 => self.loadPair(bus, 1),
            0x12 => self.writePair(bus, self.de(), self.a),
            0x13 => self.incPair(1),
            0x14 => self.incReg(bus, 2),
            0x15 => self.decReg(bus, 2),
            0x16 => self.loadImmReg(bus, 2),
            0x17 => self.rotateA(2),
            0x18 => self.jumpRelative(bus, true),
            0x19 => self.addHl(self.de()),
            0x1a => self.readA(bus, self.de()),
            0x1b => self.decPair(1),
            0x1c => self.incReg(bus, 3),
            0x1d => self.decReg(bus, 3),
            0x1e => self.loadImmReg(bus, 3),
            0x1f => self.rotateA(3),
            0x20 => self.jumpRelative(bus, (self.f & Z) == 0),
            0x21 => self.loadPair(bus, 2),
            0x22 => self.writePairInc(bus),
            0x23 => self.incPair(2),
            0x24 => self.incReg(bus, 4),
            0x25 => self.decReg(bus, 4),
            0x26 => self.loadImmReg(bus, 4),
            0x27 => self.daa(),
            0x28 => self.jumpRelative(bus, (self.f & Z) != 0),
            0x29 => self.addHl(self.hl()),
            0x2a => self.readAInc(bus),
            0x2b => self.decPair(2),
            0x2c => self.incReg(bus, 5),
            0x2d => self.decReg(bus, 5),
            0x2e => self.loadImmReg(bus, 5),
            0x2f => self.complement(),
            0x30 => self.jumpRelative(bus, (self.f & C) == 0),
            0x31 => self.loadPair(bus, 3),
            0x32 => self.writePairDec(bus),
            0x33 => self.incPair(3),
            0x34 => self.incReg(bus, 6),
            0x35 => self.decReg(bus, 6),
            0x36 => self.loadImmReg(bus, 6),
            0x37 => self.setCarry(),
            0x38 => self.jumpRelative(bus, (self.f & C) != 0),
            0x39 => self.addHl(self.sp),
            0x3a => self.readADec(bus),
            0x3b => self.decPair(3),
            0x3c => self.incReg(bus, 7),
            0x3d => self.decReg(bus, 7),
            0x3e => self.loadImmReg(bus, 7),
            0x3f => self.complementCarry(),
            0x76 => self.halt(),
            0xc0 => self.ret(bus, (self.f & Z) == 0),
            0xc1 => self.popPair(bus, 0),
            0xc2 => self.jump(bus, (self.f & Z) == 0),
            0xc3 => self.jumpAbsolute(bus),
            0xc4 => self.call(bus, (self.f & Z) == 0),
            0xc5 => self.pushPair(bus, self.bc()),
            0xc6 => self.addImmediate(bus, false),
            0xc7 => self.rst(bus, 0x00),
            0xc8 => self.ret(bus, (self.f & Z) != 0),
            0xc9 => self.returnAbsolute(bus),
            0xca => self.jump(bus, (self.f & Z) != 0),
            0xcc => self.call(bus, (self.f & Z) != 0),
            0xcd => self.call(bus, true),
            0xce => self.addImmediate(bus, true),
            0xcf => self.rst(bus, 0x08),
            0xd0 => self.ret(bus, (self.f & C) == 0),
            0xd1 => self.popPair(bus, 1),
            0xd2 => self.jump(bus, (self.f & C) == 0),
            0xd4 => self.call(bus, (self.f & C) == 0),
            0xd5 => self.pushPair(bus, self.de()),
            0xd6 => self.subImmediate(bus, false),
            0xd7 => self.rst(bus, 0x10),
            0xd8 => self.ret(bus, (self.f & C) != 0),
            0xd9 => self.reti(bus),
            0xda => self.jump(bus, (self.f & C) != 0),
            0xdc => self.call(bus, (self.f & C) != 0),
            0xde => self.subImmediate(bus, true),
            0xdf => self.rst(bus, 0x18),
            0xe0 => self.highWrite(bus),
            0xe1 => self.popPair(bus, 2),
            0xe2 => self.highWriteC(bus),
            0xe5 => self.pushPair(bus, self.hl()),
            0xe6 => self.andImmediate(bus),
            0xe7 => self.rst(bus, 0x20),
            0xe8 => self.addSp(bus),
            0xe9 => self.jumpHl(),
            0xea => self.writeWordAddress(bus),
            0xee => self.xorImmediate(bus),
            0xef => self.rst(bus, 0x28),
            0xf0 => self.highRead(bus),
            0xf1 => self.popPair(bus, 3),
            0xf2 => self.highReadC(bus),
            0xf3 => self.disableInterrupts(),
            0xf5 => self.pushPair(bus, self.af()),
            0xf6 => self.orImmediate(bus),
            0xf7 => self.rst(bus, 0x30),
            0xf8 => self.loadHlSp(bus),
            0xf9 => self.loadSpHl(),
            0xfa => self.readAbsolute(bus),
            0xfb => self.enableInterrupts(),
            0xfe => self.compareImmediate(bus),
            0xff => self.rst(bus, 0x38),
            else => 4,
        };
        return self.finish(bus, cycles, enable_after);
    }

    fn finish(self: *Cpu, bus: *Bus, cycles: u16, enable_after: bool) u16 {
        bus.tick(cycles);
        if (enable_after) self.ime = true;
        self.f &= 0xf0;
        return cycles;
    }

    fn serviceInterrupt(self: *Cpu, bus: *Bus, pending: u8) u16 {
        const bit: u3 = if ((pending & 1) != 0) 0 else if ((pending & 2) != 0) 1 else if ((pending & 4) != 0) 2 else if ((pending & 8) != 0) 3 else 4;
        bus.clearInterrupt(bit);
        self.ime = false;
        self.halted = false;
        self.push(bus, self.pc);
        self.pc = 0x40 + @as(u16, bit) * 8;
        return self.finish(bus, 20, false);
    }

    fn fetch8(self: *Cpu, bus: *Bus) u8 {
        const value = bus.read(self.pc);
        self.pc +%= 1;
        return value;
    }

    fn fetch16(self: *Cpu, bus: *Bus) u16 {
        const low = self.fetch8(bus);
        return @as(u16, low) | @as(u16, self.fetch8(bus)) << 8;
    }

    fn readReg(self: *Cpu, bus: *Bus, index: u3) u8 {
        return switch (index) {
            0 => self.b,
            1 => self.c,
            2 => self.d,
            3 => self.e,
            4 => self.h,
            5 => self.l,
            6 => bus.read(self.hl()),
            else => self.a,
        };
    }

    fn writeReg(self: *Cpu, bus: *Bus, index: u3, value: u8) void {
        switch (index) {
            0 => self.b = value,
            1 => self.c = value,
            2 => self.d = value,
            3 => self.e = value,
            4 => self.h = value,
            5 => self.l = value,
            6 => bus.write(self.hl(), value),
            else => self.a = value,
        }
    }

    fn loadImmReg(self: *Cpu, bus: *Bus, index: u3) u16 {
        self.writeReg(bus, index, self.fetch8(bus));
        return if (index == 6) 12 else 8;
    }

    fn incReg(self: *Cpu, bus: *Bus, index: u3) u16 {
        const old = self.readReg(bus, index);
        const value = old +% 1;
        self.writeReg(bus, index, value);
        self.f = (self.f & C) | (if (value == 0) Z else 0) | (if ((old & 0x0f) == 0x0f) H else 0);
        return if (index == 6) 12 else 4;
    }

    fn decReg(self: *Cpu, bus: *Bus, index: u3) u16 {
        const old = self.readReg(bus, index);
        const value = old -% 1;
        self.writeReg(bus, index, value);
        self.f = (self.f & C) | N | (if (value == 0) Z else 0) | (if ((old & 0x0f) == 0) H else 0);
        return if (index == 6) 12 else 4;
    }

    fn loadPair(self: *Cpu, bus: *Bus, pair_index: u2) u16 {
        self.setPair(pair_index, self.fetch16(bus));
        return 12;
    }

    fn incPair(self: *Cpu, pair_index: u2) u16 {
        self.setPair(pair_index, self.pair(pair_index) +% 1);
        return 8;
    }

    fn decPair(self: *Cpu, pair_index: u2) u16 {
        self.setPair(pair_index, self.pair(pair_index) -% 1);
        return 8;
    }

    fn pair(self: *const Cpu, pair_index: u2) u16 {
        return switch (pair_index) {
            0 => self.bc(),
            1 => self.de(),
            2 => self.hl(),
            else => self.sp,
        };
    }

    fn setPair(self: *Cpu, pair_index: u2, value: u16) void {
        switch (pair_index) {
            0 => {
                self.b = @truncate(value >> 8);
                self.c = @truncate(value);
            },
            1 => {
                self.d = @truncate(value >> 8);
                self.e = @truncate(value);
            },
            2 => {
                self.h = @truncate(value >> 8);
                self.l = @truncate(value);
            },
            else => self.sp = value,
        }
    }

    fn writePair(self: *Cpu, bus: *Bus, address: u16, value: u8) u16 {
        _ = self;
        bus.write(address, value);
        return 8;
    }

    fn writePairInc(self: *Cpu, bus: *Bus) u16 {
        bus.write(self.hl(), self.a);
        self.setPair(2, self.hl() +% 1);
        return 8;
    }

    fn writePairDec(self: *Cpu, bus: *Bus) u16 {
        bus.write(self.hl(), self.a);
        self.setPair(2, self.hl() -% 1);
        return 8;
    }

    fn readA(self: *Cpu, bus: *Bus, address: u16) u16 {
        self.a = bus.read(address);
        return 8;
    }

    fn readAInc(self: *Cpu, bus: *Bus) u16 {
        self.a = bus.read(self.hl());
        self.setPair(2, self.hl() +% 1);
        return 8;
    }

    fn readADec(self: *Cpu, bus: *Bus) u16 {
        self.a = bus.read(self.hl());
        self.setPair(2, self.hl() -% 1);
        return 8;
    }

    fn addHl(self: *Cpu, value: u16) u16 {
        const old = self.hl();
        const sum = @as(u32, old) + value;
        self.setPair(2, @truncate(sum));
        self.f = (self.f & Z) | (if ((old & 0x0fff) + (value & 0x0fff) > 0x0fff) H else 0) | (if (sum > 0xffff) C else 0);
        return 8;
    }

    fn rotateA(self: *Cpu, kind: u2) u16 {
        const old_carry: u8 = if ((self.f & C) != 0) 1 else 0;
        const carry: u8 = switch (kind) {
            0 => self.a >> 7,
            1 => self.a & 1,
            2 => self.a >> 7,
            else => self.a & 1,
        };
        self.a = switch (kind) {
            0 => (self.a << 1) | carry,
            1 => (self.a >> 1) | (carry << 7),
            2 => (self.a << 1) | old_carry,
            else => (self.a >> 1) | (old_carry << 7),
        };
        self.f = if (carry != 0) C else 0;
        return 4;
    }

    fn alu(self: *Cpu, operation: u3, value: u8) void {
        switch (operation) {
            0 => self.addA(value, false),
            1 => self.addA(value, true),
            2 => self.subA(value, false),
            3 => self.subA(value, true),
            4 => self.andA(value),
            5 => self.xorA(value),
            6 => self.orA(value),
            else => self.cp(value),
        }
    }

    fn addA(self: *Cpu, value: u8, with_carry: bool) void {
        const carry: u16 = if (with_carry and (self.f & C) != 0) 1 else 0;
        const sum = @as(u16, self.a) + value + carry;
        const half = @as(u16, self.a & 0x0f) + (value & 0x0f) + carry;
        self.a = @truncate(sum);
        self.f = (if (self.a == 0) Z else 0) | (if (half > 0x0f) H else 0) | (if (sum > 0xff) C else 0);
    }

    fn subA(self: *Cpu, value: u8, with_carry: bool) void {
        const carry: u16 = if (with_carry and (self.f & C) != 0) 1 else 0;
        const old = self.a;
        const result = @as(i16, old) - @as(i16, value) - @as(i16, @intCast(carry));
        const half = @as(i16, old & 0x0f) - @as(i16, value & 0x0f) - @as(i16, @intCast(carry));
        self.a = @truncate(@as(u16, @bitCast(result)));
        self.f = Z * @as(u8, if (self.a == 0) 1 else 0) | N | (if (half < 0) H else 0) | (if (result < 0) C else 0);
    }

    fn andA(self: *Cpu, value: u8) void {
        self.a &= value;
        self.f = (if (self.a == 0) Z else 0) | H;
    }

    fn xorA(self: *Cpu, value: u8) void {
        self.a ^= value;
        self.f = if (self.a == 0) Z else 0;
    }

    fn orA(self: *Cpu, value: u8) void {
        self.a |= value;
        self.f = if (self.a == 0) Z else 0;
    }

    fn cp(self: *Cpu, value: u8) void {
        const old = self.a;
        const result = @as(i16, old) - value;
        self.f = (if (@as(u8, @truncate(@as(u16, @bitCast(result)))) == 0) Z else 0) | N | (if ((old & 0x0f) < (value & 0x0f)) H else 0) | (if (result < 0) C else 0);
    }

    fn daa(self: *Cpu) u16 {
        var correction: u8 = 0;
        var carry = (self.f & C) != 0;
        if ((self.f & H) != 0 or (self.f & N) == 0 and (self.a & 0x0f) > 9) correction |= 0x06;
        if (carry or (self.f & N) == 0 and self.a > 0x99) {
            correction |= 0x60;
            carry = true;
        }
        self.a = if ((self.f & N) != 0) self.a -% correction else self.a +% correction;
        self.f = (self.f & N) | (if (self.a == 0) Z else 0) | (if (carry) C else 0);
        return 4;
    }

    fn jumpRelative(self: *Cpu, bus: *Bus, condition: bool) u16 {
        const offset: i8 = @bitCast(self.fetch8(bus));
        if (condition) {
            self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
            return 12;
        }
        return 8;
    }

    fn jump(self: *Cpu, bus: *Bus, condition: bool) u16 {
        const target = self.fetch16(bus);
        if (condition) {
            self.pc = target;
            return 16;
        }
        return 12;
    }

    fn jumpAbsolute(self: *Cpu, bus: *Bus) u16 {
        self.pc = self.fetch16(bus);
        return 16;
    }

    fn jumpHl(self: *Cpu) u16 {
        self.pc = self.hl();
        return 4;
    }

    fn call(self: *Cpu, bus: *Bus, condition: bool) u16 {
        const target = self.fetch16(bus);
        if (condition) {
            self.push(bus, self.pc);
            self.pc = target;
            return 24;
        }
        return 12;
    }

    fn ret(self: *Cpu, bus: *Bus, condition: bool) u16 {
        if (condition) {
            self.pc = self.pop(bus);
            return 20;
        }
        return 8;
    }

    fn returnAbsolute(self: *Cpu, bus: *Bus) u16 {
        self.pc = self.pop(bus);
        return 16;
    }

    fn reti(self: *Cpu, bus: *Bus) u16 {
        self.pc = self.pop(bus);
        self.ime = true;
        return 16;
    }

    fn rst(self: *Cpu, bus: *Bus, address: u16) u16 {
        self.push(bus, self.pc);
        self.pc = address;
        return 16;
    }

    fn push(self: *Cpu, bus: *Bus, value: u16) void {
        self.sp -%= 1;
        bus.write(self.sp, @truncate(value >> 8));
        self.sp -%= 1;
        bus.write(self.sp, @truncate(value));
    }

    fn pop(self: *Cpu, bus: *Bus) u16 {
        const low = bus.read(self.sp);
        self.sp +%= 1;
        const high = bus.read(self.sp);
        self.sp +%= 1;
        return @as(u16, low) | @as(u16, high) << 8;
    }

    fn popPair(self: *Cpu, bus: *Bus, pair_index: u2) u16 {
        const value = self.pop(bus);
        if (pair_index == 3) {
            self.a = @truncate(value >> 8);
            self.f = @as(u8, @truncate(value)) & 0xf0;
        } else {
            self.setPair(pair_index, value);
        }
        return 12;
    }

    fn pushPair(self: *Cpu, bus: *Bus, value: u16) u16 {
        self.push(bus, value);
        return 16;
    }

    fn writeWord(self: *Cpu, bus: *Bus) u16 {
        const address = self.fetch16(bus);
        bus.write(address, @truncate(self.sp));
        bus.write(address +% 1, @truncate(self.sp >> 8));
        return 20;
    }

    fn writeWordAddress(self: *Cpu, bus: *Bus) u16 {
        const address = self.fetch16(bus);
        bus.write(address, self.a);
        return 16;
    }

    fn highWrite(self: *Cpu, bus: *Bus) u16 {
        bus.write(@as(u16, 0xff00) + self.fetch8(bus), self.a);
        return 12;
    }

    fn highWriteC(self: *Cpu, bus: *Bus) u16 {
        bus.write(@as(u16, 0xff00) + self.c, self.a);
        return 8;
    }

    fn highRead(self: *Cpu, bus: *Bus) u16 {
        self.a = bus.read(@as(u16, 0xff00) + self.fetch8(bus));
        return 12;
    }

    fn highReadC(self: *Cpu, bus: *Bus) u16 {
        self.a = bus.read(@as(u16, 0xff00) + self.c);
        return 8;
    }

    fn readAbsolute(self: *Cpu, bus: *Bus) u16 {
        self.a = bus.read(self.fetch16(bus));
        return 16;
    }

    fn addImmediate(self: *Cpu, bus: *Bus, with_carry: bool) u16 {
        self.addA(self.fetch8(bus), with_carry);
        return 8;
    }

    fn subImmediate(self: *Cpu, bus: *Bus, with_carry: bool) u16 {
        self.subA(self.fetch8(bus), with_carry);
        return 8;
    }

    fn andImmediate(self: *Cpu, bus: *Bus) u16 {
        self.andA(self.fetch8(bus));
        return 8;
    }

    fn xorImmediate(self: *Cpu, bus: *Bus) u16 {
        self.xorA(self.fetch8(bus));
        return 8;
    }

    fn orImmediate(self: *Cpu, bus: *Bus) u16 {
        self.orA(self.fetch8(bus));
        return 8;
    }

    fn compareImmediate(self: *Cpu, bus: *Bus) u16 {
        self.cp(self.fetch8(bus));
        return 8;
    }

    fn addSp(self: *Cpu, bus: *Bus) u16 {
        const offset: i8 = @bitCast(self.fetch8(bus));
        const old = self.sp;
        const encoded: u16 = @bitCast(@as(i16, offset));
        const result = old +% encoded;
        self.sp = result;
        self.f = (if (((old ^ encoded ^ result) & 0x10) != 0) H else 0) | (if (((old ^ encoded ^ result) & 0x100) != 0) C else 0);
        return 16;
    }

    fn loadHlSp(self: *Cpu, bus: *Bus) u16 {
        const offset: i8 = @bitCast(self.fetch8(bus));
        const old = self.sp;
        const encoded: u16 = @bitCast(@as(i16, offset));
        const result = old +% encoded;
        self.setPair(2, result);
        self.f = (if (((old ^ encoded ^ result) & 0x10) != 0) H else 0) | (if (((old ^ encoded ^ result) & 0x100) != 0) C else 0);
        return 12;
    }

    fn loadSpHl(self: *Cpu) u16 {
        self.sp = self.hl();
        return 8;
    }

    fn stop(self: *Cpu) u16 {
        self.pc +%= 1;
        return 4;
    }

    fn halt(self: *Cpu) u16 {
        self.halted = true;
        return 4;
    }

    fn complement(self: *Cpu) u16 {
        self.a = ~self.a;
        self.f = (self.f & (Z | C)) | N | H;
        return 4;
    }

    fn setCarry(self: *Cpu) u16 {
        self.f = (self.f & Z) | C;
        return 4;
    }

    fn complementCarry(self: *Cpu) u16 {
        self.f = (self.f & Z) | (if ((self.f & C) == 0) C else 0);
        return 4;
    }

    fn disableInterrupts(self: *Cpu) u16 {
        self.ime = false;
        return 4;
    }

    fn enableInterrupts(self: *Cpu) u16 {
        self.ei_pending = true;
        return 4;
    }

    fn executeCb(self: *Cpu, bus: *Bus) u16 {
        const opcode = self.fetch8(bus);
        const group = opcode >> 6;
        const operation: u3 = @intCast((opcode >> 3) & 7);
        const index: u3 = @intCast(opcode & 7);
        var value = self.readReg(bus, index);
        if (group == 0) {
            const carry: u8 = switch (operation) {
                0 => value >> 7,
                1 => value & 1,
                2 => value >> 7,
                3 => value & 1,
                4 => value >> 7,
                5 => value & 1,
                6 => 0,
                else => value & 1,
            };
            value = switch (operation) {
                0 => (value << 1) | carry,
                1 => (value >> 1) | (carry << 7),
                2 => (value << 1) | (if ((self.f & C) != 0) @as(u8, 1) else 0),
                3 => (value >> 1) | (if ((self.f & C) != 0) @as(u8, 0x80) else 0),
                4 => value << 1,
                5 => (value >> 1) | (value & 0x80),
                6 => (value << 4) | (value >> 4),
                else => value >> 1,
            };
            self.f = (if (value == 0) Z else 0) | (if (carry != 0) C else 0);
            self.writeReg(bus, index, value);
        } else if (group == 1) {
            self.f = (self.f & C) | H | (if ((value & (@as(u8, 1) << operation)) == 0) Z else 0);
        } else if (group == 2) {
            value &= ~(@as(u8, 1) << operation);
            self.writeReg(bus, index, value);
        } else {
            value |= @as(u8, 1) << operation;
            self.writeReg(bus, index, value);
        }
        if (index == 6) return if (group == 1) 12 else 16;
        return 8;
    }

    fn bc(self: *const Cpu) u16 {
        return @as(u16, self.b) << 8 | self.c;
    }

    fn de(self: *const Cpu) u16 {
        return @as(u16, self.d) << 8 | self.e;
    }

    fn hl(self: *const Cpu) u16 {
        return @as(u16, self.h) << 8 | self.l;
    }

    fn af(self: *const Cpu) u16 {
        return @as(u16, self.a) << 8 | self.f;
    }
};

const std = @import("std");

test "POP AF restores A and masks the low nibble of F" {
    const allocator = std.testing.allocator;
    var rom = [_]u8{0} ** 0x8000;
    rom[0x0100] = 0xf1;
    var bus = try Bus.init(allocator, &rom);
    defer bus.deinit();
    var cpu = Cpu{};
    cpu.sp = 0xc000;
    bus.write(0xc000, 0x5b);
    bus.write(0xc001, 0xa3);
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u8, 0xa3), cpu.a);
    try std.testing.expectEqual(@as(u8, 0x50), cpu.f);
    try std.testing.expectEqual(@as(u16, 0xc002), cpu.sp);
}

test "POP AF does not disturb SP with a non-AF pair" {
    const allocator = std.testing.allocator;
    var rom = [_]u8{0} ** 0x8000;
    rom[0x0100] = 0xf1; // POP AF would corrupt SP in the old code
    var bus = try Bus.init(allocator, &rom);
    defer bus.deinit();
    var cpu = Cpu{};
    cpu.sp = 0xd000;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u16, 0xd002), cpu.sp);
    try std.testing.expectEqual(@as(u16, 0x0101), cpu.pc);
}
