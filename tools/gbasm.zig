const std = @import("std");

// gbasm - an SM83 assembler for test ROM sources.
//
// It turns the small assembly dialect used by the bundled test ROMs into
// a Game Boy cartridge image. The build step "zig build fixtures" runs it
// over fixtures/assembler and writes the ROMs into fixtures/roms. The tests in
// src/integration.zig assemble the smoke ROM again and compare the output
// to the committed image byte for byte.
//
// Supported syntax:
//   org $0100          set the next address; the gap fills with $00
//   db 1, 2, 3         emit bytes from numbers or double-quoted strings
//   dw $1234           emit a 16-bit value, little endian
//   ds $10             emit N zero bytes
//   label:             define a label at the current address
//   instruction        the SM83 base set plus the CB prefix
//
// Literals use $ for hex, % for binary, or plain decimal. An operand may
// also be a label, or a label plus or minus a constant. The image always
// has the size of a 32 KiB cartridge. SM83 instruction sizes never depend
// on operand values, so pass one sizes the program and pass two encodes
// it with full knowledge of the labels.

const ImageSize: usize = 0x8000;

const Parsed = struct {
    mnemonic_buf: [8]u8,
    mnemonic_len: usize,
    operands: [3][]const u8,
    count: usize,

    fn mnemonic(self: *const Parsed) []const u8 {
        return self.mnemonic_buf[0..self.mnemonic_len];
    }

    fn operand(self: *const Parsed, index: usize) []const u8 {
        return self.operands[index];
    }
};

fn parseLine(line: []const u8) Parsed {
    var rest = std.mem.trimStart(u8, line, " \t");
    // Strip an inline comment: a semicolon outside a double-quoted string.
    {
        var in_quotes = false;
        for (rest, 0..) |ch, i| {
            if (ch == '"') in_quotes = !in_quotes;
            if (ch == ';' and !in_quotes) {
                rest = rest[0..i];
                rest = std.mem.trimEnd(u8, rest, " \t");
                break;
            }
        }
    }
    const word_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    var mnemonic_buf: [8]u8 = undefined;
    var mnemonic_len: usize = 0;
    for (rest[0..word_end]) |ch| {
        if (mnemonic_len < mnemonic_buf.len) {
            mnemonic_buf[mnemonic_len] = std.ascii.toUpper(ch);
            mnemonic_len += 1;
        }
    }
    rest = std.mem.trimStart(u8, rest[word_end..], " \t");

    var operands: [3][]const u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    var in_quotes = false;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        const at_end = i == rest.len;
        const ch = if (at_end) 0 else rest[i];
        if (ch == '"') in_quotes = !in_quotes;
        if ((at_end or ch == ',') and !in_quotes) {
            const operand = std.mem.trim(u8, rest[start..i], " \t");
            if (operand.len != 0 and count < operands.len) {
                operands[count] = operand;
                count += 1;
            }
            start = i + 1;
        }
    }
    return .{ .mnemonic_buf = mnemonic_buf, .mnemonic_len = mnemonic_len, .operands = operands, .count = count };
}
pub const Assembler = struct {
    allocator: std.mem.Allocator,
    image: []u8,
    symbols: std.StringHashMap(u16),
    message_buffer: [160]u8 = undefined,
    message_len: usize = 0,

    pub fn deinit(self: *Assembler) void {
        var it = self.symbols.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.symbols.deinit();
        self.allocator.free(self.image);
    }

    pub fn errorText(self: *const Assembler) ?[]const u8 {
        if (self.message_len == 0) return null;
        return self.message_buffer[0..self.message_len];
    }

    fn fail(self: *Assembler, comptime format: []const u8, args: anytype) void {
        if (self.message_len != 0) return;
        const text = std.fmt.bufPrint(&self.message_buffer, format, args) catch "assembly error";
        self.message_len = @min(text.len, self.message_buffer.len);
    }
    fn failAddress(self: *Assembler, address: usize) usize {
        self.fail("assembly error near ${X:0>4}", .{address});
        return address;
    }
    // Resolves an expression to a value. Numbers are $ hex, % binary, or
    // decimal. Labels may be followed by "+const" or "-const".
    fn evaluate(self: *Assembler, operand: []const u8) ?i32 {
        const text = std.mem.trim(u8, operand, " \t");
        if (text.len == 0) return null;
        var value: i64 = 0;
        var cursor: usize = 0;
        var sign: i64 = 1;
        if (text[0] == '+') {
            cursor = 1;
        } else if (text[0] == '-') {
            cursor = 1;
            sign = -1;
        }
        const first = text[cursor..];
        const first_term = self.parseTerm(first) orelse return null;
        value = sign * first_term;
        cursor += termLength(first);
        while (cursor < text.len) {
            const op = text[cursor];
            if (op != '+' and op != '-') return null;
            cursor += 1;
            const rest = text[cursor..];
            const term = self.parseTerm(rest) orelse return null;
            if (op == '-') value -= term else value += term;
            cursor += termLength(rest);
        }
        if (value < -0x8000 or value > 0xffff) return null;
        return @intCast(value);
    }

    fn parseTerm(self: *Assembler, text: []const u8) ?i64 {
        if (text.len == 0) return null;
        const end = std.mem.indexOfAny(u8, text, "+-") orelse text.len;
        const term = text[0..end];
        if (term.len == 0) return null;
        if (term[0] == '$') return std.fmt.parseInt(i64, term[1..], 16) catch null;
        if (term[0] == '%') return std.fmt.parseInt(i64, term[1..], 2) catch null;
        if (std.ascii.isDigit(term[0])) return std.fmt.parseInt(i64, term, 10) catch null;
        if (self.symbols.get(term)) |address| return address;
        return null;
    }

    fn termLength(text: []const u8) usize {
        return std.mem.indexOfAny(u8, text, "+-") orelse text.len;
    }
};

fn u8FromChar(ch: u8) ?u8 {
    return switch (std.ascii.toUpper(ch)) {
        'B' => 0,
        'C' => 1,
        'D' => 2,
        'E' => 3,
        'H' => 4,
        'L' => 5,
        'A' => 7,
        else => null,
    };
}

fn r16Code(text: []const u8) ?u2 {
    return if (std.ascii.eqlIgnoreCase(text, "BC")) 0 else if (std.ascii.eqlIgnoreCase(text, "DE")) 1 else if (std.ascii.eqlIgnoreCase(text, "HL")) 2 else if (std.ascii.eqlIgnoreCase(text, "SP")) 3 else null;
}

fn stackPairCode(text: []const u8) ?u2 {
    return if (std.ascii.eqlIgnoreCase(text, "BC")) 0 else if (std.ascii.eqlIgnoreCase(text, "DE")) 1 else if (std.ascii.eqlIgnoreCase(text, "HL")) 2 else if (std.ascii.eqlIgnoreCase(text, "AF")) 3 else null;
}

fn condCode(text: []const u8) ?u2 {
    return if (std.ascii.eqlIgnoreCase(text, "NZ")) 0 else if (std.ascii.eqlIgnoreCase(text, "Z")) 1 else if (std.ascii.eqlIgnoreCase(text, "NC")) 2 else if (std.ascii.eqlIgnoreCase(text, "C")) 3 else null;
}

fn isShift(m: []const u8) bool {
    return std.mem.eql(u8, m, "RLC") or std.mem.eql(u8, m, "RRC") or std.mem.eql(u8, m, "RL") or std.mem.eql(u8, m, "RR") or std.mem.eql(u8, m, "SLA") or std.mem.eql(u8, m, "SRA") or std.mem.eql(u8, m, "SWAP") or std.mem.eql(u8, m, "SRL");
}

fn shiftCode(m: []const u8) u8 {
    return if (std.mem.eql(u8, m, "RLC")) 0 else if (std.mem.eql(u8, m, "RRC")) 1 else if (std.mem.eql(u8, m, "RL")) 2 else if (std.mem.eql(u8, m, "RR")) 3 else if (std.mem.eql(u8, m, "SLA")) 4 else if (std.mem.eql(u8, m, "SRA")) 5 else if (std.mem.eql(u8, m, "SWAP")) 6 else 7;
}

fn isValidLabel(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

// Returns the number of bytes a line occupies, for the sizing pass.
fn lineSize(parsed: Parsed) usize {
    const m = parsed.mnemonic();
    if (std.mem.eql(u8, m, "ORG")) return 0;
    if (std.mem.eql(u8, m, "DS")) return 2;
    if (std.mem.eql(u8, m, "DW")) return parsed.count * 2;
    if (std.mem.eql(u8, m, "DB")) {
        var size: usize = 0;
        for (parsed.operands[0..parsed.count]) |operand| {
            if (operand.len >= 2 and operand[0] == '"') {
                size += operand.len - 2;
            } else {
                size += 1;
            }
        }
        return size;
    }
    if (std.mem.eql(u8, m, "STOP")) return 2;
    if (std.mem.eql(u8, m, "JR")) return 2;
    if (std.mem.eql(u8, m, "JP")) {
        // JP HL is a single-byte instruction.
        if (parsed.count == 1 and std.ascii.eqlIgnoreCase(parsed.operand(0), "HL")) return 1;
        return 3;
    }
    if (std.mem.eql(u8, m, "CALL")) return 3;
    if (std.mem.eql(u8, m, "LD")) {
        if (parsed.count != 2) return 0;
        const dest = parsed.operand(0);
        const src = parsed.operand(1);
        // 16-bit register load.
        if (r16Code(dest) != null) return 3;
        // Single-byte forms: register to register and the fixed memory
        // moves.
        if (dest.len == 1 and src.len == 1) return 1;
        if (dest.len == 1 and std.ascii.eqlIgnoreCase(src, "(HL)")) return 1;
        if (std.ascii.eqlIgnoreCase(dest, "(HL)") and src.len == 1) return 1;
        if (std.ascii.eqlIgnoreCase(dest, "A")) {
            if (std.ascii.eqlIgnoreCase(src, "(BC)") or std.ascii.eqlIgnoreCase(src, "(DE)") or std.ascii.eqlIgnoreCase(src, "(HL+)") or std.ascii.eqlIgnoreCase(src, "(HL-)") or std.ascii.eqlIgnoreCase(src, "(C)")) return 1;
            if (isMem16(src)) return 3;
        }
        if (std.ascii.eqlIgnoreCase(src, "A")) {
            if (std.ascii.eqlIgnoreCase(dest, "(BC)") or std.ascii.eqlIgnoreCase(dest, "(DE)") or std.ascii.eqlIgnoreCase(dest, "(HL+)") or std.ascii.eqlIgnoreCase(dest, "(HL-)") or std.ascii.eqlIgnoreCase(dest, "(C)")) return 1;
            if (isMem16(dest)) return 3;
        }
        if (std.ascii.eqlIgnoreCase(dest, "SP") and std.ascii.eqlIgnoreCase(src, "HL")) return 1;
        if (std.ascii.eqlIgnoreCase(dest, "HL") and std.ascii.eqlIgnoreCase(src, "SP")) return 2;
        return 2;
    }
    if (std.mem.eql(u8, m, "LDH")) return 2;
    if (isShift(m) or std.mem.eql(u8, m, "BIT") or std.mem.eql(u8, m, "RES") or std.mem.eql(u8, m, "SET")) return 2;
    if (std.mem.eql(u8, m, "ADD")) {
        if (parsed.count == 2 and std.ascii.eqlIgnoreCase(parsed.operand(0), "SP")) return 2;
        if (parsed.count == 2 and std.ascii.eqlIgnoreCase(parsed.operand(0), "HL")) return 1;
        if (parsed.count == 1 and parsed.operand(0).len == 1) return 1;
        if (parsed.count == 1 and std.ascii.eqlIgnoreCase(parsed.operand(0), "(HL)")) return 1;
        if (parsed.count == 2 and std.ascii.eqlIgnoreCase(parsed.operand(0), "A")) {
            const second = parsed.operand(1);
            if (second.len == 1 or std.ascii.eqlIgnoreCase(second, "(HL)")) return 1;
        }
        return 2;
    }
    if (std.mem.eql(u8, m, "ADC") or std.mem.eql(u8, m, "SUB") or std.mem.eql(u8, m, "SBC") or std.mem.eql(u8, m, "AND") or std.mem.eql(u8, m, "XOR") or std.mem.eql(u8, m, "OR") or std.mem.eql(u8, m, "CP")) {
        const operand = parsed.operand(parsed.count - 1);
        if (operand.len == 1 or std.ascii.eqlIgnoreCase(operand, "(HL)")) return 1;
        return 2;
    }
    return 1;
}

fn isMem16(text: []const u8) bool {
    if (text.len < 4) return false;
    if (text[0] != '(' or text[text.len - 1] != ')') return false;
    const body = text[1 .. text.len - 1];
    if (std.ascii.eqlIgnoreCase(body, "C")) return false;
    if (std.ascii.eqlIgnoreCase(body, "BC") or std.ascii.eqlIgnoreCase(body, "DE") or std.ascii.eqlIgnoreCase(body, "HL")) return false;
    return true;
}

fn stripMem(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '(' and text[text.len - 1] == ')') return text[1 .. text.len - 1];
    return text;
}

fn assemble(allocator: std.mem.Allocator, source: []const u8) !Assembler {
    var assembler = Assembler{
        .allocator = allocator,
        .image = try allocator.alloc(u8, ImageSize),
        .symbols = std.StringHashMap(u16).init(allocator),
    };
    errdefer assembler.deinit();
    @memset(assembler.image, 0);

    var address: usize = 0;

    // Pass one: collect labels and compute every address. `ds` needs the
    // count, so it is evaluated against the labels gathered so far.
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == ';') continue;
        var rest = line;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (isValidLabel(name)) {
                if (assembler.symbols.contains(name)) {
                    assembler.fail("duplicate label: {s}", .{name});
                    break;
                }
                try assembler.symbols.put(try allocator.dupe(u8, name), @intCast(address));
                rest = std.mem.trimStart(u8, line[colon + 1 ..], " \t");
                if (rest.len == 0) continue;
            }
        }
        if (rest.len >= 2 and (std.mem.startsWith(u8, rest, "org"))) {
            const arg = std.mem.trimStart(u8, rest["org".len..], " \t");
            const value = assembler.evaluate(arg) orelse {
                assembler.fail("bad org target", .{});
                break;
            };
            if (value < 0 or value >= ImageSize) {
                assembler.fail("org out of range", .{});
                break;
            }
            if (@as(usize, @intCast(value)) < address) {
                assembler.fail("org goes backwards", .{});
                break;
            }
            address = @intCast(value);
            continue;
        }
        const parsed = parseLine(rest);
        if (std.mem.eql(u8, parsed.mnemonic(), "DS")) {
            const count = assembler.evaluate(parsed.operand(0)) orelse {
                assembler.fail("bad ds count", .{});
                break;
            };
            if (count < 0 or count > 0xffff) {
                assembler.fail("ds count out of range", .{});
                break;
            }
            address += @as(usize, @intCast(count));
            continue;
        }
        address += lineSize(parsed);
        if (address > ImageSize) {
            assembler.fail("program past the end of the image", .{});
            break;
        }
    }

    // Pass two: encode every line with the labels resolved.
    if (assembler.errorText() == null) {
        address = 0;
        lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == ';') continue;
            var rest = line;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const name = std.mem.trim(u8, line[0..colon], " \t");
                if (isValidLabel(name)) {
                    rest = std.mem.trimStart(u8, line[colon + 1 ..], " \t");
                    if (rest.len == 0) continue;
                }
            }
            address = encodeLine(&assembler, address, rest);
            if (assembler.errorText() != null) break;
        }
    }

    return assembler;
}

// Encodes a single line and returns the new address.
fn encodeLine(assembler: *Assembler, address: usize, line: []const u8) usize {
    const parsed = parseLine(line);
    const m = parsed.mnemonic();
    var cursor = address;

    if (std.mem.eql(u8, m, "ORG")) {
        const value = assembler.evaluate(parsed.operand(0)) orelse return assembler.failAddress(0);
        return @intCast(value);
    }
    if (std.mem.eql(u8, m, "DB")) {
        for (parsed.operands[0..parsed.count]) |operand| {
            if (operand.len >= 2 and operand[0] == '"') {
                for (operand[1 .. operand.len - 1]) |byte| {
                    assembler.image[cursor] = byte;
                    cursor += 1;
                }
            } else {
                const value = assembler.evaluate(operand) orelse return assembler.failAddress(cursor);
                if (value < -0x80 or value > 0xff) return assembler.failAddress(cursor);
                assembler.image[cursor] = @truncate(@as(u32, @bitCast(value)));
                cursor += 1;
            }
        }
        return cursor;
    }
    if (std.mem.eql(u8, m, "DW")) {
        for (parsed.operands[0..parsed.count]) |operand| {
            const value = assembler.evaluate(operand) orelse return assembler.failAddress(cursor);
            if (value < 0 or value > 0xffff) return assembler.failAddress(cursor);
            const as_word: u16 = @intCast(value);
            assembler.image[cursor] = @truncate(as_word);
            assembler.image[cursor + 1] = @truncate(as_word >> 8);
            cursor += 2;
        }
        return cursor;
    }
    if (std.mem.eql(u8, m, "DS")) {
        const value = assembler.evaluate(parsed.operand(0)) orelse return assembler.failAddress(cursor);
        if (value < 0 or value > 0xffff) return assembler.failAddress(cursor);
        cursor += @as(usize, @intCast(value));
        return cursor;
    }

    // Instructions.
    if (std.mem.eql(u8, m, "NOP")) {
        return emit(assembler, cursor, 0x00);
    } else if (std.mem.eql(u8, m, "HALT")) {
        return emit(assembler, cursor, 0x76);
    } else if (std.mem.eql(u8, m, "STOP")) {
        cursor = emit(assembler, cursor, 0x10);
        return emit(assembler, cursor, 0x00);
    } else if (std.mem.eql(u8, m, "DI")) {
        return emit(assembler, cursor, 0xf3);
    } else if (std.mem.eql(u8, m, "EI")) {
        return emit(assembler, cursor, 0xfb);
    } else if (std.mem.eql(u8, m, "DAA")) {
        return emit(assembler, cursor, 0x27);
    } else if (std.mem.eql(u8, m, "CPL")) {
        return emit(assembler, cursor, 0x2f);
    } else if (std.mem.eql(u8, m, "SCF")) {
        return emit(assembler, cursor, 0x37);
    } else if (std.mem.eql(u8, m, "CCF")) {
        return emit(assembler, cursor, 0x3f);
    } else if (std.mem.eql(u8, m, "RETI")) {
        return emit(assembler, cursor, 0xd9);
    } else if (std.mem.eql(u8, m, "RET")) {
        if (parsed.count == 0) return emit(assembler, cursor, 0xc9);
        const cc = condCode(parsed.operand(0)) orelse return assembler.failAddress(cursor);
        return emit(assembler, cursor, 0xc0 | @as(u8, cc) << 3);
    } else if (std.mem.eql(u8, m, "JR")) {
        var cc: u2 = 0;
        var unconditional = false;
        var operand: []const u8 = undefined;
        if (parsed.count == 1) {
            operand = parsed.operand(0);
            unconditional = true;
        } else if (parsed.count == 2) {
            cc = condCode(parsed.operand(0)) orelse return assembler.failAddress(cursor);
            operand = parsed.operand(1);
        } else return assembler.failAddress(cursor);
        const target = assembler.evaluate(operand) orelse return assembler.failAddress(cursor);
        const offset = target - (@as(i32, @intCast(cursor)) + 2);
        if (offset < -128 or offset > 127) return assembler.failAddress(cursor);
        cursor = emit(assembler, cursor, if (unconditional) 0x18 else 0x20 | @as(u8, cc) << 3);
        return emit(assembler, cursor, @bitCast(@as(i8, @intCast(offset))));
    } else if (std.mem.eql(u8, m, "JP")) {
        if (parsed.count == 1 and std.ascii.eqlIgnoreCase(parsed.operand(0), "HL")) {
            return emit(assembler, cursor, 0xe9);
        }
        var cc: u2 = 0;
        var unconditional = false;
        var operand: []const u8 = undefined;
        if (parsed.count == 1) {
            operand = parsed.operand(0);
            unconditional = true;
        } else if (parsed.count == 2) {
            cc = condCode(parsed.operand(0)) orelse return assembler.failAddress(cursor);
            operand = parsed.operand(1);
        } else return assembler.failAddress(cursor);
        const target = assembler.evaluate(operand) orelse return assembler.failAddress(cursor);
        if (target < 0 or target > 0xffff) return assembler.failAddress(cursor);
        const word: u16 = @intCast(target);
        cursor = emit(assembler, cursor, if (unconditional) 0xc3 else 0xc2 | @as(u8, cc) << 3);
        cursor = emit(assembler, cursor, @truncate(word));
        return emit(assembler, cursor, @truncate(word >> 8));
    } else if (std.mem.eql(u8, m, "CALL")) {
        var cc: u2 = 0;
        var unconditional = false;
        var operand: []const u8 = undefined;
        if (parsed.count == 1) {
            operand = parsed.operand(0);
            unconditional = true;
        } else if (parsed.count == 2) {
            cc = condCode(parsed.operand(0)) orelse return assembler.failAddress(cursor);
            operand = parsed.operand(1);
        } else return assembler.failAddress(cursor);
        const target = assembler.evaluate(operand) orelse return assembler.failAddress(cursor);
        if (target < 0 or target > 0xffff) return assembler.failAddress(cursor);
        const word: u16 = @intCast(target);
        cursor = emit(assembler, cursor, if (unconditional) 0xcd else 0xc4 | @as(u8, cc) << 3);
        cursor = emit(assembler, cursor, @truncate(word));
        return emit(assembler, cursor, @truncate(word >> 8));
    } else if (std.mem.eql(u8, m, "RST")) {
        const target = assembler.evaluate(parsed.operand(0)) orelse return assembler.failAddress(cursor);
        if (target < 0 or target > 0x38 or (target & 7) != 0) return assembler.failAddress(cursor);
        return emit(assembler, cursor, 0xc7 | @as(u8, @intCast(target)));
    } else if (std.mem.eql(u8, m, "PUSH") or std.mem.eql(u8, m, "POP")) {
        const base: u8 = if (std.mem.eql(u8, m, "PUSH")) 0xc5 else 0xc1;
        const rr = stackPairCode(parsed.operand(0)) orelse return assembler.failAddress(cursor);
        return emit(assembler, cursor, base | @as(u8, rr) << 4);
    } else if (std.mem.eql(u8, m, "LD")) {
        return encodeLd(assembler, cursor, parsed);
    } else if (std.mem.eql(u8, m, "LDH")) {
        return encodeLdh(assembler, cursor, parsed);
    } else if (std.mem.eql(u8, m, "INC") or std.mem.eql(u8, m, "DEC")) {
        const base_8: u8 = if (std.mem.eql(u8, m, "INC")) 0x04 else 0x05;
        const base_16: u8 = if (std.mem.eql(u8, m, "INC")) 0x03 else 0x0b;
        const operand = parsed.operand(0);
        if (operand.len == 1) {
            if (u8FromChar(operand[0])) |r| return emit(assembler, cursor, base_8 | r << 3);
            return assembler.failAddress(cursor);
        }
        if (std.ascii.eqlIgnoreCase(operand, "(HL)")) return emit(assembler, cursor, base_8 | 6 << 3);
        if (r16Code(operand)) |rr| return emit(assembler, cursor, base_16 | @as(u8, rr) << 4);
        return assembler.failAddress(cursor);
    } else if (std.mem.eql(u8, m, "ADD")) {
        if (parsed.count == 2 and std.ascii.eqlIgnoreCase(parsed.operand(0), "HL")) {
            const rr = r16Code(parsed.operand(1)) orelse return assembler.failAddress(cursor);
            return emit(assembler, cursor, 0x09 | @as(u8, rr) << 4);
        }
        if (parsed.count == 2 and std.ascii.eqlIgnoreCase(parsed.operand(0), "SP")) {
            const value = assembler.evaluate(parsed.operand(1)) orelse return assembler.failAddress(cursor);
            if (value < -128 or value > 255) return assembler.failAddress(cursor);
            cursor = emit(assembler, cursor, 0xe8);
            return emit(assembler, cursor, @truncate(@as(u32, @bitCast(value))));
        }
        if (parsed.count == 1 or (parsed.count == 2 and std.ascii.eqlIgnoreCase(parsed.operand(0), "A"))) {
            return encodeAlu(assembler, cursor, 0, parsed);
        }
        return assembler.failAddress(cursor);
    } else if (std.mem.eql(u8, m, "ADC")) {
        return encodeAlu(assembler, cursor, 1, parsed);
    } else if (std.mem.eql(u8, m, "SUB")) {
        return encodeAlu(assembler, cursor, 2, parsed);
    } else if (std.mem.eql(u8, m, "SBC")) {
        return encodeAlu(assembler, cursor, 3, parsed);
    } else if (std.mem.eql(u8, m, "AND")) {
        return encodeAlu(assembler, cursor, 4, parsed);
    } else if (std.mem.eql(u8, m, "XOR")) {
        return encodeAlu(assembler, cursor, 5, parsed);
    } else if (std.mem.eql(u8, m, "OR")) {
        return encodeAlu(assembler, cursor, 6, parsed);
    } else if (std.mem.eql(u8, m, "CP")) {
        return encodeAlu(assembler, cursor, 7, parsed);
    } else if (isShift(m)) {
        const op = shiftCode(m);
        const operand = parsed.operand(0);
        var r: u8 = undefined;
        if (operand.len == 1) {
            r = u8FromChar(operand[0]) orelse return assembler.failAddress(cursor);
        } else if (std.ascii.eqlIgnoreCase(operand, "(HL)")) {
            r = 6;
        } else return assembler.failAddress(cursor);
        cursor = emit(assembler, cursor, 0xcb);
        return emit(assembler, cursor, op << 3 | r);
    } else if (std.mem.eql(u8, m, "BIT") or std.mem.eql(u8, m, "RES") or std.mem.eql(u8, m, "SET")) {
        if (parsed.count != 2) return assembler.failAddress(cursor);
        const bit = assembler.evaluate(parsed.operand(0)) orelse return assembler.failAddress(cursor);
        if (bit < 0 or bit > 7) return assembler.failAddress(cursor);
        const operand = parsed.operand(1);
        var r: u8 = undefined;
        if (operand.len == 1) {
            r = u8FromChar(operand[0]) orelse return assembler.failAddress(cursor);
        } else if (std.ascii.eqlIgnoreCase(operand, "(HL)")) {
            r = 6;
        } else return assembler.failAddress(cursor);
        const base: u8 = if (std.mem.eql(u8, m, "BIT")) 0x40 else if (std.mem.eql(u8, m, "RES")) 0x80 else 0xc0;
        cursor = emit(assembler, cursor, 0xcb);
        return emit(assembler, cursor, base | @as(u8, @intCast(bit)) << 3 | r);
    }
    assembler.fail("unknown mnemonic: {s}", .{m});
    return cursor;
}

fn emit(assembler: *Assembler, address: usize, byte: u8) usize {
    if (address >= ImageSize) {
        assembler.fail("output past the end of the image", .{});
        return address;
    }
    assembler.image[address] = byte;
    return address + 1;
}

fn encodeAlu(assembler: *Assembler, cursor: usize, op: u8, parsed: Parsed) usize {
    const operand = parsed.operand(parsed.count - 1);
    if (operand.len == 1) {
        if (u8FromChar(operand[0])) |r| return emit(assembler, cursor, 0x80 | op << 3 | r);
        return assembler.failAddress(cursor);
    }
    if (std.ascii.eqlIgnoreCase(operand, "(HL)")) return emit(assembler, cursor, 0x80 | op << 3 | 6);
    const value = assembler.evaluate(operand) orelse return assembler.failAddress(cursor);
    if (value < -0x80 or value > 0xff) return assembler.failAddress(cursor);
    const next = emit(assembler, cursor, 0xc6 | op << 3);
    return emit(assembler, next, @truncate(@as(u32, @bitCast(value))));
}

fn encodeLd(assembler: *Assembler, cursor: usize, parsed: Parsed) usize {
    if (parsed.count != 2) return assembler.failAddress(cursor);
    const dest = parsed.operand(0);
    const src = parsed.operand(1);

    // LD A,(BC) / (DE) / (nn) / (HL) / (HL+) / (HL-) / (C)
    if (std.ascii.eqlIgnoreCase(dest, "A") and (src.len > 2 and src[0] == '(')) {
        if (std.ascii.eqlIgnoreCase(src, "(BC)")) return emit(assembler, cursor, 0x0a);
        if (std.ascii.eqlIgnoreCase(src, "(DE)")) return emit(assembler, cursor, 0x1a);
        if (std.ascii.eqlIgnoreCase(src, "(HL)")) return emit(assembler, cursor, 0x7e);
        if (std.ascii.eqlIgnoreCase(src, "(HL+)")) return emit(assembler, cursor, 0x2a);
        if (std.ascii.eqlIgnoreCase(src, "(HL-)")) return emit(assembler, cursor, 0x3a);
        if (std.ascii.eqlIgnoreCase(src, "(C)")) return emit(assembler, cursor, 0xf2);
        if (isMem16(src)) {
            const value = assembler.evaluate(stripMem(src)) orelse return assembler.failAddress(cursor);
            if (value < 0 or value > 0xffff) return assembler.failAddress(cursor);
            const word: u16 = @intCast(value);
            const b = emit(assembler, cursor, 0xfa);
            const w = emit(assembler, b, @truncate(word));
            return emit(assembler, w, @truncate(word >> 8));
        }
        return assembler.failAddress(cursor);
    }
    // LD (BC),A / (DE),A / (HL+),A / (HL-),A / (nn),A
    if (src.len == 1 and u8FromChar(src[0]) == 7 and (dest.len > 2 and dest[0] == '(')) {
        if (std.ascii.eqlIgnoreCase(dest, "(BC)")) return emit(assembler, cursor, 0x02);
        if (std.ascii.eqlIgnoreCase(dest, "(DE)")) return emit(assembler, cursor, 0x12);
        if (std.ascii.eqlIgnoreCase(dest, "(HL)")) return emit(assembler, cursor, 0x77);
        if (std.ascii.eqlIgnoreCase(dest, "(HL+)")) return emit(assembler, cursor, 0x22);
        if (std.ascii.eqlIgnoreCase(dest, "(HL-)")) return emit(assembler, cursor, 0x32);
        if (isMem16(dest)) {
            const value = assembler.evaluate(stripMem(dest)) orelse return assembler.failAddress(cursor);
            if (value < 0 or value > 0xffff) return assembler.failAddress(cursor);
            const word: u16 = @intCast(value);
            const b = emit(assembler, cursor, 0xea);
            const w = emit(assembler, b, @truncate(word));
            return emit(assembler, w, @truncate(word >> 8));
        }
        return assembler.failAddress(cursor);
    }
    // LD r,r ; LD r,n ; LD r,(HL)
    if (dest.len == 1) {
        const d = u8FromChar(dest[0]) orelse return assembler.failAddress(cursor);
        if (src.len == 1) {
            const s = u8FromChar(src[0]) orelse return assembler.failAddress(cursor);
            return emit(assembler, cursor, 0x40 | d << 3 | s);
        }
        if (std.ascii.eqlIgnoreCase(src, "(HL)")) return emit(assembler, cursor, 0x40 | d << 3 | 6);
        const value = assembler.evaluate(src) orelse return assembler.failAddress(cursor);
        if (value < -0x80 or value > 0xff) return assembler.failAddress(cursor);
        const next = emit(assembler, cursor, 0x06 | d << 3);
        return emit(assembler, next, @truncate(@as(u32, @bitCast(value))));
    }
    // LD (HL),r ; LD (HL),n
    if (std.ascii.eqlIgnoreCase(dest, "(HL)")) {
        if (src.len == 1) {
            const s = u8FromChar(src[0]) orelse return assembler.failAddress(cursor);
            return emit(assembler, cursor, 0x70 | s);
        }
        const value = assembler.evaluate(src) orelse return assembler.failAddress(cursor);
        if (value < -0x80 or value > 0xff) return assembler.failAddress(cursor);
        const next = emit(assembler, cursor, 0x36);
        return emit(assembler, next, @truncate(@as(u32, @bitCast(value))));
    }
    // LD rr,nn
    if (r16Code(dest)) |rr| {
        const value = assembler.evaluate(src) orelse return assembler.failAddress(cursor);
        if (value < 0 or value > 0xffff) return assembler.failAddress(cursor);
        const word: u16 = @intCast(value);
        const b = emit(assembler, cursor, 0x01 | @as(u8, rr) << 4);
        const w = emit(assembler, b, @truncate(word));
        return emit(assembler, w, @truncate(word >> 8));
    }
    // LD SP,HL ; LD HL,SP+e
    if (std.ascii.eqlIgnoreCase(dest, "SP") and std.ascii.eqlIgnoreCase(src, "HL")) return emit(assembler, cursor, 0xf9);
    if (std.ascii.eqlIgnoreCase(dest, "HL") and std.ascii.eqlIgnoreCase(src, "SP")) {
        // LD HL,SP+e requires an explicit + or - offset.
        const value = assembler.evaluate(src) orelse return assembler.failAddress(cursor);
        if (value < -128 or value > 255) return assembler.failAddress(cursor);
        const b = emit(assembler, cursor, 0xf8);
        return emit(assembler, b, @truncate(@as(u32, @bitCast(value))));
    }
    return assembler.failAddress(cursor);
}

fn encodeLdh(assembler: *Assembler, cursor: usize, parsed: Parsed) usize {
    if (parsed.count != 2) return assembler.failAddress(cursor);
    const dest = parsed.operand(0);
    const src = parsed.operand(1);
    if (std.ascii.eqlIgnoreCase(dest, "A")) {
        if (std.ascii.eqlIgnoreCase(src, "(C)")) return emit(assembler, cursor, 0xf2);
        const value = assembler.evaluate(stripMem(src)) orelse return assembler.failAddress(cursor);
        if (value < 0 or value > 0xff) return assembler.failAddress(cursor);
        const byte: u8 = @intCast(value);
        const b = emit(assembler, cursor, 0xf0);
        return emit(assembler, b, byte);
    }
    if (std.ascii.eqlIgnoreCase(dest, "(C)") and src.len == 1 and u8FromChar(src[0]) == 7) return emit(assembler, cursor, 0xe2);
    const value = assembler.evaluate(stripMem(dest)) orelse return assembler.failAddress(cursor);
    if (value < 0 or value > 0xff) return assembler.failAddress(cursor);
    const byte: u8 = @intCast(value);
    const b = emit(assembler, cursor, 0xe0);
    return emit(assembler, b, byte);
}

// Public entry point used by the integration tests.
pub fn assembleSource(allocator: std.mem.Allocator, source: []const u8) !Assembler {
    return assemble(allocator, source);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const buffer = try allocator.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    const file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

fn usage(program: []const u8) void {
    std.debug.print(
        \\gbasm - SM83 assembler for test ROMs
        \\Usage:
        \\  {s} <input-directory> <output-directory>
        \\
        \\Assembles every .asm file in the input directory and writes the
        \\matching .gb image into the output directory.
        \\
    , .{program});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| {
        try args.append(allocator, arg);
    }
    const argv = args.items;

    if (argv.len < 3) {
        usage(argv[0]);
        std.process.exit(2);
    }

    const input_dir = argv[1];
    const output_dir = argv[2];

    var dir = try std.Io.Dir.cwd().openDir(io, input_dir, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".asm")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var failures: usize = 0;
    for (names.items) |name| {
        const base = name[0 .. name.len - 4];
        const output_name = try std.fmt.allocPrint(allocator, "{s}.gb", .{base});
        defer allocator.free(output_name);
        const input_path = try std.fs.path.join(allocator, &.{ input_dir, name });
        defer allocator.free(input_path);
        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_name });
        defer allocator.free(output_path);

        const source = readFile(io, allocator, input_path) catch |err| {
            std.debug.print("{s}: read error {s}\n", .{ name, @errorName(err) });
            failures += 1;
            continue;
        };
        defer allocator.free(source);

        var assembler = assemble(allocator, source) catch |err| {
            std.debug.print("{s}: error {s}\n", .{ name, @errorName(err) });
            failures += 1;
            continue;
        };
        defer assembler.deinit();
        if (assembler.errorText()) |message| {
            std.debug.print("{s}: {s}\n", .{ name, message });
            failures += 1;
            continue;
        }
        writeFile(io, output_path, assembler.image) catch |err| {
            std.debug.print("{s}: write error {s}\n", .{ name, @errorName(err) });
            failures += 1;
            continue;
        };
        std.debug.print("{s}: {d} bytes\n", .{ name, assembler.image.len });
        allocator.free(name);
    }

    std.process.exit(if (failures == 0) 0 else 1);
}

test "assembler encodes the entry point and a jump" {
    const allocator = std.testing.allocator;
    const source =
        \\    org $0100
        \\    nop
        \\    jp start
        \\start:
        \\    ld a, $05
        \\    ret
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.errorText() == null);
    try std.testing.expectEqual(@as(u8, 0x00), assembler.image[0x0100]);
    try std.testing.expectEqual(@as(u8, 0xc3), assembler.image[0x0101]);
    try std.testing.expectEqual(@as(u8, 0x04), assembler.image[0x0102]);
    try std.testing.expectEqual(@as(u8, 0x01), assembler.image[0x0103]);
    try std.testing.expectEqual(@as(u8, 0x3e), assembler.image[0x0104]);
    try std.testing.expectEqual(@as(u8, 0x05), assembler.image[0x0105]);
}

test "assembler supports data directives" {
    const allocator = std.testing.allocator;
    const source =
        \\    org $0000
        \\    db $12, $34
        \\    dw $abcd
        \\    ds 2
        \\    db "HI", $00
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.errorText() == null);
    try std.testing.expectEqual(@as(u8, 0x12), assembler.image[0]);
    try std.testing.expectEqual(@as(u8, 0x34), assembler.image[1]);
    try std.testing.expectEqual(@as(u8, 0xcd), assembler.image[2]);
    try std.testing.expectEqual(@as(u8, 0xab), assembler.image[3]);
    try std.testing.expectEqual(@as(u8, 0x00), assembler.image[4]);
    try std.testing.expectEqual(@as(u8, 0x00), assembler.image[5]);
    try std.testing.expectEqual(@as(u8, 'H'), assembler.image[6]);
    try std.testing.expectEqual(@as(u8, 'I'), assembler.image[7]);
}

test "assembler computes relative branches" {
    const allocator = std.testing.allocator;
    const source =
        \\    org $0100
        \\    jr skip
        \\    nop
        \\skip:
        \\    halt
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.errorText() == null);
    try std.testing.expectEqual(@as(u8, 0x18), assembler.image[0x0100]);
    try std.testing.expectEqual(@as(u8, 0x01), assembler.image[0x0101]);
}

test "assembler detects a duplicate label" {
    const allocator = std.testing.allocator;
    const source =
        \\    org $0100
        \\dup:
        \\    nop
        \\dup:
        \\    halt
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.errorText() != null);
}

test "assembler encodes the CB prefix" {
    const allocator = std.testing.allocator;
    const source =
        \\    org $0100
        \\    sla a
        \\    bit 1, a
        \\    res 7, (hl)
        \\    set 0, b
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.errorText() == null);
    try std.testing.expectEqual(@as(u8, 0xcb), assembler.image[0x0100]);
    try std.testing.expectEqual(@as(u8, 0x27), assembler.image[0x0101]);
    try std.testing.expectEqual(@as(u8, 0xcb), assembler.image[0x0102]);
    try std.testing.expectEqual(@as(u8, 0x4f), assembler.image[0x0103]);
    try std.testing.expectEqual(@as(u8, 0xcb), assembler.image[0x0104]);
    try std.testing.expectEqual(@as(u8, 0xbe), assembler.image[0x0105]);
    try std.testing.expectEqual(@as(u8, 0xcb), assembler.image[0x0106]);
    try std.testing.expectEqual(@as(u8, 0xc0), assembler.image[0x0107]);
}

test "assembler rejects a bad mnemonic" {
    const allocator = std.testing.allocator;
    const source =
        \\    org $0100
        \\    frob a, $12
    ;
    var assembler = try assembleSource(allocator, source);
    defer assembler.deinit();
    try std.testing.expect(assembler.errorText() != null);
}
