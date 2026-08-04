const std = @import("std");

const sdl_deps = [_][]const u8{ "dinput8", "dxguid", "dxerr8", "user32", "gdi32", "winmm", "imm32", "ole32", "oleaut32", "shell32", "version", "uuid", "setupapi" };

const sdl_prefix_candidates = [_][]const u8{
    "C:/msys64/mingw64",
    "C:/msys2/mingw64",
    "C:/msys64/ucrt64",
    "C:/vcpkg/installed/x64-mingw-dynamic",
    "C:/vcpkg/installed/x64-windows",
};

fn sdl2PrefixFound(b: *std.Build, prefix: []const u8) bool {
    const header = std.fmt.allocPrint(b.allocator, "{s}/include/SDL2/SDL.h", .{prefix}) catch return false;
    defer b.allocator.free(header);
    b.build_root.handle.access(b.graph.io, header, .{}) catch return false;
    return true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const headless = b.addExecutable(.{
        .name = "dot-matrix-deck-headless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/headless.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(headless);

    const run_headless = b.addRunArtifact(headless);
    const run_headless_step = b.step("run-headless", "Run a ROM headlessly. Usage: zig build run-headless -- <rom.gb> [options]");
    run_headless_step.dependOn(&run_headless.step);
    if (b.args) |args| run_headless.addArgs(args);

    const gbasm = b.addExecutable(.{
        .name = "gbasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gbasm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(gbasm);

    const sdl2_opt = b.option([]const u8, "sdl2", "Path to an SDL2 prefix. Set to \"off\" to disable the windowed frontend.");

    const build_windowed = blk: {
        if (sdl2_opt) |value| {
            if (value.len == 0 or std.mem.eql(u8, value, "off")) break :blk false;
            break :blk true;
        }
        break :blk true;
    };

    if (build_windowed) {
        var sdl_prefix: ?[]const u8 = null;
        if (sdl2_opt) |value| {
            if (value.len != 0 and !std.mem.eql(u8, value, "off")) sdl_prefix = value;
        } else {
            if (b.graph.environ_map.get("SDL2_DIR")) |dir| {
                if (dir.len != 0) sdl_prefix = dir;
            }
            if (sdl_prefix == null and target.result.os.tag == .windows) {
                for (sdl_prefix_candidates) |candidate| {
                    if (sdl2PrefixFound(b, candidate)) {
                        sdl_prefix = candidate;
                        break;
                    }
                }
            }
        }

        if (sdl_prefix != null or target.result.os.tag != .windows) {
            const exe = b.addExecutable(.{
                .name = "dot-matrix-deck",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            exe.root_module.linkSystemLibrary("SDL2", .{});
            if (target.result.os.tag == .windows) {
                for (sdl_deps) |lib| exe.root_module.linkSystemLibrary(lib, .{});
            }
            if (sdl_prefix) |prefix| {
                exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
                exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
                // On Windows prefer the DLL import library. The static
                // mingw archive drags in CRT symbols Zig does not ship.
                if (target.result.os.tag == .windows) {
                    exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", "libSDL2.dll.a" }) });
                    const shim = b.addObject(.{ .name = "sdl_mingw_shim", .root_module = b.createModule(.{
                        .root_source_file = b.path("src/sdl_mingw_shim.zig"),
                        .target = target,
                        .optimize = optimize,
                    }) });
                    exe.root_module.addObject(shim);
                }
                const dll_path = b.pathJoin(&.{ prefix, "bin", "SDL2.dll" });
                if (sdl2PrefixFound(b, prefix)) {
                    const install_dll = b.addInstallBinFile(.{ .cwd_relative = dll_path }, "SDL2.dll");
                    b.getInstallStep().dependOn(&install_dll.step);
                }
            }
            b.installArtifact(exe);

            const run_cmd = b.addRunArtifact(exe);
            const run_step = b.step("run", "Run a ROM in the SDL2 window. Usage: zig build run -- <rom.gb>");
            run_step.dependOn(&run_cmd.step);
            if (b.args) |args| run_cmd.addArgs(args);
        } else {
            b.step("run", "Windowed frontend disabled. SDL2 not found; pass -Dsdl2=<prefix>.").dependOn(b.getInstallStep());
        }
    } else {
        b.step("run", "Windowed frontend disabled by -Dsdl2=off.").dependOn(b.getInstallStep());
    }

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emulator.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const asm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gbasm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_asm_tests = b.addRunArtifact(asm_tests);

    const joypad_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/joypad.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_joypad_tests = b.addRunArtifact(joypad_tests);

    const serial_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/serial.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_serial_tests = b.addRunArtifact(serial_tests);

    const disasm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/disasm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_disasm_tests = b.addRunArtifact(disasm_tests);

    const gbasm_mod = b.createModule(.{
        .root_source_file = b.path("tools/gbasm.zig"),
        .target = target,
        .optimize = optimize,
    });
    const end_to_end_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gbasm", .module = gbasm_mod }},
        }),
    });
    const run_end_to_end_tests = b.addRunArtifact(end_to_end_tests);

    const test_step = b.step("test", "Run deterministic unit tests and bundled ROM tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_asm_tests.step);
    test_step.dependOn(&run_joypad_tests.step);
    test_step.dependOn(&run_serial_tests.step);
    test_step.dependOn(&run_disasm_tests.step);
    test_step.dependOn(&run_end_to_end_tests.step);

    const fixtures_step = b.step("fixtures", "Regenerate bundled test ROMs from their assembly sources");
    {
        const run = b.addRunArtifact(gbasm);
        run.addDirectoryArg(b.path("fixtures/asm"));
        run.addDirectoryArg(b.path("fixtures/roms"));
        fixtures_step.dependOn(&run.step);
    }

    const demo_step = b.step("run-demo", "Run the bundled demo ROM and check it reports PASS");
    {
        const run = b.addRunArtifact(headless);
        run.addArg("--expect");
        run.addArg("pass");
        run.addFileArg(b.path("fixtures/roms/demo.gb"));
        demo_step.dependOn(&run.step);
    }
    demo_step.dependOn(fixtures_step);

    const blargg_step = b.step("test-blargg", "Run the blargg cpu_instrs ROMs in headless mode and check their serial output");
    {
        const run = b.addRunArtifact(headless);
        run.addArg("--blargg-suite");
        run.addDirectoryArg(b.path("fixtures/blargg"));
        blargg_step.dependOn(&run.step);
    }
}
