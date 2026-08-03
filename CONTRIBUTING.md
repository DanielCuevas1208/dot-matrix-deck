# Contributing

Thank you for your interest in Dot Matrix Deck.

## Ground rules

- Keep the emulator core free of SDL2 dependencies.
- Keep the headless build working without SDL2.
- Write deterministic tests for new behavior.
- Run `zig fmt` on every file you change.
- Keep the bundle ROMs reproducible. Change the assembler source, then
  regenerate the ROMs with `zig build fixtures`.

## How to build

Requires Zig 0.16 or later.

```text
zig build test -Dsdl2=off
```

Run the windowed frontend with SDL2 installed:

```text
zig build
```

## How to add a test ROM

1. Write an assembly source under `fixtures/asm`.
2. Generate the ROM with `zig build fixtures`.
3. Add integration checks in `src/integration.zig`.
4. Commit both the source and the generated ROM.

## How to run the blargg suite

Add the blargg cpu_instrs ROMs to `fixtures/blargg`, then run:

```text
zig build test-blargg
```

## How to report an issue

Open an issue on GitHub.
Include the ROM name, the expected result, and the actual result.
Include the headless command you used.
