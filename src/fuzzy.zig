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

/// Names and queries longer than this are not considered.
const max_len = 256;

/// Splits text into lowercase characters. `null`: invalid text.
fn decode(bytes: []const u8, out: *[max_len]u21, skip_spaces: bool) ?[]u21 {
    var it = (std.unicode.Utf8View.init(bytes) catch return null).iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (skip_spaces and cp == ' ') continue;
        if (n == max_len) break;
        out[n] = lower(cp);
        n += 1;
    }
    return out[0..n];
}

/// Score when the first query letter sits exactly at `start` and every further
/// one at the next possible position.
fn scoreFrom(want: []const u21, have: []const u21, start: usize) ?i32 {
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
        if (pos == 0 or isSeparator(have[pos - 1])) total += 20;
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
    const want = decode(needle, &want_buf, true) orelse return null;
    const have = decode(hay, &have_buf, false) orelse return null;
    if (want.len == 0) return 0;

    // Try every position where the query could start and keep the best.
    // Otherwise the b from "Tab" wins for "b.txt".
    var best: ?i32 = null;
    for (have, 0..) |h, start| {
        if (h != want[0]) continue;
        const sc = scoreFrom(want, have, start) orelse break;
        if (best == null or sc > best.?) best = sc;
    }
    return best;
}

/// Score for paths: a match within the last component (the file or folder name)
/// counts more than one spread across the folders before it.
pub fn scorePath(needle: []const u8, path: []const u8) ?i32 {
    const whole = score(needle, path) orelse return null;
    const cut = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else return whole;
    const tail = score(needle, path[cut..]) orelse return whole;
    return @max(whole, tail + 40);
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

test "broken text matches nothing" {
    try testing.expect(score("a\xff", "abc") == null);
}
