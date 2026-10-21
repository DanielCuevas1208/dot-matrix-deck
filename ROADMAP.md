# Roadmap

This document tracks what the project delivers and what remains.

## Release 0.2

Release 0.2 makes the emulator a usable workbench. It adds input,
DMA, cartridge banking, an assembler, save data, and bundled test ROMs.
The listed 0.2 scope is complete.

### Done

- SM83 CPU with the full 256-opcode set and the CB prefix group.
- Memory bus with WRAM, HRAM, and hardware I/O registers.
- Timer with DIV, TIMA, TMA, and TAC.
- PPU with background maps, tile data, and sprite rendering.
- Cartridge support for ROM-only, MBC1, MBC2, MBC3, and MBC5 images.
- OAM DMA with cycle-accurate CPU blocking.
- Headless ROM runner with cycle caps, traces, and verdicts.
- Joypad device with active-low column selection and visible falling-edge interrupts.
- MBC3 real-time clock with halt, latch, and BCD seconds.
- Battery-backed RAM saves for the headless runner and the windowed frontend.
- SDL2 windowed frontend with a DMG-style shell and pause controls.
- Configurable key bindings for the windowed frontend via a `dmd.keys.conf` file.
- SM83 assembler with labels, data directives, and expressions.
- Bundled demo, DMA, joypad, banking, MBC2, MBC3, MBC5, and SRAM ROMs that report PASS.
- Deterministic unit tests for every core module.
- Continuous integration on Ubuntu and Windows.

### Release evidence

- `zig build test -Dsdl2=off` checks 158 deterministic tests.
- `zig build run-demo -Dsdl2=off` checks the bundled demo verdict.
- `zig build run-headless -Dsdl2=off -- fixtures/roms/joypad.gb --expect pass` checks FF00 behavior.
- `zig build run-headless -Dsdl2=off -- fixtures/roms/timer.gb --expect pass` checks timer overflow behavior.

### Continued by Release 0.3

The timing work continues in the release below.

## Release 0.3: timing slice

The timing slice is complete.
It makes timer edges, delayed reloads, scanline modes, and STAT requests observable.

### Done

- Timer increments from divider falling edges at all four TAC frequencies.
- DIV and TAC writes apply their falling-edge effects.
- TIMA overflow exposes zero during the four-cycle reload delay.
- Writing TIMA cancels a pending overflow reload.
- PPU mode timing covers the 456 T-cycles in each scanline.
- STAT requests use rising edges for mode and LYC coincidence sources.
- Bundled timer ROM checks the overflow interrupt flag.
- The suite reports 158 deterministic tests.

## Release 0.4: connectivity slice

The connectivity slice is complete.
It adds a deterministic byte-level link between two emulator instances.

### Done

- Public `Emulator.connectSerial` and `disconnectSerial` APIs.
- Internal-clock and armed external-clock byte exchanges.
- Paired ROM fixtures that verify both received marker bytes.
- A headless link demo with a readable pass verdict.
- CI coverage for every bundled ROM and the link demo.

### Release evidence

- `zig build test-fixtures -Dsdl2=off` checks 11 bundled ROM verdicts.
- `zig build run-link-demo -Dsdl2=off` checks both received marker bytes.

### Continued by Release 0.5

The audio slice is complete below.
The debugger remains planned in the future milestones.

## Release 0.5: audio slice

Status: complete.

### Milestone: `apu-square-channel`

User-visible outcome: the headless workbench renders one deterministic Game Boy audio channel.

Bounded deliverable: implement channel 2 registers, duty timing, length control, volume envelope, and WAV rendering.

Acceptance criteria:

- Implement one square-wave channel with documented register and envelope behavior.
- Render a headless WAV fixture before adding live playback.
- Test register transitions and sample values with deterministic checks.

### Done

- Added `src/apu.zig` with channel 2 register masks and NR52 power state.
- Advanced the APU through CPU and DMA cycles on the memory bus.
- Added integer-clock 44.1 kHz signed PCM rendering.
- Added the 0.25-second `fixtures/audio/square-channel.wav` fixture.
- Added a headless audio demo with a readable pass verdict.

### Release evidence

- `zig build test -Dsdl2=off` checks 170 deterministic tests.
- `zig build run-apu-demo -Dsdl2=off` regenerates the WAV fixture.
- CI compares the regenerated WAV bytes with the committed fixture.

## Future milestones

### Milestone: `debugger-breakpoints`

Status: planned.

User-visible outcome: inspect CPU execution from a reproducible headless debugger session.

Bounded deliverable: add address breakpoints, stepping, register inspection, and an optional SDL2 overlay.

Acceptance criteria:

- Pause at an address breakpoint in a bundled ROM.
- Resume execution and report CPU registers.
- Expose the same state in the optional overlay.

Verification: `zig build test -Dsdl2=off` plus a dedicated debugger fixture command.

### Milestone: `ppu-window-edge-cases`

Status: planned.

User-visible outcome: render window layers with correct line-counter edge behavior.

Bounded deliverable: model window line progression and add a focused ROM fixture.

Acceptance criteria:

- Increment the window line only when the window draws a visible line.
- Reset the line counter at frame start.
- Verify the result with a bundled headless ROM.

Verification: `zig build test-fixtures -Dsdl2=off`.

## Known limits

- The core starts at the post-boot state. Boot ROM emulation is out of scope.
- The PPU has no window line counter edge cases yet.
- The SDL2 frontend ships without live audio playback.
- Only channel 2 has audio output.
- Save files store external RAM only. The MBC3 real-time clock state is not persisted.
- Serial links complete at byte boundaries. Bit-level clock timing is not modeled.
