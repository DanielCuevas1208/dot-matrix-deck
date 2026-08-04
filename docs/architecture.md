# Architecture

This page explains how the emulator is organized. It is a short guide,
not a full specification.

## Layers

The project has four layers.

1. The core emulator in `src/`.
2. The headless runner in `src/headless.zig`.
3. The windowed frontend in `src/frontend.zig` and `src/main.zig`.
4. The assembler and fixtures in `tools/` and `fixtures/`.

## The core

The core lives in `src/emulator.zig`. It ties the CPU and the bus
together. The CPU executes instructions. Each instruction ticks the bus.

The bus routes reads and writes. It connects the cartridge, the timer,
the serial port, the joypad, and the pixel pipeline. The bus lives in
`src/bus.zig`.

The pixel pipeline renders 160 by 144 pixels. It produces one frame per
display refresh. The pipeline lives in `src/ppu.zig`.

## The headless runner

`src/headless.zig` runs a ROM without a window. It steps the core until
a serial verdict appears. It prints the serial output and sets the exit
code from the verdict.

This runner powers the CI checks. It also runs the Blargg suites.

## The windowed frontend

`src/frontend.zig` opens an SDL2 window. Each loop iteration presents
one emulated frame. It reads the keyboard and writes the joypad.

`src/main.zig` loads the ROM and runs the loop. It exits when the user
closes the window or presses Escape.

## The assembler

`tools/gbasm.zig` assembles SM83 source text into a ROM image. The
output is deterministic. The fixtures step uses it to build the bundled
ROMs. The tests use it to build ROMs in memory.

## Data flow

A frame flows like this.

1. The frontend polls input.
2. The frontend writes the joypad.
3. The core steps the CPU.
4. The CPU ticks the bus.
5. The pixel pipeline fills the frame buffer.
6. The frontend shows the frame.

The headless runner skips the input and display steps.
