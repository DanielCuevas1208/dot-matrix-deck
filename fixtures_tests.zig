const std = @import("std");
const gbasm = @import("tools/gbasm.zig");

// Package-root shim for the gbasm test suite.
//
// `zig test` roots a package at the directory of its root source file.
// gbasm's fixture round-trip test embeds files under fixtures/, so this
// module must live at the project root to keep those paths inside the
// package. The build.zig `test` step uses this file as its root source.

test {
    std.testing.refAllDecls(gbasm);
}
