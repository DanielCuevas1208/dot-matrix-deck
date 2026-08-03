// Root module for the deterministic unit test suite.
//
// Importing a module pulls its test blocks into the test binary, so this
// root file exercises the whole emulator core and the frontend logic.

test {
    _ = @import("emulator.zig");
    _ = @import("bus.zig");
    _ = @import("joypad.zig");
    _ = @import("frontend.zig");
    _ = @import("serial.zig");
    _ = @import("disasm.zig");
}
