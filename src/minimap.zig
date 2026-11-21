// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Braille minimap: a scaled-down silhouette of the whole file at the right
//! edge.
//!
//! Each terminal cell shows a 2x4-dot Braille pattern (`U+2800..U+28FF`). With
//! `width = 6` cells this gives 12 horizontal dot columns (each covering 6
//! visible text columns) and 4 lines per screen row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const editor = @import("editor.zig");
const gitdiff = @import("gitdiff.zig");
const text = @import("text.zig");

pub const width: usize = 6;
const cols_per_dot: usize = 6;

pub const RowKind = enum { normal, cursor, search_hit, git_added, git_changed, git_deleted };

pub const Row = struct {
    cells: [width][3]u8,
    in_view: bool,
    kind: RowKind,
};

/// Encodes an 8-bit Braille dot mask as 3-byte UTF-8 (`U+2800..U+28FF`).
pub fn encodeBraille(mask: u8) [3]u8 {
    const cp: u21 = 0x2800 + @as(u21, mask);
    return .{
        0xE0 | @as(u8, @intCast(cp >> 12)),
        0x80 | @as(u8, @intCast((cp >> 6) & 0x3F)),
        0x80 | @as(u8, @intCast(cp & 0x3F)),
    };
}

fn dotBit(dx: usize, dy: usize) u8 {
    return switch (dy) {
        0 => if (dx == 0) 0x01 else 0x08,
        1 => if (dx == 0) 0x02 else 0x10,
        2 => if (dx == 0) 0x04 else 0x20,
        else => if (dx == 0) 0x40 else 0x80,
    };
}

fn kindRank(k: RowKind) u8 {
    return switch (k) {
        .normal => 0,
        .git_deleted => 1,
        .git_added => 2,
        .git_changed => 3,
        .search_hit => 4,
        .cursor => 5,
    };
}

fn promoteKind(cur: *RowKind, cand: RowKind) void {
    if (kindRank(cand) > kindRank(cur.*)) cur.* = cand;
}

fn scanLineDots(line: []const u8, tab_width: usize, dy: usize, masks: *[width]u8) void {
    const max_dots = width * 2;
    const max_cols = max_dots * cols_per_dot;
    var it = text.iterate(line, tab_width);
    while (it.next()) |c| {
        if (c.dcol >= max_cols) break;
        const bytes = line[c.start..c.end()];
        if (bytes.len == 1 and (bytes[0] == ' ' or bytes[0] == '\t')) continue;
        const dot_col = @min(c.dcol / cols_per_dot, max_dots - 1);
        masks[dot_col / 2] |= dotBit(dot_col % 2, dy);
    }
}

/// Computes the Braille minimap rows for the full visible height `text_h`.
pub fn compute(
    arena: Allocator,
    buf: *const Buffer,
    tab_width: usize,
    top_line: usize,
    text_h: usize,
    cursor_line: usize,
    git_marks: []const gitdiff.Mark,
    needle: []const u8,
) Allocator.Error![]Row {
    const rows = try arena.alloc(Row, text_h);
    if (text_h == 0) return rows;

    const n = buf.lineCount();
    const total_dots_h = text_h * 4;
    const view_end = @min(n, top_line + text_h);
    const scan_all_needle = n <= 10_000;

    for (rows, 0..) |*row, r| {
        var masks: [width]u8 = @splat(0);
        var kind: RowKind = .normal;
        var in_view = false;

        const row_start = if (n <= total_dots_h) @min(r * 4, n) else (r * 4) * n / total_dots_h;
        const row_end = if (n <= total_dots_h) @min(r * 4 + 4, n) else @min(((r + 1) * 4) * n / total_dots_h, n);

        if (row_start < row_end) {
            in_view = row_start < view_end and row_end > top_line;
            if (cursor_line >= row_start and cursor_line < row_end) {
                promoteKind(&kind, .cursor);
            }

            const mark_end = @min(row_end, git_marks.len);
            if (row_start < mark_end) {
                for (git_marks[row_start..mark_end]) |m| {
                    switch (m) {
                        .none => {},
                        .added => promoteKind(&kind, .git_added),
                        .changed => promoteKind(&kind, .git_changed),
                        .deleted_above, .deleted_below => promoteKind(&kind, .git_deleted),
                    }
                }
            }

            var dy: usize = 0;
            while (dy < 4) : (dy += 1) {
                const s = r * 4 + dy;
                const s_start = if (n <= total_dots_h) s else s * n / total_dots_h;
                if (s_start >= n) continue;
                const s_end = if (n <= total_dots_h)
                    s + 1
                else
                    @min(@max(s_start + 1, (s + 1) * n / total_dots_h), n);

                const span = s_end - s_start;
                const step = @max(span / 4, 1);
                var li = s_start;
                while (li < s_end) : (li += step) {
                    const line = buf.line(li);
                    scanLineDots(line, tab_width, dy, &masks);
                    if (!scan_all_needle and needle.len > 0 and kindRank(kind) < kindRank(.search_hit)) {
                        if (editor.findInLine(line, needle, 0) != null) promoteKind(&kind, .search_hit);
                    }
                }
            }

            if (scan_all_needle and needle.len > 0 and kindRank(kind) < kindRank(.search_hit)) {
                var li = row_start;
                while (li < row_end) : (li += 1) {
                    if (editor.findInLine(buf.line(li), needle, 0) != null) {
                        promoteKind(&kind, .search_hit);
                        break;
                    }
                }
            }
        }

        for (&row.cells, masks) |*cell, m| {
            cell.* = encodeBraille(m);
        }
        row.in_view = in_view;
        row.kind = kind;
    }

    return rows;
}

/// Converts a clicked minimap row into the matching `top_line` (centres the
/// viewport on the chosen spot).
pub fn targetTopLine(click_row: usize, text_h: usize, line_count: usize) usize {
    if (line_count <= 1 or text_h == 0 or line_count <= text_h) return 0;
    const total_dots_h = text_h * 4;
    const r = @min(click_row, text_h - 1);
    const center_line = if (line_count <= total_dots_h)
        @min(r * 4 + 2, line_count - 1)
    else
        @min(((r * 2 + 1) * line_count) / (2 * text_h), line_count - 1);
    return @min(center_line -| (text_h / 2), line_count - text_h);
}

test "Braille encoding" {
    try std.testing.expectEqualSlices(u8, "\u{2800}", &encodeBraille(0x00));
    try std.testing.expectEqualSlices(u8, "\u{2801}", &encodeBraille(0x01));
    try std.testing.expectEqualSlices(u8, "\u{28ff}", &encodeBraille(0xFF));
}

test "minimap renders silhouette, viewport and priorities" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 10 lines: first 4 in the viewport, line 5 has a search match, line 6 the cursor, line 8 a git
    // change.
    var buf = try Buffer.fromBytes(gpa,
        \\alpha
        \\      beta
        \\
        \\gamma
        \\delta
        \\treffer hier
        \\cursorzeile
        \\        weit rechts
        \\geändert
        \\ende
    );
    defer buf.deinit();

    var marks: [10]gitdiff.Mark = @splat(.none);
    marks[6] = .added; // same line as the cursor -> cursor wins
    marks[8] = .changed;

    const rows = try compute(arena, &buf, 4, 0, 5, 6, &marks, "treffer");
    try std.testing.expectEqual(@as(usize, 5), rows.len);

    // Minimap row 0 covers document lines 0..3 (all inside viewport 0..5).
    try std.testing.expect(rows[0].in_view);
    try std.testing.expectEqual(RowKind.normal, rows[0].kind);
    // "alpha" (column 0) sets the top-left dot (0x01); "      beta" (column 6) is dot column 1 in cell 0 (dx=1, dy=1 -> 0x10).
    try std.testing.expectEqualSlices(u8, &encodeBraille(0x01 | 0x10 | 0x40), &rows[0].cells[0]);

    // Minimap row 1 covers document lines 4..7: the cursor on line 6 beats the search match on 5 and git on 6.
    try std.testing.expect(rows[1].in_view);
    try std.testing.expectEqual(RowKind.cursor, rows[1].kind);

    // Minimap row 2 covers document lines 8..9: outside the viewport (0..5), git changed.
    try std.testing.expect(!rows[2].in_view);
    try std.testing.expectEqual(RowKind.git_changed, rows[2].kind);

    // Rows 3 and 4 lie past the end of the file -> empty.
    try std.testing.expect(!rows[3].in_view);
    try std.testing.expectEqual(RowKind.normal, rows[3].kind);
    try std.testing.expectEqualSlices(u8, "\u{2800}", &rows[3].cells[0]);
}

test "minimap scales long files and maps clicks centred" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..400) |i| {
        if (i > 0) try raw.append(gpa, '\n');
        if (i == 200) {
            try raw.appendSlice(gpa, "Suchwort");
        } else {
            try raw.appendSlice(gpa, "x");
        }
    }
    var buf = try Buffer.fromBytes(gpa, raw.items);
    defer buf.deinit();

    const rows = try compute(arena, &buf, 4, 190, 20, 10, &.{}, "Suchwort");
    try std.testing.expectEqual(@as(usize, 20), rows.len);
    // Row 10 (middle of 20) maps to around line 200 -> search match and
    // viewport.
    try std.testing.expect(rows[10].in_view);
    try std.testing.expectEqual(RowKind.search_hit, rows[10].kind);
    // Row 0 covers about 0..20 -> cursor on line 10.
    try std.testing.expectEqual(RowKind.cursor, rows[0].kind);

    // Mouse jumps
    try std.testing.expectEqual(@as(usize, 0), targetTopLine(0, 20, 400));
    try std.testing.expectEqual(@as(usize, 380), targetTopLine(19, 20, 400));
    const mid = targetTopLine(10, 20, 400);
    try std.testing.expect(mid >= 190 and mid <= 210);
    try std.testing.expectEqual(@as(usize, 0), targetTopLine(5, 20, 10));
}
