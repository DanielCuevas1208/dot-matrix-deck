//! End-to-end tests for the dot-matrix-deck core.
//!
//! These tests assemble small ROMs with gbasm, boot them in the
//! emulator, and check the serial verdict. Each ROM exercises a slice
//! of the full pipeline: CPU, memory bus, timers, serial output, and
//! the pixel pipeline, with no display required.

const std = @import("std");
const gbasm = @import("gbasm");
const Emulator = @import("emulator.zig").Emulator;
const serial = @import("serial.zig");
const joypad = @import("joypad.zig");
const ppu = @import("ppu.zig");

const boot_and_pass_source =
    \\    .org 0x0100
    \\    nop
    \\    jp start
    \\start:
    \\    ld sp, 0xfffe
    \\    ld hl, pass_text
    \\print_loop:
    \\    ld a, (hl)
    \\    or a
    \\    jr z, idle
    \\    ld (0xff01), a
    \\    ld a, 0x81
    \\    ld (0xff02), a
    \\    inc hl
    \\    jr print_loop
    \\idle:
    \\    jr idle
    \\pass_text:
    \\    .ascii "PASS"
    \\    .db 10, 0
;

const render_and_pass_source =
    \\    .org 0x0100
    \\    nop
    \\    jp start
    \\start:
    \\    ld sp, 0xfffe
    \\    ; Draw a solid tile into VRAM.
    \\    ld hl, 0x8000
    \\    ld b, 16
    \\tile_loop:
    \\    ld (hl), 0xff
    \\    inc hl
    \\    dec b
    \\    jr nz, tile_loop
    \\    ; Wait a few frames so the pixel pipeline renders.
    \\    ld b, 10
    \\frame_wait:
    \\    call wait_vblank
    \\    dec b
    \\    jr nz, frame_wait
    \\    ; Print PASS over the link port.
    \\    ld hl, pass_text
    \\print_loop:
    \\    ld a, (hl)
    \\    or a
    \\    jr z, idle
    \\    ld (0xff01), a
    \\    ld a, 0x81
    \\    ld (0xff02), a
    \\    inc hl
    \\    jr print_loop
    \\idle:
    \\    jr idle
    \\wait_vblank:
    \\    ld a, (0xff44)
    \\    cp 144
    \\    jr c, wait_vblank
    \\wait_active:
    \\    ld a, (0xff44)
    \\    cp 144
    \\    jr nc, wait_active
    \\    ret
    \\pass_text:
    \\    .ascii "PASS"
    \\    .db 10, 0
;

const joypad_source =
    \\    .org 0x0100
    \\    nop
    \\    jp start
    \\start:
    \\    ld sp, 0xfffe
    \\    xor a
    \\    ld (0xff00), a
    \\    ld a, (0xff00)
    \\    and 0x0f
    \\    ld (0xff01), a
    \\    ld a, 0x81
    \\    ld (0xff02), a
    \\idle:
    \\    jr idle
;

fn assemble(source: []const u8) ![]u8 {
    var diagnostics = std.ArrayList(gbasm.Diagnostics).empty;
    defer diagnostics.deinit(std.testing.allocator);
    return gbasm.assemble(std.testing.allocator, source, &diagnostics) catch |err| {
        for (diagnostics.items) |d| {
            std.debug.print("assemble line {d}: {s}\n", .{ d.line, d.message });
        }
        return err;
    };
}

// Runs the ROM until a serial verdict settles. Returns the verdict.
fn runToVerdict(image: []const u8) !serial.Verdict {
    var emulator = try Emulator.init(std.testing.allocator, image);
    defer emulator.deinit();

    var last_len: usize = 0;
    var silent: u64 = 0;
    var instructions: u64 = 0;
    const limit: u64 = 20_000_000;
    while (instructions < limit) : (instructions += 1) {
        _ = emulator.step();
        const output = emulator.serialOutput();
        if (output.len != last_len) {
            last_len = output.len;
            silent = 0;
        } else {
            silent += 1;
        }
        const verdict = serial.verdictOf(output);
        if (verdict != .pending and silent > 50_000) return verdict;
    }
    return .pending;
}

test "boot ROM reports PASS" {
    const image = try assemble(boot_and_pass_source);
    defer std.testing.allocator.free(image);
    try std.testing.expectEqual(serial.Verdict.pass, try runToVerdict(image));
}

test "rendered ROM reports PASS" {
    const image = try assemble(render_and_pass_source);
    defer std.testing.allocator.free(image);
    try std.testing.expectEqual(serial.Verdict.pass, try runToVerdict(image));
}

test "pixel pipeline produces a frame with a lit tile" {
    const image = try assemble(render_and_pass_source);
    defer std.testing.allocator.free(image);

    var emulator = try Emulator.init(std.testing.allocator, image);
    defer emulator.deinit();

    // Advance past the boot and tile write, into the render loop.
    emulator.runFrame(1_000_000);
    var any_dark = false;
    for (emulator.bus.ppu.frame) |pixel| {
        if (pixel != 0xfff8f8f0) {
            any_dark = true;
            break;
        }
    }
    try std.testing.expect(any_dark);
    try std.testing.expectEqual(@as(usize, 160), ppu.ScreenWidth);
    try std.testing.expectEqual(@as(usize, 144), ppu.ScreenHeight);
}

test "joypad reads flow through the bus" {
    const image = try assemble(joypad_source);
    defer std.testing.allocator.free(image);

    var emulator = try Emulator.init(std.testing.allocator, image);
    defer emulator.deinit();
    emulator.bus.setJoypadButtons(joypad.buttons.action_a | joypad.buttons.right);

    emulator.runInstructions(40);
    const output = emulator.serialOutput();
    try std.testing.expect(output.len != 0);
    try std.testing.expectEqual(@as(u8, 0x0e), output[0]);
}
