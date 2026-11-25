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
    /// A visible character with an invisible joiner glued to it (zero-width
    /// joiner or non-joiner, outside an emoji sequence). `is‌Admin` looks
    /// like `isAdmin` but is a different name. Drawn as itself, but marked.
    joined,
};

fn hiddenCodepoint(cp: u21) Hidden {
    return switch (cp) {
        0...0x08, 0x0A...0x1F, 0x7F...0x9F => .control,
        0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF => .sneaky,
        else => .none,
    };
}

/// Classifies a visible character. The zero-width joiner and non-joiner
/// attach to the character before them, so they are looked for inside the
/// whole cluster; only the joiner between emoji is fine.
pub fn hiddenKind(bytes: []const u8) Hidden {
    if (bytes.len == 0) return .none;
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .none;
    if (n > bytes.len) return .none;
    if (n == bytes.len) {
        const cp = std.unicode.utf8Decode(bytes) catch return .none;
        return hiddenCodepoint(cp);
    }
    var view = std.unicode.Utf8View.init(bytes) catch return .none;
    var it = view.iterator();
    var prev: u21 = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp == 0x200C or (cp == 0x200D and !isEmojiPart(prev))) return .joined;
        prev = cp;
    }
    return .none;
}

/// The first character of a cluster, without what is attached to it.
pub fn baseChar(bytes: []const u8) []const u8 {
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return bytes[0..1];
    return bytes[0..@min(n, bytes.len)];
}

/// Can a zero-width joiner after `cp` be part of an emoji sequence
/// (👨‍👩‍👧, ❤️‍🔥, 🏳️‍🌈)? Rough but sufficient: emoji blocks, symbols, the
/// emoji variation selector and skin tones.
fn isEmojiPart(cp: u21) bool {
    return cp >= 0x1F000 or (cp >= 0x2190 and cp <= 0x2BFF) or cp == 0xFE0F or cp == 0x20E3;
}

/// Same rules as `cleanName`, but in place, for text that already sits in a
/// buffer (status messages, output of other programs): every control and
/// invisible character becomes "?". Returns the (possibly shorter) result.
pub fn neutralize(buf: []u8) []u8 {
    var r: usize = 0;
    var w: usize = 0;
    while (r < buf.len) {
        const n = std.unicode.utf8ByteSequenceLength(buf[r]) catch 1;
        const cp: ?u21 = if (r + n <= buf.len) (std.unicode.utf8Decode(buf[r .. r + n]) catch null) else null;
        if (cp == null or cp.? == '\t' or hiddenCodepoint(cp.?) != .none) {
            buf[w] = '?';
            w += 1;
        } else {
            std.mem.copyForwards(u8, buf[w .. w + n], buf[r .. r + n]);
            w += n;
        }
        r += @min(n, buf.len - r);
    }
    return buf[0..w];
}

/// Makes a name (file, folder) safe for the title and status line: control and
/// invisible characters become "?". Without such characters the name comes back
/// unchanged, without allocating.
/// Turns CRLF and lone CR into LF, in place. Returns the shortened text.
pub fn unifyLineBreaks(buf: []u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\r') {
            buf[w] = '\n';
            if (i + 1 < buf.len and buf[i + 1] == '\n') i += 1;
        } else buf[w] = buf[i];
        w += 1;
    }
    return buf[0..w];
}

test "line breaks from any system become LF" {
    var buf = "a\r\nb\rc\nd\r\r\ne\r".*;
    try std.testing.expectEqualStrings("a\nb\nc\nd\n\ne\n", unifyLineBreaks(&buf));
    var none = "kein umbruch".*;
    try std.testing.expectEqualStrings("kein umbruch", unifyLineBreaks(&none));
}

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
    if (col >= line.len) return line.len;
    const from = restartPoint(line, col);
    var it = iterate(line[from..], 1);
    while (it.next()) |c| {
        if (from + c.end() > col) return from + c.end();
    }
    return line.len;
}

/// Previous character boundary before `col`, at least 0.
pub fn prevBoundary(line: []const u8, col: usize) usize {
    if (col == 0) return 0;
    const to = @min(col, line.len);
    const from = restartPoint(line, to - 1);
    var prev: usize = from;
    var it = iterate(line[from..], 1);
    while (it.next()) |c| {
        if (from + c.end() >= to) return from + c.start;
        prev = from + c.end();
    }
    return prev;
}

/// The closest position at or before `pos` where a character certainly
/// begins, so the character boundaries around `pos` can be found from there
/// instead of from the start of the line. Word jumps and double clicks would
/// otherwise take quadratic time on long lines (minified JSON, base64).
///
/// By the Unicode rules for grapheme clusters (UAX #29), an ASCII character,
/// a CJK ideograph or a kana letter never attaches to what comes before it,
/// unless that is a "prepend" character (a few Arabic and Indic signs).
fn restartPoint(line: []const u8, pos: usize) usize {
    var s = @min(pos, line.len);
    while (s > 0) : (s -= 1) {
        if (s < line.len and standsAlone(line, s)) return s;
    }
    return 0;
}

fn standsAlone(line: []const u8, s: usize) bool {
    const b = line[s];
    if (b >= 0x80) {
        // CJK ideographs and kana are three bytes long (lead byte E3–E9).
        if (b < 0xE3 or b > 0xE9 or s + 3 > line.len) return false;
        const cp = std.unicode.utf8Decode(line[s .. s + 3]) catch return false;
        const simple = (cp >= 0x3041 and cp <= 0x3096) or (cp >= 0x30A1 and cp <= 0x30FA) or
            (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x4E00 and cp <= 0x9FFF);
        if (!simple) return false;
    }
    if (s == 0 or line[s - 1] < 0x80) return true;
    // Find the start of the previous code point (at most 4 bytes back).
    var p = s - 1;
    while (p > 0 and s - p < 4 and line[p] & 0xC0 == 0x80) p -= 1;
    // Only after a complete, valid sequence is the decoder sure to start
    // afresh at `s`: it either read the sequence as one, or (if its first byte
    // was swallowed by broken UTF-8 before it) rejects the rest byte by byte.
    // After broken UTF-8, where it stands depends on what came earlier.
    // (`utf8Decode` must get exactly one whole sequence.)
    const n = std.unicode.utf8ByteSequenceLength(line[p]) catch return false;
    if (n != s - p) return false;
    const cp = std.unicode.utf8Decode(line[p..s]) catch return false;
    return !isPrepend(cp);
}

/// Grapheme_Cluster_Break=Prepend (Unicode 16): attaches to what follows.
fn isPrepend(cp: u21) bool {
    return switch (cp) {
        0x0600...0x0605, 0x06DD, 0x070F, 0x0890...0x0891, 0x08E2, 0x0D4E => true,
        0x110BD, 0x110CD, 0x111C2...0x111C3, 0x1193F, 0x11941, 0x11A3A, 0x11A84...0x11A89, 0x11D46, 0x11F02 => true,
        else => false,
    };
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

/// One screen row of a soft-wrapped line: the characters whose display
/// column lies in `[start, end)`.
pub const Row = struct { start: usize, end: usize };

/// Soft wrap: splits a line into rows of `w` screen cells, at character
/// boundaries. A character that no longer fits at the end of a row (a wide
/// CJK character or emoji in the last cell) moves to the next row whole and
/// leaves that cell empty. Cutting by screen columns showed such a character
/// on neither row. Every line has at least one row.
pub const RowIterator = struct {
    it: Iterator,
    w: usize,
    start: usize = 0,
    pending: ?Cluster = null,
    done: bool = false,

    pub fn next(self: *RowIterator) ?Row {
        if (self.done) return null;
        const start = self.start;
        while (true) {
            const c = self.pending orelse self.it.next() orelse {
                self.done = true;
                return .{ .start = start, .end = self.it.dcol };
            };
            self.pending = null;
            // A character wider than a whole row stays where it is (cut off).
            if (c.dcol > start and c.dcol + c.width > start + self.w) {
                self.pending = c;
                self.start = c.dcol;
                return .{ .start = start, .end = c.dcol };
            }
        }
    }
};

pub fn wrapRows(line: []const u8, tab_width: usize, w: usize) RowIterator {
    return .{ .it = iterate(line, tab_width), .w = @max(w, 1) };
}

/// How many rows a soft-wrapped line takes. One more if the cursor
/// (`cursor_dcol`, its display column) sits at the end of a full last row:
/// it needs a cell of its own.
pub fn wrapRowCount(line: []const u8, tab_width: usize, w: usize, cursor_dcol: ?usize) usize {
    var rows = wrapRows(line, tab_width, w);
    var n: usize = 0;
    var last: Row = .{ .start = 0, .end = 0 };
    while (rows.next()) |r| : (n += 1) last = r;
    if (cursor_dcol) |d| {
        if (d == last.end and last.end >= last.start + rows.w) n += 1;
    }
    return n;
}

/// The row (counted like `wrapRowCount`) that shows display column `dcol`.
pub fn wrapRowOf(line: []const u8, tab_width: usize, w: usize, dcol: usize) usize {
    var rows = wrapRows(line, tab_width, w);
    var k: usize = 0;
    while (rows.next()) |r| : (k += 1) {
        if (dcol < r.end) return k;
        if (rows.done) return if (dcol >= r.start + rows.w) k + 1 else k;
    }
    return k;
}

/// Byte position for a click at screen column `x` of row `row`. Past the
/// end of a row that continues below, the cursor stays on the last character
/// of that row instead of jumping to the next one.
pub fn wrapColAt(line: []const u8, tab_width: usize, w: usize, row: usize, x: usize) usize {
    var rows = wrapRows(line, tab_width, w);
    var k: usize = 0;
    while (rows.next()) |r| : (k += 1) {
        if (k < row) continue;
        if (rows.done) return colAtDisplay(line, r.start + x, tab_width);
        var col = colAtDisplay(line, @min(r.start + x, r.end - 1), tab_width);
        if (displayCol(line, col, tab_width) >= r.end) col = prevBoundary(line, col);
        return col;
    }
    // The extra row for the cursor at the end of the line.
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
        .none, .joined => {},
    };
    try testing.expectEqual(@as(usize, 2), controls);
    try testing.expectEqual(@as(usize, 2), sneaky);
}

test "zero-width joiners glued to a letter are caught, emoji stay clean" {
    // `is\u{200C}Admin` looks like `isAdmin`: the joiner hides inside "s".
    const line = "is\u{200C}Admin = x\u{200D}y";
    var it = iterate(line, 4);
    var joined: usize = 0;
    while (it.next()) |c| {
        const bytes = line[c.start..c.end()];
        if (hiddenKind(bytes) == .joined) {
            joined += 1;
            try testing.expectEqual(@as(usize, 1), baseChar(bytes).len);
        }
    }
    try testing.expectEqual(@as(usize, 2), joined);
    // Joiners that build emoji are fine.
    try testing.expectEqual(Hidden.none, hiddenKind("👨‍👩‍👧"));
    try testing.expectEqual(Hidden.none, hiddenKind("❤️‍🔥"));
    try testing.expectEqual(Hidden.none, hiddenKind("🏳️‍🌈"));
    try testing.expectEqual(Hidden.none, hiddenKind("👍🏽"));
    // A combining accent is visible, not hidden.
    try testing.expectEqual(Hidden.none, hiddenKind("e\u{0301}"));
}

test "status text is neutralized in place" {
    var buf = "ok \u{202E}txt.exe\u{202C} \x1b[2J \u{200B}x\u{2066}y é".*;
    const out = neutralize(&buf);
    try testing.expectEqualStrings("ok ?txt.exe? ?[2J ?x?y é", out);
    // Nothing to do: unchanged.
    var plain = "Gespeichert: a.txt (3 Zeilen)".*;
    try testing.expectEqualStrings("Gespeichert: a.txt (3 Zeilen)", neutralize(&plain));
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

fn slowNextBoundary(line: []const u8, col: usize) usize {
    var it = iterate(line, 1);
    while (it.next()) |c| {
        if (c.end() > col) return c.end();
    }
    return line.len;
}

fn slowPrevBoundary(line: []const u8, col: usize) usize {
    var prev: usize = 0;
    var it = iterate(line, 1);
    while (it.next()) |c| {
        if (c.end() >= col) return c.start;
        prev = c.end();
    }
    return prev;
}

test "character boundaries found from a restart point match a scan from the line start" {
    // Pieces that test the restart rules: prepend signs before ASCII and CJK,
    // emoji sequences, flags, combining marks, kana with voicing marks,
    // Hangul jamo, invalid and truncated UTF-8.
    const pieces = [_][]const u8{
        "a",          " ",           "{",          "\"",            "\t",
        "\u{0600}",   "\u{0605}",    "\u{110BD}",  "\u{0301}",      "\u{200D}",
        "\u{FE0F}",   "👨‍👩‍👧",      "❤️‍🔥",        "🇩🇪",           "\u{1F1E9}",
        "日",         "本",          "か",         "\u{3099}",      "ア",
        "\u{1100}",   "\u{1161}",    "한",         "é",             "e\u{0301}",
        "\xff",       "\xe3\x81",    "\xe4",       "\u{094D}",      "\u{0915}",
        "\r",         "\u{0644}",    "🏳️‍🌈",       "\u{1F3FB}",     "z",
        "\xe3\xe3",   "\xf0\x9f",    "\x81",       "\xed\xa0\x80",  "\xe0\x80",
    };
    var prng = std.Random.DefaultPrng.init(0x1ce);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    for (0..3000) |_| {
        var len: usize = 0;
        while (true) {
            const piece = pieces[rnd.uintLessThan(usize, pieces.len)];
            if (len + piece.len > buf.len or rnd.uintLessThan(u8, 24) == 0) break;
            @memcpy(buf[len .. len + piece.len], piece);
            len += piece.len;
        }
        const line = buf[0..len];
        for (0..len + 1) |col| {
            std.testing.expectEqual(slowNextBoundary(line, col), nextBoundary(line, col)) catch |err| {
                std.debug.print("next: line {x} col {d}\n", .{ line, col });
                return err;
            };
            std.testing.expectEqual(slowPrevBoundary(line, col), prevBoundary(line, col)) catch |err| {
                std.debug.print("prev: line {x} col {d}\n", .{ line, col });
                return err;
            };
        }
    }
}

fn expectRows(line: []const u8, w: usize, want: []const Row) !void {
    var rows = wrapRows(line, 4, w);
    for (want) |r| try std.testing.expectEqual(r, rows.next().?);
    try std.testing.expect(rows.next() == null);
}

test "soft wrap moves a wide character that does not fit to the next row" {
    // 日 would start in the last cell of the row: it moves down whole.
    try expectRows("abcdefg日x", 8, &.{ .{ .start = 0, .end = 7 }, .{ .start = 7, .end = 10 } });
    // It fits exactly.
    try expectRows("abcdef日x", 8, &.{ .{ .start = 0, .end = 8 }, .{ .start = 8, .end = 9 } });
    // Emoji, and a run of wide characters on an odd width.
    try expectRows("ab👨‍👩‍👧cd", 3, &.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 5 }, .{ .start = 5, .end = 6 } });
    try expectRows("日本語です", 5, &.{ .{ .start = 0, .end = 4 }, .{ .start = 4, .end = 8 }, .{ .start = 8, .end = 10 } });
    // Empty line and a character wider than the row.
    try expectRows("", 8, &.{.{ .start = 0, .end = 0 }});
    try expectRows("日本", 1, &.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 4 } });

    // The cursor at the end of a full row needs a row of its own.
    try std.testing.expectEqual(@as(usize, 1), wrapRowCount("abcdef日", 8, 8, null));
    try std.testing.expectEqual(@as(usize, 2), wrapRowCount("abcdef日", 8, 8, 8));
    try std.testing.expectEqual(@as(usize, 1), wrapRowOf("abcdef日", 8, 8, 8));
    try std.testing.expectEqual(@as(usize, 1), wrapRowOf("abcdefg日x", 8, 8, 7));
    try std.testing.expectEqual(@as(usize, 0), wrapRowOf("abcdefg日x", 8, 8, 6));

    // A click in the cell left empty stays on the row: before the "g".
    try std.testing.expectEqual(@as(usize, 6), wrapColAt("abcdefg日x", 8, 8, 0, 7));
    // On the wide character itself, and past the end of the last row.
    try std.testing.expectEqual(@as(usize, 7), wrapColAt("abcdefg日x", 8, 8, 1, 0));
    try std.testing.expectEqual(@as(usize, 11), wrapColAt("abcdefg日x", 8, 8, 1, 6));
    try std.testing.expectEqual(@as(usize, 9), wrapColAt("abcdef日", 8, 8, 1, 0));
}

test "soft wrap of narrow text matches cutting by screen columns" {
    var prng = std.Random.DefaultPrng.init(0x3a9);
    const rnd = prng.random();
    var buf: [200]u8 = undefined;
    for (0..500) |_| {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = "abc xyz_.-"[rnd.uintLessThan(usize, 10)];
        const line = buf[0..len];
        const w = 8 + rnd.uintLessThan(usize, 40);
        const rows_old = @max(@as(usize, 1), (len + w - 1) / w);
        try std.testing.expectEqual(rows_old, wrapRowCount(line, 4, w, null));
        const eol_extra = len > 0 and len % w == 0;
        try std.testing.expectEqual(rows_old + @intFromBool(eol_extra), wrapRowCount(line, 4, w, len));
        for (0..len + 1) |d| try std.testing.expectEqual(d / w, wrapRowOf(line, 4, w, d));
    }
}
