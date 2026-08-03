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

## Milestone 2: Memory and timing

Status: complete.

- Full address map with WRAM, HRAM, and echoes
- Timer unit with DIV, TIMA, TMA, and TAC
- MBC1 mapper for banked ROM and RAM
- Serial link output for test verdicts
- Joypad input with column selection

## Milestone 3: Pixel pipeline

Status: complete.

- LCD register file
- Background rendering with scrolling
- Sprite rendering with priority and palettes
- VBlank and STAT interrupts
- Deterministic frame output

## Milestone 4: Frontends

Status: complete.

- SDL2 windowed frontend with a software renderer
- Keyboard controls for the D-pad and buttons
- Headless runner with pass, fail, and any verdicts
- Cartridge header display with the --info flag
- Instruction trace mode

## Milestone 5: Test infrastructure

Status: complete.

- SM83 assembler with deterministic output
- Bundled smoke ROM assembled from source
- Integration tests that run the smoke ROM
- Deterministic rerun checks for the emulator
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

## External test ROMs

The headless runner supports the blargg cpu_instrs suite.
The ROMs are public test files and are not committed to this repository.
Copy them into `fixtures/blargg` and run `zig build test-blargg`.
