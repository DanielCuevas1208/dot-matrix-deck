# Dot Matrix Deck

Dot Matrix Deck is a Game Boy emulator written in Zig. It emulates the SM83 CPU, the memory bus, the timers, and the pixel pipeline. A software renderer shows the screen in an SDL2 window. A headless mode runs public test ROMs for automated checks.

## Features

- SM83 CPU with all 256 opcodes
- CB prefix instructions and interrupt timing
- Memory bus with WRAM, HRAM, and the MBC1 mapper
- Timer unit with DIV, TIMA, TMA, and TAC
- Background and sprite rendering through the PPU
- Windowed frontend with keyboard controls
- Headless runner with pass or fail verdicts
- Instruction trace mode
- Cartridge header display with the --info flag
- Small assembler for test ROM sources
- Deterministic unit and integration tests

## Requirements

- Zig 0.16.0 or later
- SDL2 for the windowed frontend

The headless build does not require SDL2. On Windows, the build searches common MSYS2 and vcpkg prefixes. You can also set `SDL2_DIR` or pass an SDL2 prefix.

## Build

Build the headless runner and assembler:

```text
zig build -Dsdl2=off
```

Build with the windowed frontend when SDL2 is available:

```text
zig build
```

Disable the windowed frontend explicitly:

```text
zig build -Dsdl2=off
```

## Run a ROM

Run a ROM without a window:

```text
zig build run-headless -- path/to/rom.gb
```

Run a ROM in the SDL2 window:

```text
zig build run -- path/to/rom.gb
```

Useful options are `--max-cycles N`, `--trace`, `--info`, and `--expect pass|fail|any`. The runner prints serial output and returns a status from the detected verdict.

## Sample output

Run the bundled smoke ROM:

```text
zig build run-headless -- fixtures/roms/smoke.gb
```

```text
Serial output:
PASS
Verdict: pass
```

Show the cartridge header:

```text
zig build run-headless -- fixtures/roms/smoke.gb --info
```

```text
Title:  SMOKE TEST
Mapper: ROM only
ROM:    32 KiB
RAM:    0 KiB
CGB:    no
SGB:    no
Header: valid checksum
Global: $0000
```

## Test

Run the unit, assembler, and integration tests:

```text
zig build test -Dsdl2=off
```

Run the blargg CPU instruction suite:

```text
zig build test-blargg
```

The integration tests assemble the smoke ROM from source and compare the image to the committed ROM. They also run the ROM through the emulator and check the serial verdict and the frame checksum.

## Test status

- Unit tests for the CPU, timer, bus, and serial output pass.
- The smoke ROM rebuilds byte for byte from its source.
- The smoke ROM reports a pass verdict through the emulator.
- The blargg CPU instruction suite passes, 11 of 11.
- The frame checksum is deterministic.

## Architecture

- `src/cpu.zig` - SM83 CPU implementation
- `src/bus.zig` - memory and device routing
- `src/emulator.zig` - emulator composition and core tests
- `src/cartridge.zig` - cartridge mapping and header parsing
- `src/ppu.zig` - pixel pipeline and frame buffer
- `src/timer.zig` - timer unit
- `src/headless.zig` - command-line ROM runner
- `src/main.zig` - SDL2 frontend
- `src/disasm.zig` - instruction disassembler
- `src/integration.zig` - end-to-end ROM tests
- `tools/gbasm.zig` - SM83 assembler for fixture ROMs
- `fixtures/asm` - assembly sources for the bundled ROMs
- `fixtures/roms` - committed ROM images
- `fixtures/blargg` - blargg CPU instruction suite

## Limitations

Hardware coverage is incomplete. Timing accuracy, cartridge support, audio, and frontend features will improve as the project grows. The windowed frontend needs an SDL2 setup to build.

## License

Dot Matrix Deck is released under the MIT License. See `LICENSE` for details. The bundled test ROMs have their own provenance; see `NOTICE`.
