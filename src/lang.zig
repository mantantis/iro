// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! UI language: German or English.
//!
//! Every text iro shows is a pair in the code: `.{ .de = …, .en = … }`. Both
//! fields are required, so a missing translation does not even compile. Which
//! half applies is decided by `language` in init.lua, otherwise by the system
//! language (`LC_ALL`, `LC_MESSAGES`, `LANG`): German for `de…`, English
//! otherwise.

const std = @import("std");

pub const Lang = enum { de, en };

/// A text in both languages.
pub const Text = struct {
    de: []const u8,
    en: []const u8,

    pub fn in(self: Text, l: Lang) []const u8 {
        return switch (l) {
            .de => self.de,
            .en => self.en,
        };
    }
};

/// The system language as other programs read it: the first variable that is
/// set wins, in this order.
pub fn fromLocale(lc_all: ?[]const u8, lc_messages: ?[]const u8, lang: ?[]const u8) Lang {
    for ([_]?[]const u8{ lc_all, lc_messages, lang }) |v| {
        const s = v orelse continue;
        if (s.len == 0) continue;
        return if (std.ascii.startsWithIgnoreCase(s, "de")) .de else .en;
    }
    return .en;
}

/// English name for a part of a German key name ("Strg" → "Ctrl", "Bild ab" →
/// "PgDn"). Anything unknown stays as it is.
pub fn keyTokenEn(tok: []const u8) []const u8 {
    const Pair = struct { de: []const u8, en: []const u8 };
    const table = [_]Pair{
        .{ .de = "Strg", .en = "Ctrl" },
        .{ .de = "Umschalt", .en = "Shift" },
        .{ .de = "Pos1", .en = "Home" },
        .{ .de = "Ende", .en = "End" },
        .{ .de = "Bild auf", .en = "PgUp" },
        .{ .de = "Bild ab", .en = "PgDn" },
        .{ .de = "Rücktaste", .en = "Backspace" },
        .{ .de = "Entf", .en = "Del" },
        .{ .de = "Einfg", .en = "Ins" },
        .{ .de = "Leer", .en = "Space" },
        .{ .de = "Hoch", .en = "Up" },
        .{ .de = "Runter", .en = "Down" },
        .{ .de = "Links", .en = "Left" },
        .{ .de = "Rechts", .en = "Right" },
        .{ .de = "Komma", .en = "Comma" },
        .{ .de = "Punkt", .en = "Period" },
    };
    for (table) |p| {
        if (std.mem.eql(u8, tok, p.de)) return p.en;
    }
    return tok;
}

/// Full key name in English, at compile time ("Strg+Bild ab" → "Ctrl+PgDn").
/// For the fixed defaults in config.zig.
pub fn keyLabelEnStatic(comptime de: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var rest: []const u8 = de;
        while (std.mem.indexOfScalar(u8, rest, '+')) |p| {
            // "Strg++": the last plus is the key itself.
            if (p == 0) break;
            out = out ++ keyTokenEn(rest[0..p]) ++ "+";
            rest = rest[p + 1 ..];
        }
        return out ++ keyTokenEn(rest);
    }
}

test "system language: first variable set wins" {
    try std.testing.expectEqual(Lang.de, fromLocale(null, null, "de_DE.UTF-8"));
    try std.testing.expectEqual(Lang.en, fromLocale(null, null, "en_US.UTF-8"));
    try std.testing.expectEqual(Lang.en, fromLocale("C", null, "de_DE.UTF-8"));
    try std.testing.expectEqual(Lang.de, fromLocale("", "de_AT", "en_GB"));
    try std.testing.expectEqual(Lang.en, fromLocale(null, null, null));
}

test "key names in English" {
    try std.testing.expectEqualStrings("Ctrl+PgDn", comptime keyLabelEnStatic("Strg+Bild ab"));
    try std.testing.expectEqualStrings("Ctrl+Shift+S", comptime keyLabelEnStatic("Strg+Umschalt+S"));
    try std.testing.expectEqualStrings("Alt+Up", comptime keyLabelEnStatic("Alt+Hoch"));
    try std.testing.expectEqualStrings("F12", comptime keyLabelEnStatic("F12"));
    try std.testing.expectEqualStrings("Del", comptime keyLabelEnStatic("Entf"));
    const ja: Text = .{ .de = "Ja", .en = "Yes" };
    try std.testing.expectEqualStrings("Yes", ja.in(.en));
}
