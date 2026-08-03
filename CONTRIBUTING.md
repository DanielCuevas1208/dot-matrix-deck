# Contributing

Dot Matrix Deck is a work-in-progress emulator. Contributions are welcome.

## Build

Use Zig 0.16.0 or later.

Build the headless tools:

```text
zig build -Dsdl2=off
```

Build the windowed frontend. SDL2 must be installed.

On Linux, install the package `libsdl2-dev`.

On Windows, install SDL2 in MSYS2 or set the prefix with `-Dsdl2=<prefix>`.

```text
zig build
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

The blargg ROMs are public test files. Copy them into `fixtures/blargg` first.
Without them, the suite prints a skip message and exits cleanly.

## Format

The CI workflow checks formatting. Format your changes before you open a
pull request:

```text
zig fmt .
```

Verify the formatting with:

```text
zig fmt --check .
```

## Regenerate fixtures

The bundled ROMs come from source. Regenerate them with:

```text
zig build fixtures
```

The output is deterministic. The integration tests read the generated ROMs.

## Report a problem

Open an issue that describes the expected behavior and the observed behavior.
Include the ROM and the command you ran when you can.
