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
- Bundled demo, DMA, banking, MBC2, MBC3, MBC5, and SRAM ROMs that report PASS.
- Deterministic unit tests for every core module.
- Continuous integration on Ubuntu and Windows.

### Next

- Cycle-accurate timing for the timer and the PPU STAT modes.
- Serial link emulation between two emulator instances.
- Audio processing unit (APU).
- A debugger overlay for pause and reset.

## Known limits

- The core starts at the post-boot state. Boot ROM emulation is out of scope.
- The PPU has no window line counter edge cases yet.
- The SDL2 frontend ships without audio.
- Save files store external RAM only. The MBC3 real-time clock state is not persisted.
