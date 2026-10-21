# Dot Matrix Deck

Dot Matrix Deck is a Game Boy emulator written in Zig.
It models the SM83 CPU, the memory bus, the timers, and the pixel pipeline.
A software renderer shows the screen in an SDL2 window.
A headless mode runs public test ROMs and renders deterministic audio fixtures.

Read the [roadmap](ROADMAP.md) for release status, acceptance criteria, and verification commands.

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
- `src/timer.zig` models divider edges, delayed reloads, and interrupts.
- `src/apu.zig` models channel 2, a square wave, length, and volume envelope.
- `src/ppu.zig` renders graphics and exposes scanline modes and STAT edges.
- `src/cartridge.zig` loads ROM-only, MBC1, MBC2, MBC3, and MBC5 images.
  It banks memory and drives the MBC3 real-time clock.
  Battery-backed carts keep RAM in a `.sav` file.
- `src/dma.zig` copies pages into OAM with the correct timing.
- `src/serial.zig` turns link-port bytes into test verdicts.
- `src/joypad.zig` reports button state through the FF00 register.
- `src/emulator.zig` ties the core together and connects two serial ports.
- `src/headless.zig` runs a ROM without a window.
- `src/main.zig` and `src/frontend.zig` form the SDL2 frontend.
- `tools/gbasm.zig` assembles SM83 test ROMs.
- `tools/apu_demo.zig` renders a deterministic PCM WAV fixture.

The frontend logic stays free of SDL2.
Unit tests cover that logic in headless builds.

The joypad uses the real register semantics.
The select bits are active-low.
A cleared bit selects a column.
The register returns the stored select bits when read.
The bus raises the joypad interrupt on a visible falling edge.
The joypad ROM checks register reads and active-low column selection.
The timer ROM checks delayed overflow reload and the timer interrupt flag.
The joypad tests cover both columns, combined reads, stored select bits, and held-key selection.
CI runs the joypad and timer ROMs as separate headless checks.
The link demo connects two emulator instances through the same serial API.
The audio demo uses the same bus register path as the emulator core.

## Timing model

The CPU advances devices in T-cycles.
The timer counts falling edges from the divider signal.
An overflow reloads TIMA after four T-cycles.
The PPU runs modes 2, 3, 0, and 1 across 456 T-cycles.
STAT requests use rising edges from enabled mode and coincidence sources.
The APU advances with CPU and DMA cycles.
The channel frame sequencer clocks length at 256 Hz and envelopes at 64 Hz.

## Audio slice

Channel 2 uses the Game Boy square-wave registers.
The core exposes these registers through the memory bus.

| Register | Behavior |
| --- | --- |
| `FF16` NR21 | Bits 7–6 select duty; bits 5–0 load a 64-step length counter |
| `FF17` NR22 | Bits 7–4 set volume; bit 3 sets direction; bits 2–0 set envelope period |
| `FF18` NR23 | Stores the low frequency byte |
| `FF19` NR24 | Stores frequency bits, length enable, and trigger |
| `FF26` NR52 | Controls master power and reports channel 2 status |

The DAC disables when NR22 bits 7–3 are zero.
The envelope clocks at 64 Hz and changes volume at its selected period.
Period zero holds the current volume.
The frequency timer uses `(2048 - frequency) * 4` CPU cycles.
The renderer converts CPU cycles to 44.1 kHz with integer arithmetic.
The WAV output uses centered signed 16-bit mono samples.

## Verified hardware

The release includes evidence for each new hardware path.

| Surface | Evidence |
| --- | --- |
| `FF00` joypad | Active-low selection, stored bits, pressed keys, and interrupt edges |
| `FF46` DMA | 160-byte OAM transfer and CPU blocking |
| Cartridge banks | MBC1, MBC2, MBC3, and MBC5 fixture ROMs |
| Battery RAM | Deterministic save-file round-trip |
| Timer | Divider edges, delayed reload, and IF bit 2 |
| PPU timing | Scanline modes and STAT edge requests |
| Serial link | Two ROMs exchange bytes through connected emulator instances |
| APU channel 2 | Register transitions, duty samples, envelope steps, and WAV output |

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

Check the joypad fixture separately.

```text
zig build run-headless -Dsdl2=off -- fixtures/roms/joypad.gb --expect pass
```

It prints `PASS` under `Serial output` and ends with `Verdict: pass`.

Run the serial link demo.

```text
zig build run-link-demo -Dsdl2=off
```

Sample output:

```text
Serial link demo:
A received: B
B received: A
Verdict: pass
```

Render the square-channel audio fixture.

```text
zig build run-apu-demo -Dsdl2=off
```

Sample output:

```text
APU square-channel demo:
Wrote fixtures/audio/square-channel.wav
Samples: 11025
First samples: 30720, 30720, 30720, 30720
Verdict: pass
```

The fixture contains 0.25 seconds of mono, signed 16-bit PCM at 44.1 kHz.

## Run a ROM

Run a ROM without a window.

```text
zig build run-headless -- path/to/rom.gb
```

Useful options are `--max-cycles N`, `--trace`, `--expect pass|fail|any`, `--load-save <path>`, and `--save <path>`.
The runner prints serial output and returns the verdict code.

Run a ROM in the SDL2 frontend.

```text
zig build run -- path/to/rom.gb
```

The built-in key map uses Z for A, X for B, Enter for Start, and Shift for Select.
Arrows move the d-pad.
P pauses, R resets, F fast-forwards, and ESC quits.
See "Key bindings" below to change the map.

## Key bindings

The key map is configurable.
Create a file named `dmd.keys.conf` in the working directory.
The frontend loads it at start.
The repository ships a `dmd.keys.conf` that matches the built-in map.

Each line maps one logical key to one or more physical keys.
Each line overrides one logical key.
Omitted keys keep the built-in bindings.

```text
a = z
select = left shift, right shift
```

Physical keys use SDL scancode names.
Examples are `z`, `return`, `up`, and `left shift`.
Lines that start with `#` are comments.
Blank lines are ignored.

Pass `--keys <path>` to load another file.

```text
zig build run -- path/to/rom.gb --keys my-keys.conf
```

## Save files

Battery-backed cartridges keep their external RAM in a `.sav` file.
The windowed frontend loads the file next to the ROM at start.
It writes the file back when you quit.
The headless runner keeps the files explicit.

```text
zig build run-headless -Dsdl2=off -- fixtures/roms/sram.gb --save /tmp/sram.sav
zig build run-headless -Dsdl2=off -- fixtures/roms/sram.gb --load-save /tmp/sram.sav
```

Sample output from the second run:

```text
Loaded save data.
Serial output:
PASS
Verdict: pass
```

The save file stores the external RAM bytes only.
It matches the RAM size from the cartridge header.
The MBC3 real-time clock state is not persisted.

## Generate fixtures

Regenerate the bundled ROMs from their assembly sources.

```text
zig build fixtures -Dsdl2=off
```

Each `.asm` file in `fixtures/asm` becomes a `.gb` image in `fixtures/roms`.
The round-trip tests keep those images in sync.
The suite ships eleven ROMs:

- `demo` renders the title and prints PASS.
- `dma` copies a page into OAM and checks the result.
- `joypad` checks FF00 select bits and active-low column reads.
- `link-a` and `link-b` exchange marker bytes through a connected cable.
- `banking` switches MBC1 banks and checks each marker.
- `mbc2` switches MBC2 banks and checks the internal RAM.
- `mbc3` switches MBC3 banks, RAM banks, and the real-time clock.
- `mbc5` switches MBC5 banks and RAM banks.
- `sram` enables battery-backed RAM and verifies the save file round-trip.
- `timer` waits for a TIMA overflow and checks the timer interrupt flag.

Generate the audio fixture with the headless demo.

```text
zig build run-apu-demo -Dsdl2=off
```

The command rewrites `fixtures/audio/square-channel.wav` with stable bytes.

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

Run every bundled ROM through the headless runner.

```text
zig build test-fixtures -Dsdl2=off
```

The current suite reports 170 deterministic tests and 11 bundled ROMs on Zig 0.16.
CI repeats the suite on Ubuntu and Windows.

The CI job also regenerates the WAV fixture and checks its committed bytes.

## Project layout

- `src/` holds the emulator core and frontend.
- `tools/` holds the assembler and audio demo.
- `fixtures/` holds ROM sources, ROM images, and the WAV fixture.
- `.github/workflows/` holds the CI pipeline.

## Limitations

Hardware coverage is incomplete.
Only channel 2 has audio output.
The SDL2 frontend does not play audio yet.
The debugger overlay remains planned.
Serial links complete at byte boundaries and do not model individual bit clocks.
The core starts at the post-boot state.
It does not emulate the boot ROM.
The MBC3 clock advances with the emulated cycle count.
It does not follow the host clock.
Save files store external RAM only.
The MBC3 real-time clock state does not persist.

## License

This project is licensed under the MIT License.
See the LICENSE file for details.
