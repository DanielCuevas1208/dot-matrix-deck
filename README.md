# Dot Matrix Deck

```
  ____    __  __   ____
 |  _ \  |  \/  | |  _ \
 | | | | | |\/| | | | | |
 | |_| | | |  | | | |_| |
 |____/  |_|  |_| |____/
```

Dot Matrix Deck is a Game Boy emulator written in Zig.
It emulates the SM83 CPU, the memory bus, the timers, and the pixel pipeline.
A software renderer draws the screen in an SDL2 window.
A headless mode runs test ROMs without a window.
The headless mode prints a pass or fail verdict from the serial link output.

## What it provides

- SM83 CPU with the full instruction set and interrupts
- Memory bus with ROM-only and MBC1 cartridges
- Timer unit with DIV, TIMA, TMA, and TAC registers
- Pixel pipeline for background, window, and sprites
- Serial link output for automated test verdicts
- SDL2 windowed frontend with keyboard controls
- Headless runner with frame dump and checksums
- A bundled SM83 assembler named gbasm

The bundled test ROM runs the CPU and the memory bus.
It reports "PASS" only when every check succeeds.
The blargg CPU instruction suite runs in the headless mode.
All 11 test ROMs in the suite pass.

## Architecture

The code is split into small modules.
Each module owns one part of the machine.
The frontends share one core; only presentation differs.

```
  rom.gb --> Cartridge --> Bus --> Cpu
                                  |
                                  v (cycles)
                          Timer and Ppu
                                  |
                                  v
                Frame buffer --> window or PPM dump
```

| Module | Responsibility |
| --- | --- |
| `cpu.zig` | SM83 core, instructions, flags, interrupts |
| `bus.zig` | Memory map, joypad, serial link, interrupts |
| `cartridge.zig` | ROM image, MBC1 mapper, header parser |
| `timer.zig` | DIV, TIMA, TMA, and TAC |
| `ppu.zig` | LCD registers and pixel rendering |
| `serial.zig` | Verdict extraction from serial output |
| `disasm.zig` | Instruction disassembly for trace mode |
| `headless.zig` | Headless runner entry point |
| `main.zig` | SDL2 windowed frontend |
| `tools/gbasm.zig` | Two-pass assembler for test ROMs |

## Requirements

- Zig 0.16.0 or newer
- SDL2 for the windowed frontend only

The headless runner does not need SDL2.
On Windows, pass `-Dsdl2=off` when SDL2 is absent.

## Build

Build the headless runner and gbasm.

```
zig build -Dsdl2=off
```

Build the windowed frontend.

```
zig build
```

## Run

Run a ROM in the SDL2 window.

```
zig build run -- path/to/rom.gb
```

Keys: arrows move the D-pad.  Z is A, X is B.
Enter is Start, Backspace is Select, and Esc quits.

Run a ROM without a window.

```
zig build run-headless -- path/to/rom.gb
```

Show the cartridge header.

```
zig build run-headless -- path/to/rom.gb --info
```

Run the bundled smoke ROM.

```
zig build run-headless -- fixtures/roms/smoke.gb
```

Print a pixel checksum for a fixed number of frames.

```
zig build run-headless -- fixtures/roms/smoke.gb --dump-frame out.ppm --frames 3
```

## Sample output

Cartridge header of the bundled smoke ROM.

```
Title:  SMOKE TEST
Mapper: ROM only
ROM:    32 KiB
RAM:    0 KiB
CGB:    no
SGB:    no
Header: valid checksum
Global: $0000
```

Headless run of the bundled smoke ROM.

```
Serial output:
PASS

Verdict: pass
```

Deterministic frame checksum after three frames.

```
Frame checksum: 5CCE8DC5
```

Headless run of the blargg CPU suite.

```
11/11 ROMs passed
```

## Test

Run the unit and integration tests.

```
zig build test
```

Run the blargg CPU instruction suite.

```
zig build test-blargg
```

Regenerate the bundled ROMs from their assembly sources.

```
zig build fixtures
```

Check code formatting.

```
zig fmt --check .
```

The test suite is deterministic.
The smoke ROM must rebuild byte for byte from its source.
The rendered frame must produce a fixed checksum.
CI runs every check on Linux and Windows.

## Test status

- `zig build test`: 42 tests pass
- `zig build test-blargg`: 11 of 11 ROMs pass
- Formatting: clean

## Limitations

- The APU is not implemented, so there is no sound
- OAM DMA is not implemented
- Only ROM-only and MBC1 cartridges are supported
- The joypad interrupt is not implemented
- Battery save is not supported
- The boot ROM is not emulated
- Registers start in the state left by the boot ROM

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the completed and planned work.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution guide.

## License

The project is licensed under the MIT License.
See [LICENSE](LICENSE) for details.
Third-party test ROMs are listed in [NOTICE](NOTICE).
