# Dot Matrix Deck

Dot Matrix Deck is a Game Boy emulator written in Zig.
It models the SM83 CPU, the memory bus, timers, serial output, and the pixel pipeline.
A software renderer shows the screen in an SDL2 window.
A headless mode runs test ROMs and reports pass or fail verdicts.

## What you can do

Run a game in a window with keyboard controls.
Run a test ROM without a window and read its serial verdict.
Inspect a cartridge header with the `--info` flag.
Disassemble instructions with the `--trace` flag.
Verify the CPU against the blargg instruction suite.

## Value of this project

The core is small and readable.
Every subsystem has deterministic tests.
The bundled smoke ROM proves the full pipeline works.
The blargg suite proves the CPU is correct.
CI rebuilds the ROMs from source and checks them byte for byte.

## Requirements

You need Zig 0.16 or later.
You need SDL2 for the windowed frontend only.
The headless build does not need SDL2.

On Windows, the build searches common MSYS2 and vcpkg prefixes.
You can set `SDL2_DIR` or pass an SDL2 prefix with `-Dsdl2`.

## Build

Build the headless runner and the assembler:

```text
zig build -Dsdl2=off
```

Build the windowed frontend when SDL2 is available:

```text
zig build
```

## Run a ROM

Run a ROM without a window:

```text
zig build run-headless -- path/to/rom.gb
```

Useful options are `--max-cycles N`, `--trace`, `--info`, and `--expect pass|fail|any`.
The runner prints the serial output.
The exit code follows the detected verdict.

Run a ROM in the SDL2 frontend:

```text
zig build run -- path/to/rom.gb
```

Controls: Z is B, X is A, Enter is Start, Backspace is Select, Arrows are the D-pad, Esc quits.

## Test

Run the core, assembler, and integration tests:

```text
zig build test -Dsdl2=off
```

Run the blargg CPU instruction suite:

```text
zig build test-blargg
```

Regenerate the bundled ROMs from their assembly sources:

```text
zig build fixtures
```

## Project layout

- `src/cpu.zig` - SM83 CPU implementation
- `src/bus.zig` - memory and device routing
- `src/ppu.zig` - pixel pipeline
- `src/timer.zig` - timer unit
- `src/cartridge.zig` - cartridge and header parsing
- `src/serial.zig` - serial output helpers
- `src/disasm.zig` - disassembler
- `src/emulator.zig` - emulator composition
- `src/headless.zig` - command-line ROM runner
- `src/main.zig` - SDL2 frontend
- `src/integration.zig` - end-to-end ROM tests
- `tools/gbasm.zig` - SM83 assembler for test ROMs
- `fixtures/` - bundled test ROMs and their sources

## Sample output

Run the bundled smoke ROM:

```text
$ zig build run-headless -- fixtures/roms/smoke.gb --max-cycles 5000000
Serial output:
PASS
Verdict: pass
```

Inspect a cartridge header:

```text
$ zig build run-headless -- fixtures/roms/smoke.gb --max-cycles 1000 --info
Title:  SMOKE TEST
Mapper: ROM only
ROM:    32 KiB
RAM:    0 KiB
CGB:    no
SGB:    no
Header: valid checksum
Global: $0000
```

## Limitations

Timing accuracy is incomplete.
Cartridge support covers ROM-only and MBC1 mappers.
Audio is not implemented.
The windowed frontend is a basic player; it has no menu bar or save states.

## License

Dot Matrix Deck is licensed under the MIT License.
See the LICENSE file for details.
The NOTICE file lists the third-party test ROMs used by the test suite.
