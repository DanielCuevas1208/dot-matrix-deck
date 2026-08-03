# Contributing

Dot Matrix Deck is a work-in-progress emulator. Contributions are welcome.

## Build

Use Zig 0.16.0 or later.

Build the headless tools:

```text
zig build -Dsdl2=off
```

Build the windowed frontend. SDL2 must be installed. On Linux, install the package `libsdl2-dev`. On Windows, set the prefix with `-Dsdl2=<prefix>`.

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

## Format

The CI workflow checks formatting. Format your changes before you open a pull request:

```text
zig fmt .
```

## Bundled ROMs

The bundled ROMs live in `fixtures`. Keep the ROM image in sync with its assembly source:

```text
zig build fixtures
git diff --exit-code -- fixtures
```

## Pull requests

Keep each pull request small and focused. Add tests for new behavior. Update the README and the roadmap when the change affects them. Do not add generated files to a pull request unless they are committed fixtures.
