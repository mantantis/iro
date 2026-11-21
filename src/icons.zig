// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Nerd Font icons for files and folders in the tree and tabs.

const std = @import("std");

/// Icon before a name in the tree or a tab, including the trailing space.
/// Nothing unless `icons = true` in the config.
pub fn forEntry(symbols: bool, name: []const u8, is_dir: bool, expanded: bool) []const u8 {
    if (!symbols) return "";
    if (is_dir) return if (expanded) "\u{f07c} " else "\u{f07b} ";
    const Map = struct { ext: []const u8, glyph: []const u8 };
    const by_name = [_]Map{
        .{ .ext = "Makefile", .glyph = "\u{e615} " },   .{ .ext = "Dockerfile", .glyph = "\u{f308} " },
        .{ .ext = "PKGBUILD", .glyph = "\u{f303} " },   .{ .ext = "LICENSE", .glyph = "\u{f0219} " },
        .{ .ext = ".gitignore", .glyph = "\u{e702} " }, .{ .ext = "README.md", .glyph = "\u{f02d} " },
    };
    for (by_name) |m| {
        if (std.mem.eql(u8, name, m.ext)) return m.glyph;
    }
    const by_ext = [_]Map{
        .{ .ext = ".zig", .glyph = "\u{e6a9} " },  .{ .ext = ".zon", .glyph = "\u{e6a9} " },  .{ .ext = ".lua", .glyph = "\u{e620} " },
        .{ .ext = ".py", .glyph = "\u{e73c} " },   .{ .ext = ".rs", .glyph = "\u{e7a8} " },   .{ .ext = ".go", .glyph = "\u{e627} " },
        .{ .ext = ".js", .glyph = "\u{e74e} " },   .{ .ext = ".ts", .glyph = "\u{e628} " },   .{ .ext = ".json", .glyph = "\u{e60b} " },
        .{ .ext = ".md", .glyph = "\u{e73e} " },   .{ .ext = ".html", .glyph = "\u{e736} " }, .{ .ext = ".css", .glyph = "\u{e749} " },
        .{ .ext = ".c", .glyph = "\u{e61e} " },    .{ .ext = ".h", .glyph = "\u{e61e} " },    .{ .ext = ".cpp", .glyph = "\u{e61d} " },
        .{ .ext = ".java", .glyph = "\u{e738} " }, .{ .ext = ".sh", .glyph = "\u{e795} " },   .{ .ext = ".zsh", .glyph = "\u{e795} " },
        .{ .ext = ".bash", .glyph = "\u{e795} " }, .{ .ext = ".fish", .glyph = "\u{e795} " }, .{ .ext = ".conf", .glyph = "\u{e615} " },
        .{ .ext = ".toml", .glyph = "\u{e615} " }, .{ .ext = ".yaml", .glyph = "\u{e615} " }, .{ .ext = ".yml", .glyph = "\u{e615} " },
        .{ .ext = ".ini", .glyph = "\u{e615} " },  .{ .ext = ".png", .glyph = "\u{f03e} " },  .{ .ext = ".jpg", .glyph = "\u{f03e} " },
        .{ .ext = ".svg", .glyph = "\u{f03e} " },  .{ .ext = ".webp", .glyph = "\u{f03e} " }, .{ .ext = ".lock", .glyph = "\u{f023} " },
        .{ .ext = ".txt", .glyph = "\u{f0f6} " },  .{ .ext = ".nix", .glyph = "\u{f313} " },  .{ .ext = ".sql", .glyph = "\u{f1c0} " },
    };
    const ext = std.fs.path.extension(name);
    for (by_ext) |m| {
        if (std.ascii.eqlIgnoreCase(ext, m.ext)) return m.glyph;
    }
    return "\u{f15b} ";
}

test "file icons and switch" {
    try std.testing.expectEqualStrings("", forEntry(false, "main.zig", false, false));
    try std.testing.expectEqualStrings("\u{f07b} ", forEntry(true, "src", true, false));
    try std.testing.expectEqualStrings("\u{f07c} ", forEntry(true, "src", true, true));
    try std.testing.expectEqualStrings("\u{e6a9} ", forEntry(true, "main.zig", false, false));
    try std.testing.expectEqualStrings("\u{e6a9} ", forEntry(true, "MAIN.ZIG", false, false));
    try std.testing.expectEqualStrings("\u{f0219} ", forEntry(true, "LICENSE", false, false));
    try std.testing.expectEqualStrings("\u{f15b} ", forEntry(true, "unbekannt.xyz", false, false));
}
