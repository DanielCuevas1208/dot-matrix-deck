# Dot Matrix Deck

Dot Matrix Deck is a Game Boy emulator written in Zig.
It emulates the SM83 CPU, the memory bus, the timers, and the pixel pipeline.
The SDL2 frontend shows the screen in a window with a DMG-style shell.
A headless runner verifies the core with test ROMs.

## Features

- Full SM83 instruction set with the CB prefix group.
- Timer, joypad, and pixel-processing devices.
- SDL2 windowed frontend with a dot-matrix presentation.
- Headless ROM runner with cycle caps and serial verdicts.
- Small SM83 assembler for test ROM sources.
- Bundled demo ROM that draws a title and prints PASS.
- Deterministic unit tests for every core module.

## Requirements

- Zig 0.16 or later.
- SDL2 for the windowed frontend.

The headless tools do not need SDL2.
On Windows, the build searches MSYS2 and vcpkg prefixes.
Set `SDL2_DIR` to choose a prefix.

## Build

Build the headless tools:

```text
zig build -Dsdl2=off
```

Build the windowed frontend:

```text
zig build
```

## Test

Run all tests:

```text
zig build test -Dsdl2=off
```

Regenerate the bundled ROMs:

```text
zig build fixtures -Dsdl2=off
```

## Run

Run the bundled demo headlessly:

```text
zig build run-demo -Dsdl2=off
```

Run the demo in a window:

```text
zig build run -- fixtures/roms/demo.gb
```

Run any ROM headlessly:

```text
zig build run-headless -- path/to/rom.gb
```

Useful options are `--max-cycles N`, `--trace`, and `--expect pass|fail|any`.

## Sample output

This is the output of `zig build run-demo -Dsdl2=off`:

```text
Serial output:
DOT MATRIX DECK
PASS
Verdict: pass
```

## Window controls

| Key | Action |
| --- | --- |
| Arrow keys | D-pad |
| Z | A button |
| X | B button |
| Enter | Start |
| Shift | Select |
| P | Pause |
| R | Reset |
| F | Fast forward |
| ESC | Quit |

## Architecture

`src/emulator.zig` drives the run loop.
`src/bus.zig` routes reads and writes to the devices.
`src/cpu.zig` executes the SM83 instruction set.
`src/joypad.zig`, `src/timer.zig`, and `src/ppu.zig` model the hardware.
`src/serial.zig` decodes pass and fail verdicts.
`src/disasm.zig` formats instructions for the trace mode.
`src/frontend.zig` and `src/main.zig` form the SDL2 frontend.
`tools/gbasm.zig` assembles SM83 source into ROM images.

The frontend and the headless runner share the same core.
The core does not depend on SDL2.
All tests run without SDL2.

## Limitations

Hardware coverage is incomplete.
Timing accuracy is not cycle-perfect.
Cartridge support covers ROM-only and MBC1 images.
Audio is not implemented.
The frontend does not handle save files yet.

## Test status

The suite runs 68 checks.
It covers the CPU, timer, PPU, joypad, serial verdicts, and the assembler.
A round-trip test rebuilds the demo ROM and compares it byte for byte.
Continuous integration runs the suite on Ubuntu and Windows.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for what is done and what comes next.

## License

No license is published yet.
Treat this project as experimental.
