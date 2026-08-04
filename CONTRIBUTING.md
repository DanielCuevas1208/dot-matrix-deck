# Contributing

Thank you for helping with Dot Matrix Deck.
This guide explains how to contribute cleanly.

## Before you start

Read the ROADMAP file.
It lists what the project delivers and what remains.
Pick an item from the "Next" list or open an issue first.

## Build and test

Build the headless tools.

```text
zig build -Dsdl2=off
```

Run the whole test suite.

```text
zig build test -Dsdl2=off
```

Run the format check.

```text
zig fmt --check .
```

Fix formatting with `zig fmt .`.
The CI pipeline enforces both checks.

## Make a change

Follow these rules.

- Keep every module small and focused.
- Match the style of the surrounding code.
- Do not add comments that restate the code.
- Add deterministic tests for new behavior.
- Keep the public API stable unless a test requires a change.

## Regenerate fixtures

Update the demo ROM only through its source.

```text
zig build fixtures -Dsdl2=off
```

Commit the `.asm` source and the generated `.gb` image together.
The round-trip test checks that they stay in sync.

## Open a pull request

- Write a clear title and summary.
- Keep the change as small as possible.
- Confirm that tests, format, and builds pass.
- Confirm the windowed frontend still builds when SDL2 is present.
