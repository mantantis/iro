// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Main menu (Esc or F10): a card in the middle with the most important
//! commands, as known from windowed applications. Each entry has an underlined
//! letter for quick selection and its key on the right; the mouse works too.
//! This file only defines WHAT is in the menu; drawing happens in draw.zig,
//! execution in main.zig.

const std = @import("std");
const config = @import("config.zig");
const Cmd = config.Cmd;
const lang = @import("lang.zig");
const Lang = lang.Lang;

pub const Entry = struct {
    /// `null`: separator.
    cmd: ?Cmd = null,
    label: lang.Text = .{ .de = "", .en = "" },
    /// Nerd Font icon (only with `icons = true`).
    icon: []const u8 = "",
    /// The underlined letter, lowercase, per language.
    hot: Hot = .{ .de = 0, .en = 0 },
};

pub const Hot = struct {
    de: u21,
    en: u21,

    pub fn in(self: Hot, l: Lang) u21 {
        return if (l == .en) self.en else self.de;
    }
};

const sep: Entry = .{};

pub const entries = [_]Entry{
    .{ .cmd = .new_tab, .label = .{ .de = "Neue Datei", .en = "New file" }, .icon = "\u{f016}", .hot = .{ .de = 'n', .en = 'n' } },
    .{ .cmd = .open, .label = .{ .de = "Öffnen …", .en = "Open …" }, .icon = "\u{f07c}", .hot = .{ .de = 'ö', .en = 'o' } },
    .{ .cmd = .save, .label = .{ .de = "Speichern", .en = "Save" }, .icon = "\u{f0c7}", .hot = .{ .de = 's', .en = 's' } },
    .{ .cmd = .save_as, .label = .{ .de = "Speichern unter …", .en = "Save as …" }, .icon = "\u{f0c5}", .hot = .{ .de = 'u', .en = 'a' } },
    sep,
    .{ .cmd = .tree, .label = .{ .de = "Dateibaum", .en = "File tree" }, .icon = "\u{f0e8}", .hot = .{ .de = 'd', .en = 't' } },
    .{ .cmd = .gear, .label = .{ .de = "Gear wechseln", .en = "Switch gear" }, .icon = "\u{f089b}", .hot = .{ .de = 'g', .en = 'g' } },
    .{ .cmd = .palette, .label = .{ .de = "Befehlspalette", .en = "Command palette" }, .icon = "\u{f120}", .hot = .{ .de = 'p', .en = 'p' } },
    .{ .cmd = .settings, .label = .{ .de = "Einstellungen …", .en = "Settings …" }, .icon = "\u{f013}", .hot = .{ .de = 'e', .en = 'e' } },
    sep,
    .{ .cmd = .help, .label = .{ .de = "Hilfe", .en = "Help" }, .icon = "\u{f059}", .hot = .{ .de = 'h', .en = 'h' } },
    .{ .cmd = .about, .label = .{ .de = "Über iro", .en = "About iro" }, .icon = "\u{f05a}", .hot = .{ .de = 'i', .en = 'i' } },
    sep,
    .{ .cmd = .quit, .label = .{ .de = "Beenden", .en = "Quit" }, .icon = "\u{f011}", .hot = .{ .de = 'b', .en = 'q' } },
};

fn lower(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        'Ä' => 'ä',
        'Ö' => 'ö',
        'Ü' => 'ü',
        else => cp,
    };
}

/// Where the underlined letter sits in the name: byte offset and length.
pub fn hotSpan(e: Entry, l: Lang) ?struct { start: usize, len: usize } {
    var it = (std.unicode.Utf8View.init(e.label.in(l)) catch return null).iterator();
    var start: usize = 0;
    while (it.nextCodepointSlice()) |s| : (start += s.len) {
        const cp = std.unicode.utf8Decode(s) catch continue;
        if (lower(cp) == e.hot.in(l)) return .{ .start = start, .len = s.len };
    }
    return null;
}

/// Which entry belongs to this letter? For Ö, o works too.
pub fn byHotkey(cp: u21, l: Lang) ?usize {
    const c = lower(cp);
    for (entries, 0..) |e, i| {
        const h = e.hot.in(l);
        if (e.cmd != null and (h == c or (c == 'o' and h == 'ö'))) return i;
    }
    return null;
}

pub fn isItem(i: usize) bool {
    return i < entries.len and entries[i].cmd != null;
}

pub fn first() usize {
    return 0;
}

/// Next selectable entry in direction `dir`, skipping separators. Wraps around
/// at both ends.
pub fn move(sel: usize, dir: isize) usize {
    const n: isize = entries.len;
    var i: isize = @intCast(@min(sel, entries.len - 1));
    var tries: usize = 0;
    while (tries < entries.len) : (tries += 1) {
        i = @mod(i + dir, n);
        if (entries[@intCast(i)].cmd != null) return @intCast(i);
    }
    return sel;
}

pub fn last() usize {
    return move(0, -1);
}

test "underlined letters are unique and part of the name, in both languages" {
    for ([_]Lang{ .de, .en }) |l| {
        for (entries, 0..) |e, i| {
            if (e.cmd == null) continue;
            try std.testing.expect(hotSpan(e, l) != null);
            try std.testing.expectEqual(@as(?usize, i), byHotkey(e.hot.in(l), l));
        }
    }
    try std.testing.expectEqual(byHotkey('ö', .de), byHotkey('O', .de));
    try std.testing.expectEqual(@as(usize, 1), hotSpan(entries[11], .de).?.len);
    try std.testing.expectEqualStrings("i", entries[11].label.de[hotSpan(entries[11], .de).?.start..][0..1]);
    try std.testing.expectEqual(byHotkey('q', .en), byHotkey('b', .de));
}

test "selection skips separators and wraps around" {
    try std.testing.expectEqual(@as(usize, 5), move(3, 1));
    try std.testing.expectEqual(@as(usize, 3), move(5, -1));
    try std.testing.expectEqual(entries.len - 1, move(0, -1));
    try std.testing.expectEqual(@as(usize, 0), move(entries.len - 1, 1));
    try std.testing.expect(isItem(last()));
}
