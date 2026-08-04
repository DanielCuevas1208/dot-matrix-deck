# Roadmap

This file shows the current state of the project. It lists what is done
and what comes next. The list changes as the project grows.

## Complete

- SM83 CPU with the full base and CB instruction sets
- Memory bus with timer, serial, and pixel components
- Interrupt handling with EI delay and HALT wake-up
- ROM-only and MBC1 cartridges
- Pixel pipeline with background, window, and sprites
- Headless runner with cycle limits and serial verdicts
- gbasm assembler for test ROM sources
- Bundled demo ROM that draws and reports PASS
- SDL2 window that shows emulated frames
- Keyboard input for the joypad
- Deterministic unit and end-to-end tests
- CI pipeline for Linux and Windows

## Next

- Accurate pixel pipeline timing
- Accurate DIV, TIMA, and STAT behavior
- Boot ROM support
- Joypad poll with proper edge detection
- Save states and SRAM persistence
- MBC2, MBC3, and MBC5 cartridges
- Audio output
- Interactive debugger with breakpoints
- Blargg test suites in CI

## Later

- Game Boy Color support
- Link cable emulation
- Rewind and movie recording
