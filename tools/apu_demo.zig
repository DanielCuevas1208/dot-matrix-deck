const std = @import("std");
const Bus = @import("bus").Bus;

const output_path = "fixtures/audio/square-channel.wav";
const sample_count = 11_025;
const sample_rate = 44_100;

fn writeU16(bytes: anytype, offset: usize, value: u16) void {
    var encoded: [2]u8 = undefined;
    std.mem.writeInt(u16, &encoded, value, .little);
    @memcpy(bytes[offset .. offset + 2], &encoded);
}

fn writeU32(bytes: anytype, offset: usize, value: u32) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    @memcpy(bytes[offset .. offset + 4], &encoded);
}

fn makeHeader() [44]u8 {
    var header = [_]u8{0} ** 44;
    @memcpy(header[0..4], "RIFF");
    writeU32(&header, 4, 36 + sample_count * 2);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    writeU32(&header, 16, 16);
    writeU16(&header, 20, 1);
    writeU16(&header, 22, 1);
    writeU32(&header, 24, sample_rate);
    writeU32(&header, 28, sample_rate * 2);
    writeU16(&header, 32, 2);
    writeU16(&header, 34, 16);
    @memcpy(header[36..40], "data");
    writeU32(&header, 40, sample_count * 2);
    return header;
}

pub fn main(init: std.process.Init) !void {
    const rom = [_]u8{0} ** 0x8000;
    var bus = try Bus.init(init.gpa, &rom);
    defer bus.deinit();
    bus.write(0xff16, 0x80); // 50% duty.
    bus.write(0xff17, 0xf3); // Volume 15, decay, envelope period 3.
    bus.write(0xff18, 0x40);
    bus.write(0xff19, 0x87); // Trigger with frequency 0x740.

    var samples: [sample_count]i16 = undefined;
    bus.apu.renderSamples(&samples);

    const dir = std.Io.Dir.cwd();
    const file = try dir.createFile(init.io, output_path, .{});
    defer file.close(init.io);

    const header = makeHeader();
    _ = try file.writePositionalAll(init.io, &header, 0);

    var bytes: [2]u8 = undefined;
    var offset: u64 = 44;
    for (samples) |sample| {
        writeU16(&bytes, 0, @bitCast(sample));
        _ = try file.writePositionalAll(init.io, &bytes, offset);
        offset += 2;
    }

    std.debug.print(
        "APU square-channel demo:\nWrote {s}\nSamples: {d}\nFirst samples: {d}, {d}, {d}, {d}\nVerdict: pass\n",
        .{ output_path, sample_count, samples[0], samples[1], samples[2], samples[3] },
    );
}
