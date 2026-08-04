# Dot Matrix Deck

Dot Matrix Deck is a Game Boy emulator. It is written in Zig. It
emulates the SM83 CPU, the memory bus, the timers, and the pixel
pipeline. A window shows the screen with SDL2. A headless mode runs
test ROMs without a window.

## Features

- SM83 CPU with the full base and CB instruction sets
- Memory bus with timer, serial, joypad, and pixel components
- Pixel pipeline with background, window, and sprites
- MBC1 and ROM-only cartridges
- Headless runner with serial verdicts
- SDL2 window with keyboard controls
- gbasm assembler for test ROMs
- Bundled demo ROM that draws and reports PASS
- Deterministic unit and end-to-end tests

## Requirements

- Zig 0.16 or later
- SDL2 for the windowed frontend

The headless build does not need SDL2. On Windows, the build searches
common MSYS2 and vcpkg prefixes. Set `SDL2_DIR` to use another prefix.

## Build

Build the headless tools:

```text
zig build -Dsdl2=off
```

Build the windowed frontend:

```text
zig build
```

## Run the demo

Run the demo ROM and check its verdict:

```text
zig build run-demo -Dsdl2=off
```

The demo draws a pattern and reports PASS over the link port.

## Run a ROM

Run a ROM without a window:

```text
zig build run-headless -- path/to/rom.gb
```

The runner prints the serial output. It sets the exit code from the
verdict. Useful options are `--max-cycles N`, `--trace`, and
`--expect pass|fail|any`.

Run a ROM in a window:

```text
zig build run -- path/to/rom.gb
```

## Controls

Use the arrow keys to move. Use Z and X for the A and B buttons. Use
Enter and Backspace for Start and Select. Press Escape to quit.

## Test

Run all tests:

```text
zig build test -Dsdl2=off
```

The tests cover the CPU, the timer, the serial port, the disassembler,
the assembler, and the ROM fixtures.

## Project layout

- `src/cpu.zig` - the SM83 CPU
- `src/bus.zig` - the memory bus
- `src/ppu.zig` - the pixel pipeline
- `src/timer.zig` - the timer
- `src/cartridge.zig` - cartridges and MBC1
- `src/headless.zig` - the headless runner
- `src/frontend.zig` - the SDL2 window
- `src/joypad.zig` - the joypad
- `src/disasm.zig` - the disassembler
- `tools/gbasm.zig` - the assembler
- `fixtures/` - bundled test ROMs and sources
- `docs/` - roadmap and architecture notes

## Test status

The project runs 44 tests in CI. The CI checks formatting, builds, and
the demo verdict. It runs on Linux and Windows.

## Limitations

Timing accuracy is incomplete. Audio is not implemented. Only MBC1
cartridges work. The windowed frontend is basic. See `docs/roadmap.md`
for the remaining work.

## License

MIT. See `LICENSE`.
