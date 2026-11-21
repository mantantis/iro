// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

const std = @import("std");
const builtin = @import("builtin");

// iro is pinned to exactly one Zig release series. Zig regularly breaks
// existing code between versions, so upgrades happen deliberately. Backup
// archive of the matching version: ~/.local/share/iro/toolchain/
comptime {
    const v = builtin.zig_version;
    if (v.major != 0 or v.minor != 17) {
        @compileError("iro braucht Zig 0.17.x (gefunden: " ++ builtin.zig_version_string ++
            "). Passendes Archiv liegt in ~/.local/share/iro/toolchain/");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Stability rule: iro is always built in safe mode. Memory errors then end in a
    // controlled abort instead of silent data corruption.
    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "Bau-Modus (Standard: safe)",
    ) orelse .safe;

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis_mod = vaxis_dep.module("vaxis");

    // The core: text buffer, editor logic, file access. Knows nothing about the
    // terminal and can therefore be tested fully automatically.
    const core = b.addModule("iro", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
        },
    });
    core.link_libc = true;
    core.linkSystemLibrary("lua5.4", .{});

    const exe = b.addExecutable(.{
        .name = "iro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "iro", .module = core },
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("lua5.4", .{});
    b.installArtifact(exe);

    const run_step = b.step("run", "iro starten");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const core_tests = b.addTest(.{ .root_module = core });
    const run_core_tests = b.addRunArtifact(core_tests);
    const test_step = b.step("test", "Alle Tests ausführen");
    test_step.dependOn(&run_core_tests.step);
}
