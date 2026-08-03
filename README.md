# Dot Matrix Deck

Dot Matrix Deck is a Game Boy emulator written in Zig.
It emulates the SM83 CPU, the memory bus, the timers, and the pixel pipeline.
A software renderer shows the screen in an SDL2 window.
A headless mode runs public test ROMs in scripts and CI.

## Why this project

The emulator shows how a real console works.
Every layer is small, readable Zig code.
You can inspect the CPU, the bus, and the renderer separately.
A bundled assembler builds test ROMs from source.
Deterministic tests guard the core behavior.

## Current status

The emulator core is the most complete part.
The CPU, timer, bus, and pixel pipeline are implemented.
The windowed frontend works when SDL2 is installed.
The headless runner drives automated checks.

## Features

- SM83 CPU with all 256 opcodes
- Memory bus with timer, serial, and pixel components
- MBC1 cartridge mapper
- SDL2 window with keyboard controls
- Headless runner with pass or fail verdicts
- Cartridge header display with `--info`
- Instruction trace output
- SM83 assembler with deterministic output
- Bundled smoke ROM assembled from source
- Deterministic unit and integration tests

## Architecture

The core does not depend on a window.
It feeds the bus and the CPU for each step.
The PPU fills a pixel frame.
The headless runner and the SDL2 frontend both use the core.

- `src/cpu.zig` - SM83 CPU
- `src/bus.zig` - memory and device routing
- `src/timer.zig` - DIV, TIMA, TMA, and TAC
- `src/ppu.zig` - LCD, background, and sprites
- `src/cartridge.zig` - ROM and MBC1 mapper
- `src/serial.zig` - serial verdict helpers
- `src/emulator.zig` - emulator composition
- `src/headless.zig` - headless ROM runner
- `src/main.zig` - SDL2 frontend
- `src/integration.zig` - ROM-level tests
- `tools/gbasm.zig` - SM83 assembler

## Requirements

- Zig 0.16.0 or later
- SDL2 for the windowed frontend

The headless build does not require SDL2.
On Windows, the build searches common MSYS2 and vcpkg prefixes.
You can also set `SDL2_DIR` or pass `-Dsdl2=<prefix>`.

## Build

Build the headless tools:

```text
zig build -Dsdl2=off
```

Build the windowed frontend:

```text
zig build
```

## Run a ROM headlessly

```text
zig build run-headless -- path/to/rom.gb
```

Use `--expect pass` to require a passing verdict.
Use `--expect any` to accept any outcome.
Use `--trace` to print each instruction.
Use `--info` to show the cartridge header without running.

```text
zig build run-headless -- path/to/rom.gb --expect pass
```

Sample output:

```text
Serial output:
Passed
Verdict: pass
```

Run the bundled smoke ROM:

```text
zig build fixtures -Dsdl2=off
zig build run-headless -- fixtures/roms/smoke.gb
```

## Run a ROM in a window

```text
zig build run -- path/to/rom.gb
```

| Key | Button |
| --- | ------ |
| X | A |
| Z | B |
| Enter | Start |
| Backspace | Select |
| Arrows | D-pad |
| Esc | Quit |

## Test

Run all tests:

```text
zig build test -Dsdl2=off
```

The test step assembles the smoke ROM first.
It then runs the unit tests and the ROM-level tests.
The suite is deterministic and reproducible.

Regenerate the bundled ROMs:

```text
zig build fixtures
```

The blargg CPU instruction suite is optional.
Copy its ROMs into `fixtures/blargg`, then run:

```text
zig build test-blargg
```

## Roadmap

The roadmap lists complete and planned work.
See `ROADMAP.md` for details.

## Limitations

The emulator does not cover all hardware.
Audio, OAM DMA, and battery saves are not implemented.
The PPU timing is not cycle-accurate.
The boot ROM is not emulated.

## License

Dot Matrix Deck is available under the MIT license.
See `LICENSE` for details.
