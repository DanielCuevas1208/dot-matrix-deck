# Dot Matrix Deck

Dot Matrix Deck is a Game Boy emulator workbench written in Zig. It models the
SM83 CPU, the memory bus, timers, serial output, and the pixel pipeline. A
headless runner makes emulator behavior easy to inspect in scripts and CI.

## Current status

This project is under active development. The headless core is the most useful
entry point today. The SDL2 windowed frontend is available when SDL2 is
installed, but it is still being built out.

## Features

- SM83 CPU and instruction execution
- Memory bus with timer, serial, and pixel-processing components
- Headless ROM runner with cycle limits and serial verdicts
- Optional instruction trace output
- Small assembler tool for test ROM sources
- Deterministic unit tests for the emulator core and assembler

## Requirements

- Zig 0.16 or later
- SDL2 for the optional windowed frontend

The headless build does not require SDL2. On Windows, the build searches common
MSYS2 and vcpkg prefixes. You can also set `SDL2_DIR` or pass an SDL2 prefix.

## Build

Build the headless runner and assembler:

```text
zig build -Dsdl2=off
```

Build with the windowed frontend when SDL2 is available:

```text
zig build
```

## Run a ROM

Run a ROM without a window:

```text
zig build run-headless -- path/to/rom.gb
```

Useful options are `--max-cycles N`, `--trace`, and `--expect pass|fail|any`.
The runner prints serial output and returns a status from the detected verdict.

Run a ROM in the SDL2 frontend:

```text
zig build run -- path/to/rom.gb
```

## Test

Run the core and assembler tests:

```text
zig build test -Dsdl2=off
```

The repository also contains build steps for generated fixtures and the Blargg
CPU instruction suite. Add the required fixture files before using those steps.

## Project layout

- `src/cpu.zig` - SM83 CPU implementation
- `src/emulator.zig` - emulator composition and core tests
- `src/bus.zig` - memory and device routing
- `src/headless.zig` - command-line ROM runner
- `src/main.zig` - SDL2 frontend
- `tools/gbasm.zig` - small assembler for fixture ROMs

## Limitations

Hardware coverage is incomplete. Timing accuracy, cartridge support, audio,
and frontend features will improve as the project grows.

## License

No license file is published yet. Treat this repository as an experimental
project until a license is added.
