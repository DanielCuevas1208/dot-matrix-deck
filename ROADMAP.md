# Roadmap

This document tracks the work on Dot Matrix Deck.
It shows what is complete and what remains.

## Milestone 1: CPU core

Status: complete.

- SM83 CPU with all 256 opcodes
- CB prefix instructions
- Interrupt handling with IME timing
- HALT and STOP behavior
- Stack and register pair operations
- Verified by the blargg CPU instruction suite

## Milestone 2: Memory and timing

Status: complete.

- Full address map with WRAM, HRAM, and echoes
- Timer unit with DIV, TIMA, TMA, and TAC
- MBC1 mapper for banked ROM and RAM
- Serial link output for test verdicts
- Joypad input from the frontend

## Milestone 3: Pixel pipeline

Status: complete.

- LCD register file
- Background rendering with scrolling
- Sprite rendering with priority and palettes
- VBlank and STAT interrupts
- Deterministic frame checksums

## Milestone 4: Frontends

Status: complete.

- SDL2 windowed frontend
- Keyboard controls for the D-pad and buttons
- Headless runner with pass or fail verdicts
- Cartridge header display with the --info flag
- Instruction trace mode

## Milestone 5: Test infrastructure

Status: complete.

- Bundled smoke ROM assembled from source
- Deterministic rebuild check for the smoke ROM
- Golden frame checksum tests
- blargg CPU instruction suite, 11 of 11 passing
- GitHub Actions CI on Linux and Windows
- Formatting enforced by zig fmt

## Milestone 6: Audio and remaining hardware

Status: planned.

- APU and the four sound channels
- OAM DMA transfers
- Joypad interrupt
- Battery save to disk
- Additional mappers: MBC3 and MBC5

## Milestone 7: Accuracy and polish

Status: planned.

- Cycle-accurate STAT timing
- Boot ROM emulation
- Save state support
- Debugger integration
