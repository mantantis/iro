// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Helpers for visible characters.
//!
//! A visible character (grapheme) can consist of several bytes: "ä" has two,
//! "🦅" four, a family of several emoji many more. The cursor may only sit
//! between whole visible characters, never inside one. This file is the only
//! place that computes this.
//!
//! Precondition: lines are valid UTF-8. Loading (rejects anything else) and
//! inserting (checks first) make sure of that.

const std = @import("std");
const vaxis = @import("vaxis");

/// A visible character within a line.
pub const Cluster = struct {
    /// Byte offset from the start of the line.
    start: usize,
    /// Length in bytes.
    len: usize,
    /// Screen column, counted from 0.
    dcol: usize,
    /// Width on screen in cells.
    width: usize,

    pub fn end(self: Cluster) usize {
        return self.start + self.len;
    }
};

pub const Iterator = struct {
    line: []const u8,
    inner: vaxis.unicode.GraphemeIterator,
    tab_width: usize,
    dcol: usize = 0,

    pub fn next(self: *Iterator) ?Cluster {
        const g = self.inner.next() orelse return null;
        const bytes = self.line[g.start .. g.start + g.len];
        const w = clusterWidth(bytes, self.dcol, self.tab_width);
        const c: Cluster = .{ .start = g.start, .len = g.len, .dcol = self.dcol, .width = w };
        self.dcol += w;
        return c;
    }
};

pub fn iterate(line: []const u8, tab_width: usize) Iterator {
    return .{ .line = line, .inner = vaxis.unicode.graphemeIterator(line), .tab_width = tab_width };
}

/// Is this a control character that we show as a dot?
pub fn isControl(bytes: []const u8) bool {
    return bytes.len == 1 and (bytes[0] < 0x20 or bytes[0] == 0x7f) and bytes[0] != '\t';
}

/// Characters you can't see but that can still do harm.
pub const Hidden = enum {
    /// Ordinary visible character.
    none,
    /// Control character (including the C1 range U+0080 to U+009F, which some
    /// terminals interpret as commands). Shown as a dimmed dot.
    control,
    /// Invisible but effective: characters that reverse the reading direction
    /// ("Trojan Source") or have no width at all. Marked prominently.
    sneaky,
};

fn hiddenCodepoint(cp: u21) Hidden {
    return switch (cp) {
        0...0x08, 0x0A...0x1F, 0x7F...0x9F => .control,
        0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF => .sneaky,
        else => .none,
    };
}

/// Classifies a visible character. Only standalone characters count: the
/// invisible joiner inside an emoji is fine.
pub fn hiddenKind(bytes: []const u8) Hidden {
    if (bytes.len == 0 or bytes.len > 4) return .none;
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .none;
    if (n != bytes.len) return .none;
    const cp = std.unicode.utf8Decode(bytes) catch return .none;
    return hiddenCodepoint(cp);
}

/// Makes a name (file, folder) safe for the title and status line: control and
/// invisible characters become "?". Without such characters the name comes back
/// unchanged, without allocating.
pub fn cleanName(arena: std.mem.Allocator, name: []const u8) []const u8 {
    var dirty = false;
    var view = std.unicode.Utf8View.init(name) catch return "?";
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\t' or hiddenCodepoint(cp) != .none) {
            dirty = true;
            break;
        }
    }
    if (!dirty) return name;
    var out: std.ArrayList(u8) = .empty;
    it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch continue;
        if (cp == '\t' or hiddenCodepoint(cp) != .none) {
            out.append(arena, '?') catch return "?";
        } else {
            out.appendSlice(arena, slice) catch return "?";
        }
    }
    return out.items;
}

fn clusterWidth(bytes: []const u8, dcol: usize, tab_width: usize) usize {
    if (bytes.len == 1) {
        if (bytes[0] == '\t') return tab_width - (dcol % tab_width);
        return 1; // ASCII and control characters
    }
    const w = vaxis.gwidth.gwidth(bytes, .unicode);
    // Characters without width of their own (e.g. a lone combining accent)
    // still get a cell so the cursor can reach them.
    return @max(@as(usize, w), 1);
}

/// Next character boundary after `col`, at most the end of the line.
pub fn nextBoundary(line: []const u8, col: usize) usize {
    var it = iterate(line, 1);
    while (it.next()) |c| {
        if (c.end() > col) return c.end();
    }
    return line.len;
}

/// Previous character boundary before `col`, at least 0.
pub fn prevBoundary(line: []const u8, col: usize) usize {
    var prev: usize = 0;
    var it = iterate(line, 1);
    while (it.next()) |c| {
        if (c.end() >= col) return c.start;
        prev = c.end();
    }
    return prev;
}

/// Moves `col` back to the preceding character boundary if it lies inside a
/// character.
pub fn snap(line: []const u8, col: usize) usize {
    if (col >= line.len) return line.len;
    var it = iterate(line, 1);
    while (it.next()) |c| {
        if (c.start == col) return col;
        if (c.end() > col) return c.start;
    }
    return line.len;
}

/// Screen column of byte position `col`.
pub fn displayCol(line: []const u8, col: usize, tab_width: usize) usize {
    var it = iterate(line, tab_width);
    while (it.next()) |c| {
        if (c.start >= col) return c.dcol;
    }
    return it.dcol;
}

/// Byte position of the character boundary closest to screen column `dcol`.
/// Used for clicks and for arrow up/down.
pub fn colAtDisplay(line: []const u8, dcol: usize, tab_width: usize) usize {
    var it = iterate(line, tab_width);
    while (it.next()) |c| {
        if (dcol < c.dcol + c.width) {
            // In the first half of the character: before it, otherwise after
            // it.
            return if ((dcol - c.dcol) * 2 < c.width) c.start else c.end();
        }
    }
    return line.len;
}

/// Total screen width of a line.
pub fn lineWidth(line: []const u8, tab_width: usize) usize {
    var it = iterate(line, tab_width);
    while (it.next()) |_| {}
    return it.dcol;
}

pub const Class = enum { space, word, punct };

/// Rough character class for word jumps, determined by the first byte of the
/// character.
pub fn classOf(bytes: []const u8) Class {
    const b = bytes[0];
    if (b == ' ' or b == '\t') return .space;
    if (b >= 0x80 or std.ascii.isAlphanumeric(b) or b == '_') return .word;
    return .punct;
}

/// Length of the leading whitespace in bytes.
pub fn indentLen(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i;
}

// ───────────────────────────── Tests ─────────────────────────────

const testing = std.testing;

test "invisible and control characters are detected" {
    try testing.expectEqual(Hidden.control, hiddenKind("\x1b"));
    try testing.expectEqual(Hidden.control, hiddenKind("\x7f"));
    try testing.expectEqual(Hidden.control, hiddenKind("\u{9b}"));
    try testing.expectEqual(Hidden.sneaky, hiddenKind("\u{202e}"));
    try testing.expectEqual(Hidden.sneaky, hiddenKind("\u{200b}"));
    try testing.expectEqual(Hidden.none, hiddenKind("\t"));
    try testing.expectEqual(Hidden.none, hiddenKind("ä"));
    try testing.expectEqual(Hidden.none, hiddenKind("👨‍👩‍👧"));

    // Each of these characters must stand alone, otherwise it slips through.
    const line = "a\x1b[31m\u{9b}31m\u{202e}b\u{200b}c";
    var it = iterate(line, 4);
    var controls: usize = 0;
    var sneaky: usize = 0;
    while (it.next()) |c| switch (hiddenKind(line[c.start..c.end()])) {
        .control => controls += 1,
        .sneaky => sneaky += 1,
        .none => {},
    };
    try testing.expectEqual(@as(usize, 2), controls);
    try testing.expectEqual(@as(usize, 2), sneaky);
}

test "names are sanitized for title and status line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("größe 🦅.txt", cleanName(arena, "größe 🦅.txt"));
    try testing.expectEqualStrings("evil?]2;x??[31m.txt", cleanName(arena, "evil\x1b]2;x\x07\x1b[31m.txt"));
    try testing.expectEqualStrings("a?b?c", cleanName(arena, "a\u{9d}b\u{202e}c"));
}

test "boundaries in ASCII" {
    try testing.expectEqual(@as(usize, 1), nextBoundary("abc", 0));
    try testing.expectEqual(@as(usize, 3), nextBoundary("abc", 3));
    try testing.expectEqual(@as(usize, 1), prevBoundary("abc", 2));
    try testing.expectEqual(@as(usize, 0), prevBoundary("abc", 0));
}

test "umlaut is one character of two bytes" {
    const s = "ä!";
    try testing.expectEqual(@as(usize, 2), nextBoundary(s, 0));
    try testing.expectEqual(@as(usize, 0), prevBoundary(s, 2));
    try testing.expectEqual(@as(usize, 0), snap(s, 1));
    try testing.expectEqual(@as(usize, 1), displayCol(s, 2, 4));
}

test "emoji family is a single character" {
    const s = "a👨‍👩‍👧b";
    const after_a = 1;
    const before_b = s.len - 1;
    try testing.expectEqual(before_b, nextBoundary(s, after_a));
    try testing.expectEqual(@as(usize, after_a), prevBoundary(s, before_b));
    try testing.expectEqual(@as(usize, after_a), snap(s, 5));
}

test "emoji is two cells wide" {
    const s = "🦅x";
    try testing.expectEqual(@as(usize, 2), displayCol(s, 4, 4));
    try testing.expectEqual(@as(usize, 3), lineWidth(s, 4));
}

test "tab jumps to the next tab stop" {
    try testing.expectEqual(@as(usize, 4), displayCol("\tx", 1, 4));
    try testing.expectEqual(@as(usize, 4), displayCol("ab\tx", 3, 4));
    try testing.expectEqual(@as(usize, 8), displayCol("abcd\tx", 5, 4));
}

test "click column hits the nearest boundary" {
    try testing.expectEqual(@as(usize, 2), colAtDisplay("abc", 2, 4));
    try testing.expectEqual(@as(usize, 3), colAtDisplay("abc", 99, 4));
    // Tab is 4 wide: first half before, second half after.
    try testing.expectEqual(@as(usize, 0), colAtDisplay("\tx", 1, 4));
    try testing.expectEqual(@as(usize, 1), colAtDisplay("\tx", 3, 4));
    // Emoji is 2 wide.
    try testing.expectEqual(@as(usize, 0), colAtDisplay("🦅x", 0, 4));
    try testing.expectEqual(@as(usize, 4), colAtDisplay("🦅x", 1, 4));
}

test "displayCol and colAtDisplay agree" {
    const lines = [_][]const u8{ "", "abc", "\ta\tb", "Größe 🦅 ende", "a👨‍👩‍👧b", "é̃x" };
    for (lines) |l| {
        var it = iterate(l, 4);
        while (it.next()) |c| {
            try testing.expectEqual(c.start, colAtDisplay(l, displayCol(l, c.start, 4), 4));
        }
    }
}
