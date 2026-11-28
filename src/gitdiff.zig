// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Line diff for the git gutter: which lines are new, changed or removed
//! compared to the last commit?
//!
//! Compares two lists of lines. Common prefixes and suffixes drop out
//! immediately; while typing, only a tiny middle part remains. For that part
//! the longest common subsequence of lines is computed. If it is too large for
//! that, it simply counts as changed.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Mark = enum(u8) {
    none,
    /// Line does not exist in the last commit.
    added,
    /// Line replaces other lines from the last commit.
    changed,
    /// Something is missing directly above this line.
    deleted_above,
    /// Something is missing below this (last) line.
    deleted_below,
};

/// Upper limit of cells for the comparison table (4 bytes each).
const max_cells = 1_000_000;

fn exceedsCellLimit(a_len: usize, b_len: usize) bool {
    return b_len > 0 and a_len > max_cells / b_len;
}

/// Splits file content into lines the way iro counts them: without line endings
/// and without the empty "line" after the final newline. The slices point into
/// `raw`.
pub fn splitLines(gpa: Allocator, raw: []const u8) Allocator.Error![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var content = raw;
    if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF")) content = content[3..];
    if (std.mem.endsWith(u8, content, "\n")) content = content[0 .. content.len - 1];
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |l| {
        try list.append(gpa, if (std.mem.endsWith(u8, l, "\r")) l[0 .. l.len - 1] else l);
    }
    return list.toOwnedSlice(gpa);
}

/// Fills `out` (as long as `new`) with each line's mark.
pub fn marks(gpa: Allocator, old: []const []const u8, new: []const []const u8, out: []Mark) Allocator.Error!void {
    std.debug.assert(out.len == new.len);
    @memset(out, .none);

    var pre: usize = 0;
    while (pre < old.len and pre < new.len and std.mem.eql(u8, old[pre], new[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < old.len - pre and suf < new.len - pre and
        std.mem.eql(u8, old[old.len - 1 - suf], new[new.len - 1 - suf])) suf += 1;

    const a = old[pre .. old.len - suf];
    const b = new[pre .. new.len - suf];
    if (a.len == 0 and b.len == 0) return;
    if (a.len == 0) return @memset(out[pre..][0..b.len], .added);
    if (b.len == 0) return markDeletion(out, pre);
    if (exceedsCellLimit(a.len, b.len)) return @memset(out[pre..][0..b.len], .changed);

    // lcs[i][j]: length of the longest common subsequence of a[i..] and b[j..].
    const w = b.len + 1;
    const lcs = try gpa.alloc(u32, (a.len + 1) * w);
    defer gpa.free(lcs);
    @memset(lcs, 0);
    var i = a.len;
    while (i > 0) {
        i -= 1;
        var j = b.len;
        while (j > 0) {
            j -= 1;
            lcs[i * w + j] = if (std.mem.eql(u8, a[i], b[j]))
                lcs[(i + 1) * w + j + 1] + 1
            else
                @max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
        }
    }

    // Walk forward and collect contiguous differences.
    i = 0;
    var j: usize = 0;
    var dels: usize = 0;
    var ins_from: usize = 0;
    var ins: usize = 0;
    while (i < a.len or j < b.len) {
        const same = i < a.len and j < b.len and std.mem.eql(u8, a[i], b[j]);
        if (same) {
            flush(out, pre, ins_from, ins, dels, j);
            dels = 0;
            ins = 0;
            i += 1;
            j += 1;
        } else if (j >= b.len or (i < a.len and lcs[(i + 1) * w + j] >= lcs[i * w + j + 1])) {
            dels += 1;
            i += 1;
        } else {
            if (ins == 0) ins_from = j;
            ins += 1;
            j += 1;
        }
    }
    flush(out, pre, ins_from, ins, dels, j);
}

fn flush(out: []Mark, pre: usize, ins_from: usize, ins: usize, dels: usize, j: usize) void {
    if (ins > 0) {
        @memset(out[pre + ins_from ..][0..ins], if (dels > 0) .changed else .added);
    } else if (dels > 0) {
        markDeletion(out, pre + j);
    }
}

/// Something was removed before line `at`.
fn markDeletion(out: []Mark, at: usize) void {
    if (out.len == 0) return;
    if (at < out.len) {
        if (out[at] == .none) out[at] = .deleted_above;
    } else if (out[out.len - 1] == .none) {
        out[out.len - 1] = .deleted_below;
    }
}

// ───────────── Tests ─────────────

const testing = std.testing;

fn expectMarks(old_text: []const u8, new_text: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    const old = try splitLines(gpa, old_text);
    defer gpa.free(old);
    const new = try splitLines(gpa, new_text);
    defer gpa.free(new);
    const out = try gpa.alloc(Mark, new.len);
    defer gpa.free(out);
    try marks(gpa, old, new, out);
    var buf: [64]u8 = undefined;
    for (out, 0..) |m, i| buf[i] = switch (m) {
        .none => '.',
        .added => '+',
        .changed => '~',
        .deleted_above => '^',
        .deleted_below => 'v',
    };
    try testing.expectEqualStrings(expected, buf[0..out.len]);
}

test "equal, added, changed, removed" {
    try expectMarks("a\nb\nc\n", "a\nb\nc\n", "...");
    try expectMarks("a\nb\nc\n", "a\nb\nneu\nc\n", "..+.");
    try expectMarks("a\nb\nc\n", "a\nB\nc\n", ".~.");
    try expectMarks("a\nb\nc\n", "a\nc\n", ".^");
    try expectMarks("a\nb\nc\n", "a\nb\n", ".v");
    try expectMarks("a\nb\nc\n", "b\nc\n", "^.");
    try expectMarks("x\n", "a\nx\nb\n", "+.+");
    try expectMarks("a\nb\nc\nd\ne\n", "a\nX\nc\nneu\nd\n", ".~.+v");
}

test "several hunks and Windows line endings" {
    try expectMarks("1\n2\n3\n4\n5\n6\n", "0\n1\n2\n4\n5\nsechs\n7\n", "+..^.~~");
    try expectMarks("a\r\nb\r\n", "a\nb\nc\n", "..+");
}

test "split lines the way iro counts them" {
    const gpa = testing.allocator;
    const l = try splitLines(gpa, "eins\n\ndrei\n");
    defer gpa.free(l);
    try testing.expectEqual(@as(usize, 3), l.len);
    try testing.expectEqualStrings("", l[1]);
    const one = try splitLines(gpa, "");
    defer gpa.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
}

test "random test: marks always match the line count, equal lines stay unmarked" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xd1ff);
    const rnd = prng.random();
    const words = [_][]const u8{ "a", "b", "c", "d", "", "x y", "ende" };
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        var old: [24][]const u8 = undefined;
        var new: [24][]const u8 = undefined;
        const n = rnd.uintLessThan(usize, old.len);
        const m = rnd.uintLessThan(usize, new.len);
        for (old[0..n]) |*l| l.* = words[rnd.uintLessThan(usize, words.len)];
        for (new[0..m]) |*l| l.* = words[rnd.uintLessThan(usize, words.len)];
        var out: [24]Mark = undefined;
        try marks(gpa, old[0..n], new[0..m], out[0..m]);
        // Identical text never gets a mark.
        try marks(gpa, new[0..m], new[0..m], out[0..m]);
        for (out[0..m]) |mk| try testing.expectEqual(Mark.none, mk);
    }
}

test "cell limit check does not overflow on huge inputs" {
    try testing.expect(!exceedsCellLimit(1000, 1000));
    try testing.expect(exceedsCellLimit(1001, 1000));
    try testing.expect(exceedsCellLimit(1000, 1001));
    try testing.expect(exceedsCellLimit(std.math.maxInt(usize), 2));
    try testing.expect(exceedsCellLimit(2, std.math.maxInt(usize)));
    try testing.expect(exceedsCellLimit(std.math.maxInt(usize), std.math.maxInt(usize)));
}
