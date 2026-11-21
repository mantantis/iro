// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Word and keyword completion straight from the open buffers and the active
//! language's vocabulary: fast, local, no language server.

const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const Pos = buffer.Pos;

pub const Candidate = struct {
    word: []const u8,
    is_keyword: bool,
};

pub fn isWordByte(b: u8, allow_dash: bool) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_' or
        b >= 0x80 or
        (allow_dash and b == '-');
}

/// Returns the word prefix directly left of the cursor (empty if the token
/// starts with a digit or `-`, or no word character precedes it).
pub fn wordPrefix(line: []const u8, cursor_col: usize, allow_dash: bool) []const u8 {
    const col = @min(cursor_col, line.len);
    var start = col;
    while (start > 0 and isWordByte(line[start - 1], allow_dash)) : (start -= 1) {}
    if (start == col) return "";
    const first = line[start];
    if (first == '-' or (first >= '0' and first <= '9')) return "";
    return line[start..col];
}

fn matchesPrefix(word: []const u8, prefix: []const u8, case_insensitive: bool) bool {
    if (prefix.len == 0 or word.len <= prefix.len) return false;
    if (word[0] == '-' or (word[0] >= '0' and word[0] <= '9')) return false;
    return if (case_insensitive)
        std.ascii.startsWithIgnoreCase(word, prefix)
    else
        std.mem.startsWith(u8, word, prefix);
}

/// Collects up to `max_items` matching completions (exact case first, then
/// case-insensitive), without duplicates and without the word already typed.
pub fn collect(
    arena: Allocator,
    buf: *const Buffer,
    cursor: Pos,
    prefix: []const u8,
    keywords: []const []const u8,
    allow_dash: bool,
    max_items: usize,
) Allocator.Error![]Candidate {
    if (max_items == 0 or prefix.len == 0) return &.{};

    var out: std.ArrayList(Candidate) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try seen.put(arena, prefix, {});

    const cur_line_bytes = buf.line(cursor.line);
    const col = @min(cursor.col, cur_line_bytes.len);
    var cur_start = col;
    while (cur_start > 0 and isWordByte(cur_line_bytes[cur_start - 1], allow_dash)) : (cur_start -= 1) {}
    var cur_end = col;
    while (cur_end < cur_line_bytes.len and isWordByte(cur_line_bytes[cur_end], allow_dash)) : (cur_end += 1) {}

    const start_line = cursor.line -| 1000;
    const end_line = @min(buf.lineCount(), cursor.line + 1000);

    var pass: usize = 0;
    while (pass < 2 and out.items.len < max_items) : (pass += 1) {
        const ci = pass == 1;

        var line_idx = start_line;
        while (line_idx < end_line and out.items.len < max_items) : (line_idx += 1) {
            const line = buf.line(line_idx);
            var i: usize = 0;
            while (i < line.len and out.items.len < max_items) {
                if (!isWordByte(line[i], allow_dash)) {
                    i += 1;
                    continue;
                }
                const w_start = i;
                while (i < line.len and isWordByte(line[i], allow_dash)) : (i += 1) {}
                const w_end = i;
                // Skip the word currently being typed under the cursor.
                if (line_idx == cursor.line and w_start == cur_start and w_end == cur_end) continue;
                const word = line[w_start..w_end];
                if (!matchesPrefix(word, prefix, ci)) continue;
                if (seen.contains(word)) continue;
                const duped = try arena.dupe(u8, word);
                try seen.put(arena, duped, {});
                try out.append(arena, .{ .word = duped, .is_keyword = false });
            }
        }

        for (keywords) |kw| {
            if (out.items.len >= max_items) break;
            if (!matchesPrefix(kw, prefix, ci)) continue;
            if (seen.contains(kw)) continue;
            try seen.put(arena, kw, {});
            try out.append(arena, .{ .word = kw, .is_keyword = true });
        }
    }

    return out.items;
}

test "wordPrefix detects the word before the cursor" {
    try std.testing.expectEqualStrings("fenst", wordPrefix("  const fenst", 13, false));
    try std.testing.expectEqualStrings("background-col", wordPrefix("background-col: #000", 14, true));
    try std.testing.expectEqualStrings("", wordPrefix("123abc", 6, false));
    try std.testing.expectEqualStrings("", wordPrefix("foo ", 4, false));
    try std.testing.expectEqualStrings("", wordPrefix("--flag", 6, true));
}

test "collect finds words from text and language keywords without duplicates" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var buf = try Buffer.fromBytes(gpa, "const fensterbreite = 80;\nfensterbreite + 1;\nfenst\nCONST Foo = 1;\n");
    defer buf.deinit();

    const items = try collect(
        arena_state.allocator(),
        &buf,
        .{ .line = 2, .col = 5 },
        "fen",
        &.{ "fennec", "fensterbreite", "fn" },
        false,
        8,
    );
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("fensterbreite", items[0].word);
    try std.testing.expect(!items[0].is_keyword);
    try std.testing.expectEqualStrings("fennec", items[1].word);
    try std.testing.expect(items[1].is_keyword);

    // Second pass also matches case-insensitively ("con" finds "CONST").
    var buf2 = try Buffer.fromBytes(gpa, "Configuration\ncon\n");
    defer buf2.deinit();
    const ci_items = try collect(arena_state.allocator(), &buf2, .{ .line = 1, .col = 3 }, "con", &.{}, false, 8);
    try std.testing.expectEqual(@as(usize, 1), ci_items.len);
    try std.testing.expectEqualStrings("Configuration", ci_items[0].word);
}
