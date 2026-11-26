// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Fuzzy matching for the command palette: the typed letters must appear in the
//! name in order, but not necessarily adjacent. "gtl" finds "Go to line". The
//! better the fit, the higher the score.

const std = @import("std");

/// Lowercase of a character. Knows the ASCII alphabet and Ä, Ö, Ü.
fn lower(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC4, 0xD6, 0xDC => cp + 32,
        else => cp,
    };
}

/// Does a new word start after this character?
fn isSeparator(cp: u21) bool {
    return switch (cp) {
        ' ', '/', '.', '-', '_', ':', '+' => true,
        else => false,
    };
}

/// Queries are cut after this many characters. Longer names keep their last
/// characters, since that is where a path has its file name.
const max_len = 256;

const Decoded = struct {
    chars: []u21,
    /// The start was cut off: its first character is no word start.
    cut: bool = false,
};

/// Splits text into lowercase characters. `null`: invalid text.
fn decode(bytes: []const u8, out: *[max_len]u21, skip_spaces: bool) ?Decoded {
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (it.nextCodepoint()) |cp| {
        if (skip_spaces and cp == ' ') continue;
        if (n == max_len) break;
        out[n] = lower(cp);
        n += 1;
    }
    return .{ .chars = out[0..n] };
}

/// Like `decode`, but too long text keeps its last `max_len` characters.
fn decodeTail(bytes: []const u8, out: *[max_len]u21) ?Decoded {
    if (bytes.len <= max_len) return decode(bytes, out, false);
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    // Walk back over max_len character starts (UTF-8 continuation bytes are
    // 10xxxxxx).
    var start = bytes.len;
    var count: usize = 0;
    while (start > 0 and count < max_len) {
        start -= 1;
        if (bytes[start] & 0xC0 != 0x80) count += 1;
    }
    const d = decode(bytes[start..], out, false) orelse return null;
    return .{ .chars = d.chars, .cut = start > 0 };
}

/// Score when the first query letter sits exactly at `start` and every further
/// one at the next possible position.
fn scoreFrom(want: []const u21, have: []const u21, cut: bool, start: usize) ?i32 {
    var total: i32 = 0;
    var pos = start;
    var last_hit: ?usize = null;
    for (want) |n| {
        while (pos < have.len and have[pos] != n) pos += 1;
        if (pos == have.len) return null;
        total += 10;
        // Adjacent hits and hits at word starts count more.
        if (last_hit) |l| {
            if (l + 1 == pos) total += 15;
        }
        if (if (pos == 0) !cut else isSeparator(have[pos - 1])) total += 20;
        last_hit = pos;
        pos += 1;
    }
    // The later the match starts, the worse.
    return total - @as(i32, @intCast(@min(start, 10)));
}

/// How well `needle` matches `hay`. `null`: no match at all. Spaces in the
/// query are ignored. An empty query matches everything.
pub fn score(needle: []const u8, hay: []const u8) ?i32 {
    var want_buf: [max_len]u21 = undefined;
    var have_buf: [max_len]u21 = undefined;
    const want = (decode(needle, &want_buf, true) orelse return null).chars;
    const hd = decodeTail(hay, &have_buf) orelse return null;
    const have = hd.chars;
    if (want.len == 0) return 0;

    // Try every position where the query could start and keep the best.
    // Otherwise the b from "Tab" wins for "b.txt".
    var best: ?i32 = null;
    for (have, 0..) |h, start| {
        if (h != want[0]) continue;
        const sc = scoreFrom(want, have, hd.cut, start) orelse break;
        if (best == null or sc > best.?) best = sc;
    }
    return best;
}

/// Score for paths: a match within the last component (the file or folder name)
/// counts more than one spread across the folders before it.
/// A path longer than `max_len` characters is judged by its end, and its file
/// name alone always counts.
pub fn scorePath(needle: []const u8, path: []const u8) ?i32 {
    const whole = score(needle, path);
    const cut = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else return whole;
    const tail = (score(needle, path[cut..]) orelse return whole) + 40;
    return if (whole) |w| @max(w, tail) else tail;
}

// ───────────── Tests ─────────────

const testing = std.testing;

test "letters must appear in order" {
    try testing.expect(score("gz", "Gehe zu Zeile") != null);
    try testing.expect(score("zg", "Gehe") == null);
    try testing.expect(score("xyz", "Gehe zu Zeile") == null);
    try testing.expectEqual(@as(?i32, 0), score("", "egal"));
    try testing.expectEqual(@as(?i32, 0), score("  ", "egal"));
}

test "case-insensitive, umlauts included" {
    try testing.expect(score("SPEICHERN", "Datei speichern") != null);
    try testing.expect(score("öffnen", "Datei Öffnen") != null);
    try testing.expect(score("rückg", "Rückgängig") != null);
}

test "word starts and contiguous matches win" {
    // "tab" at a word start beats scattered letters.
    try testing.expect(score("tab", "Tab schließen").? > score("tab", "Stadtbad").?);
    // Initial letters of words beat letters inside a word.
    try testing.expect(score("gz", "Gehe zu Zeile").? > score("gz", "Rückgängig zuletzt").?);
    // Spaces in the query don't matter.
    try testing.expectEqual(score("gehezu", "Gehe zu Zeile"), score("gehe zu", "Gehe zu Zeile"));
}

test "the best start counts, not the first" {
    // The b from "Tab" must not hide the match in the file name.
    try testing.expect(score("b.txt", "Gehe zu Tab: b.txt").? > score("b.txt", "Gehe zu Tab: a.txt").?);
}

test "for paths the final name counts more" {
    try testing.expect(scorePath("iro", "~/Projekte/iro").? > scorePath("iro", "~/Documents/archive/rclone_sync").?);
    try testing.expect(scorePath("kitty", "kitty/kitty.conf").? > scorePath("kitty", "kitty/themes/dunkel.conf").?);
    // Matching across folders and name still works.
    try testing.expect(scorePath("hyprconf", ".config/hypr/hyprland.conf") != null);
    try testing.expect(scorePath("xyz", "a/b") == null);
}

test "long paths: the end counts" {
    // 300 characters of folders in front of the file name, partly umlauts.
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (0..30) |_| try w.writeAll("ordnerä/x/");
    try w.writeAll("tief/hyprland.conf");
    const long = w.buffered();
    try testing.expect(try std.unicode.utf8CountCodepoints(long) > max_len);

    try testing.expect(scorePath("hyprland", long) != null);
    // Across the last folder and the name.
    try testing.expect(scorePath("tiefhypr", long) != null);
    // Only what is cut off at the front no longer counts as a word start, the
    // match still works.
    try testing.expect(score("hyprland.conf", long) != null);
    // As good as the same file in a short path: the name decides.
    try testing.expectEqual(scorePath("hyprland", "tief/hyprland.conf"), scorePath("hyprland", long));
    try testing.expect(scorePath("zzz", long) == null);
    try testing.expect(scorePath("a\xff", long) == null);
}

test "cut-off start is no word start" {
    var buf: [600]u8 = undefined;
    @memset(buf[0..300], 'b');
    @memcpy(buf[300..303], "abc");
    const s = buf[0..303];
    // The first kept character is a "b" in the middle of the b-run: a match
    // there must not get the word-start bonus (20) a real start gets.
    try testing.expectEqual(score("bbb", "bbbb").? - 20, score("bbb", s).?);
}

test "broken text matches nothing" {
    try testing.expect(score("a\xff", "abc") == null);
}
