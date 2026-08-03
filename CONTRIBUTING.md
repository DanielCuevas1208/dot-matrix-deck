# Contributing

Thank you for your interest in Dot Matrix Deck.

## Setup

Install Zig 0.16.0 or newer.
Install SDL2 for the windowed frontend.

## Build and test

Run the test suite.

```
zig build test
```

Run the blargg CPU instruction suite.

```
zig build test-blargg
```

Build the headless tools.

```
zig build -Dsdl2=off
```

Format the code.

```
zig fmt .
```

## Code style

Follow the existing style in the repository.
Run `zig fmt --check .` before you finish.
Keep each module small and single-purpose.
Add a test for every new behaviour.

## Adding tests

Use the bundled smoke ROM for end-to-end checks.
Regenerate its binary after you change its assembly source.

```
zig build fixtures
```

Verify the committed ROM still matches its source.

```
git diff --exit-code -- fixtures
```

Update the golden frame checksum when rendering changes.
Run the headless runner to read the new value.

```
zig build run-headless -- fixtures/roms/smoke.gb --dump-frame out.ppm
```

## Submitting changes

Create a pull request against the main branch.
Make the change small and focused.
Add a clear description of what changed.
Confirm all CI checks pass before you request a review.
