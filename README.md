# Dot Matrix Deck

Dot Matrix Deck is a Game Boy emulator written in Zig.
It models the SM83 CPU, the memory bus, the timers, and the pixel pipeline.
A software renderer shows the screen in an SDL2 window.
A headless mode runs public test ROMs for automated checks.

## Why it exists

This project is a workbench for learning the Game Boy hardware.
Every part of the machine is small and inspectable.
You can step through the CPU, read the trace, and watch frames render.

The bundled demo ROM shows the core working end to end.
It draws a title, scrolls the background, and bounces a dot.
It prints PASS over the serial port.
A build step verifies that output in one command.

## Architecture

The core splits into small modules with one job each.

- `src/cpu.zig` executes the SM83 instruction set.
- `src/bus.zig` routes memory between the devices.
- `src/timer.zig` models the game clock.
- `src/ppu.zig` renders background, sprites, and the window.
- `src/cartridge.zig` loads ROM-only and MBC1 images and banks their memory.
- `src/dma.zig` copies pages into OAM with the correct timing.
- `src/serial.zig` turns link-port bytes into test verdicts.
- `src/joypad.zig` reports button state through the FF00 register.
- `src/emulator.zig` ties the core together.
- `src/headless.zig` runs a ROM without a window.
- `src/main.zig` and `src/frontend.zig` form the SDL2 frontend.
- `tools/gbasm.zig` assembles SM83 test ROMs.

The frontend logic stays free of SDL2.
Unit tests cover that logic in headless builds.

The joypad uses the real register semantics.
The select bits are active-low.
A cleared bit selects a column.
The register returns the stored select bits when read.

## Requirements

You need Zig 0.16 or later.

The headless build needs no other tools.
The windowed frontend needs the SDL2 development library.
On Windows, the build searches common MSYS2 and vcpkg prefixes.
You can set `SDL2_DIR` to an SDL2 prefix.
You can also pass `-Dsdl2=<prefix>` on the build line.

## Setup

Fetch the source.

```text
git clone https://github.com/DanielCuevas1208/dot-matrix-deck.git
cd dot-matrix-deck
```

Build the headless tools.

```text
zig build -Dsdl2=off
```

Build the windowed frontend when SDL2 is installed.

```text
zig build
```

## Run the demo

Run the bundled demo and check its verdict.

```text
zig build run-demo -Dsdl2=off
```

Sample output:

```text
Serial output:
DOT MATRIX DECK
PASS
Verdict: pass
```

## Run a ROM

Run a ROM without a window.

```text
zig build run-headless -- path/to/rom.gb
```

Useful options are `--max-cycles N`, `--trace`, and `--expect pass|fail|any`.
The runner prints serial output and returns the verdict code.

Run a ROM in the SDL2 frontend.

```text
zig build run -- path/to/rom.gb
```

Keys: Z is A, X is B, Enter is Start, Shift is Select.
Arrows move the d-pad.
P pauses, R resets, F fast-forwards, ESC quits.

## Generate fixtures

Regenerate the bundled ROMs from their assembly sources.

```text
zig build fixtures -Dsdl2=off
```

Each `.asm` file in `fixtures/asm` becomes a `.gb` image in `fixtures/roms`.
The round-trip tests keep those images in sync.
The suite ships three ROMs:

- `demo` renders the title and prints PASS.
- `dma` copies a page into OAM and checks the result.
- `banking` switches MBC1 banks and checks each marker.

## Test

Run the whole suite.

```text
zig build test -Dsdl2=off
```

The suite covers the core, the assembler, and the bundled ROMs.
It also runs the blargg CPU suite when you add the ROMs.

```text
zig build test-blargg -Dsdl2=off
```

Add the blargg `cpu_instrs` ROMs under `fixtures/blargg` first.

## Project layout

- `src/` holds the emulator core and frontend.
- `tools/` holds the assembler.
- `fixtures/` holds the bundled ROMs and their sources.
- `.github/workflows/` holds the CI pipeline.

## Limitations

Hardware coverage is incomplete.
Timing accuracy, cartridge support, audio, and save games will improve.
The core starts at the post-boot state.
It does not emulate the boot ROM.

## License

This project is licensed under the MIT License.
See the LICENSE file for details.
