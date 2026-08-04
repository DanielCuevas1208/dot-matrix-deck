# Roadmap

This document tracks what the project delivers and what remains.

## Release 0.2

Release 0.2 makes the emulator a usable workbench. It adds input,
a windowed frontend, an assembler, and a bundled demo ROM.

### Done

- SM83 CPU with the full 256-opcode set and the CB prefix group.
- Memory bus with WRAM, HRAM, and hardware I/O registers.
- Timer with DIV, TIMA, TMA, and TAC.
- PPU with background maps, tile data, and sprite rendering.
- Cartridge support for ROM-only and MBC1 images.
- Headless ROM runner with cycle caps, traces, and verdicts.
- Joypad device with column selection and press-edge interrupts.
- SDL2 windowed frontend with a DMG-style shell and pause controls.
- SM83 assembler with labels, data directives, and expressions.
- Bundled demo ROM that draws a title and prints PASS.
- Deterministic unit tests for every core module.
- Continuous integration on Ubuntu and Windows.

### Next

- Cycle-accurate timing for the timer and the PPU STAT modes.
- MBC2, MBC3, and MBC5 cartridge support.
- Serial link emulation between two emulator instances.
- Audio processing unit (APU).
- Save game files and battery-backed RAM.
- Configurable key bindings for the windowed frontend.
- A debugger overlay for pause and reset.

## Known limits

- The core starts at the post-boot state. Boot ROM emulation is out of scope.
- The PPU has no window line counter edge cases yet.
- The SDL2 frontend ships without audio.
