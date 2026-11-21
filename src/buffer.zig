// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! The text buffer of iro.
//!
//! The file content is held as a list of lines; each line is a sequence of
//! UTF-8 bytes without a newline. There are exactly two mutating operations,
//! `insert` and `delete`. Everything else in the editor builds on them, and
//! both are written so the buffer stays valid even if memory runs out halfway
//! through.
//!
//! Invariants (checked in the tests):
//! * There is always at least one line.
//! * No line contains '\n'.
//! * Positions lie within the text.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A position in the text: line number and byte offset from the start of the
/// line.
pub const Pos = struct {
    line: usize = 0,
    col: usize = 0,

    pub fn eql(a: Pos, b: Pos) bool {
        return a.line == b.line and a.col == b.col;
    }

    pub fn lessThan(a: Pos, b: Pos) bool {
        return a.line < b.line or (a.line == b.line and a.col < b.col);
    }

    pub fn min(a: Pos, b: Pos) Pos {
        return if (b.lessThan(a)) b else a;
    }

    pub fn max(a: Pos, b: Pos) Pos {
        return if (b.lessThan(a)) a else b;
    }
};

const Line = std.ArrayList(u8);

pub const Buffer = struct {
    gpa: Allocator,
    lines: std.ArrayList(Line),

    /// Empty text with a single empty line.
    pub fn init(gpa: Allocator) Allocator.Error!Buffer {
        var lines: std.ArrayList(Line) = .empty;
        try lines.append(gpa, .empty);
        return .{ .gpa = gpa, .lines = lines };
    }

    /// Build text from bytes. Lines are split at '\n'.
    pub fn fromBytes(gpa: Allocator, bytes: []const u8) Allocator.Error!Buffer {
        var self = try init(gpa);
        errdefer self.deinit();
        _ = try self.insert(.{}, bytes);
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*l| l.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.lines.items.len;
    }

    pub fn line(self: *const Buffer, index: usize) []const u8 {
        return self.lines.items[index].items;
    }

    /// Position after the last character.
    pub fn endPos(self: *const Buffer) Pos {
        const last = self.lines.items.len - 1;
        return .{ .line = last, .col = self.lines.items[last].items.len };
    }

    /// Clamps a position into the valid range.
    pub fn clamp(self: *const Buffer, pos: Pos) Pos {
        const l = @min(pos.line, self.lines.items.len - 1);
        return .{ .line = l, .col = @min(pos.col, self.lines.items[l].items.len) };
    }

    pub fn isValid(self: *const Buffer, pos: Pos) bool {
        return pos.line < self.lines.items.len and pos.col <= self.lines.items[pos.line].items.len;
    }

    /// Inserts `text` at `pos` and returns the position after the inserted
    /// text. `text` may contain newlines. If the operation fails, the text is
    /// unchanged.
    pub fn insert(self: *Buffer, pos: Pos, text: []const u8) Allocator.Error!Pos {
        std.debug.assert(self.isValid(pos));
        if (text.len == 0) return pos;
        const gpa = self.gpa;

        const newlines = std.mem.count(u8, text, "\n");
        if (newlines == 0) {
            try self.lines.items[pos.line].insertSlice(gpa, pos.col, text);
            return .{ .line = pos.line, .col = pos.col + text.len };
        }

        // Split: text = first ++ '\n' ++ middle... ++ '\n' ++ last
        const first_len = std.mem.indexOfScalar(u8, text, '\n').?;
        const first = text[0..first_len];
        const tail_len = self.lines.items[pos.line].items.len - pos.col;

        // Phase 1: prepare everything that can fail.
        var fresh: std.ArrayList(Line) = .empty;
        defer {
            for (fresh.items) |*l| l.deinit(gpa);
            fresh.deinit(gpa);
        }
        try fresh.ensureTotalCapacityPrecise(gpa, newlines);

        var rest = text[first_len + 1 ..];
        var end_col: usize = 0;
        var i: usize = 0;
        while (i < newlines) : (i += 1) {
            const is_last = i + 1 == newlines;
            const seg_len = if (is_last) rest.len else std.mem.indexOfScalar(u8, rest, '\n').?;
            var l: Line = .empty;
            errdefer l.deinit(gpa);
            try l.ensureTotalCapacityPrecise(gpa, seg_len + (if (is_last) tail_len else 0));
            l.appendSliceAssumeCapacity(rest[0..seg_len]);
            if (is_last) {
                end_col = seg_len;
                l.appendSliceAssumeCapacity(self.lines.items[pos.line].items[pos.col..]);
            } else {
                rest = rest[seg_len + 1 ..];
            }
            fresh.appendAssumeCapacity(l);
        }

        try self.lines.ensureUnusedCapacity(gpa, newlines);
        try self.lines.items[pos.line].ensureTotalCapacity(gpa, pos.col + first.len);

        // Phase 2: rebuild. Nothing can fail from here on.
        const head = &self.lines.items[pos.line];
        head.shrinkRetainingCapacity(pos.col);
        head.appendSliceAssumeCapacity(first);
        const slots = self.lines.addManyAtAssumeCapacity(pos.line + 1, newlines);
        @memcpy(slots, fresh.items);
        fresh.clearRetainingCapacity(); // Ownership has moved to self.lines

        return .{ .line = pos.line + newlines, .col = end_col };
    }

    /// Deletes the range from `start` (inclusive) to `end` (exclusive). If the
    /// operation fails, the text is unchanged.
    pub fn delete(self: *Buffer, start: Pos, end: Pos) Allocator.Error!void {
        std.debug.assert(self.isValid(start) and self.isValid(end));
        std.debug.assert(!end.lessThan(start));
        if (start.eql(end)) return;
        const gpa = self.gpa;

        if (start.line == end.line) {
            self.lines.items[start.line].replaceRangeAssumeCapacity(start.col, end.col - start.col, &.{});
            return;
        }

        const tail = self.lines.items[end.line].items[end.col..];
        const head = &self.lines.items[start.line];
        try head.ensureTotalCapacity(gpa, start.col + tail.len);

        head.shrinkRetainingCapacity(start.col);
        head.appendSliceAssumeCapacity(tail);
        for (self.lines.items[start.line + 1 .. end.line + 1]) |*l| l.deinit(gpa);
        self.lines.replaceRangeAssumeCapacity(start.line + 1, end.line - start.line, &.{});
    }

    /// Number of bytes in the range; newlines count as one byte.
    pub fn rangeLen(self: *const Buffer, start: Pos, end: Pos) usize {
        std.debug.assert(self.isValid(start) and self.isValid(end));
        if (start.line == end.line) return end.col - start.col;
        var n: usize = self.lines.items[start.line].items.len - start.col + 1;
        for (self.lines.items[start.line + 1 .. end.line]) |l| n += l.items.len + 1;
        return n + end.col;
    }

    /// Copy of the range, lines joined with '\n'. Caller owns the result.
    pub fn copyRange(self: *const Buffer, gpa: Allocator, start: Pos, end: Pos) Allocator.Error![]u8 {
        std.debug.assert(!end.lessThan(start));
        const out = try gpa.alloc(u8, self.rangeLen(start, end));
        var w: usize = 0;
        var l = start.line;
        while (l <= end.line) : (l += 1) {
            const items = self.lines.items[l].items;
            const from = if (l == start.line) start.col else 0;
            const to = if (l == end.line) end.col else items.len;
            @memcpy(out[w..][0 .. to - from], items[from..to]);
            w += to - from;
            if (l != end.line) {
                out[w] = '\n';
                w += 1;
            }
        }
        std.debug.assert(w == out.len);
        return out;
    }

    /// The whole text as one slice, lines joined with `eol`. Caller owns the result.
    pub fn toBytes(self: *const Buffer, gpa: Allocator, eol: []const u8) Allocator.Error![]u8 {
        var total: usize = 0;
        for (self.lines.items) |l| total += l.items.len;
        total += (self.lines.items.len - 1) * eol.len;
        const out = try gpa.alloc(u8, total);
        var w: usize = 0;
        for (self.lines.items, 0..) |l, i| {
            if (i != 0) {
                @memcpy(out[w..][0..eol.len], eol);
                w += eol.len;
            }
            @memcpy(out[w..][0..l.items.len], l.items);
            w += l.items.len;
        }
        std.debug.assert(w == total);
        return out;
    }

    /// Checks the invariants. Tests only.
    pub fn checkInvariants(self: *const Buffer) !void {
        try std.testing.expect(self.lines.items.len >= 1);
        for (self.lines.items) |l| {
            try std.testing.expect(std.mem.indexOfScalar(u8, l.items, '\n') == null);
        }
    }
};

// ───────────────────────────── Tests ─────────────────────────────

const testing = std.testing;

fn expectText(buf: *const Buffer, expected: []const u8) !void {
    const got = try buf.toBytes(testing.allocator, "\n");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
    try buf.checkInvariants();
}

test "empty text has one line" {
    var buf = try Buffer.init(testing.allocator);
    defer buf.deinit();
    try testing.expectEqual(@as(usize, 1), buf.lineCount());
    try expectText(&buf, "");
}

test "insert within a line" {
    var buf = try Buffer.fromBytes(testing.allocator, "Hallo Welt");
    defer buf.deinit();
    const end = try buf.insert(.{ .line = 0, .col = 5 }, ", schöne");
    try testing.expectEqual(Pos{ .line = 0, .col = 5 + ", schöne".len }, end);
    try expectText(&buf, "Hallo, schöne Welt");
}

test "insert with newlines" {
    var buf = try Buffer.fromBytes(testing.allocator, "ab");
    defer buf.deinit();
    const end = try buf.insert(.{ .line = 0, .col = 1 }, "1\n2\n3");
    try testing.expectEqual(Pos{ .line = 2, .col = 1 }, end);
    try expectText(&buf, "a1\n2\n3b");
    try testing.expectEqual(@as(usize, 3), buf.lineCount());
}

test "a lone newline splits the line" {
    var buf = try Buffer.fromBytes(testing.allocator, "links rechts");
    defer buf.deinit();
    const end = try buf.insert(.{ .line = 0, .col = 5 }, "\n");
    try testing.expectEqual(Pos{ .line = 1, .col = 0 }, end);
    try expectText(&buf, "links\n rechts");
}

test "delete within a line and across lines" {
    var buf = try Buffer.fromBytes(testing.allocator, "eins\nzwei\ndrei\nvier");
    defer buf.deinit();
    try buf.delete(.{ .line = 0, .col = 1 }, .{ .line = 0, .col = 3 });
    try expectText(&buf, "es\nzwei\ndrei\nvier");
    try buf.delete(.{ .line = 0, .col = 1 }, .{ .line = 2, .col = 2 });
    try expectText(&buf, "eei\nvier");
    try buf.delete(.{}, buf.endPos());
    try expectText(&buf, "");
    try testing.expectEqual(@as(usize, 1), buf.lineCount());
}

test "copyRange returns exactly the range" {
    var buf = try Buffer.fromBytes(testing.allocator, "eins\nzwei\ndrei");
    defer buf.deinit();
    const got = try buf.copyRange(testing.allocator, .{ .line = 0, .col = 2 }, .{ .line = 2, .col = 2 });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ns\nzwei\ndr", got);
}

test "umlauts and emoji survive byte for byte" {
    const text = "Größe: 5 µm 🦅\nÄÖÜ ß 👨‍👩‍👧";
    var buf = try Buffer.fromBytes(testing.allocator, text);
    defer buf.deinit();
    try expectText(&buf, text);
}

test "insert survives out-of-memory without damage" {
    // Makes every single allocation fail in turn and checks that the text is
    // unchanged and nothing leaked.
    const Check = struct {
        fn run(gpa: Allocator) !void {
            var buf = try Buffer.fromBytes(gpa, "kopf\nmitte\nfuß");
            defer buf.deinit();
            const before = try buf.toBytes(testing.allocator, "\n");
            defer testing.allocator.free(before);
            _ = buf.insert(.{ .line = 1, .col = 2 }, "AAA\nBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\nCCC") catch |err| {
                const after = try buf.toBytes(testing.allocator, "\n");
                defer testing.allocator.free(after);
                try testing.expectEqualStrings(before, after);
                return err;
            };
            buf.delete(.{ .line = 0, .col = 1 }, .{ .line = 3, .col = 1 }) catch |err| return err;
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}

/// Reference model for the random test: the whole text as one flat slice.
const Model = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn offset(self: *const Model, pos: Pos) usize {
        var off: usize = 0;
        var l: usize = 0;
        while (l < pos.line) : (l += 1) {
            off = std.mem.indexOfScalarPos(u8, self.bytes.items, off, '\n').? + 1;
        }
        return off + pos.col;
    }
};

test "random test against a simple reference model" {
    const gpa = testing.allocator;
    const pieces = [_][]const u8{ "a", "xyz", "\n", "ä", "🦅", "\n\n", " ", "zeile\nnoch eine", "\t", "" };

    var seed: u64 = 1;
    while (seed <= 40) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();

        var buf = try Buffer.init(gpa);
        defer buf.deinit();
        var model: Model = .{};
        defer model.bytes.deinit(gpa);

        var step: usize = 0;
        while (step < 400) : (step += 1) {
            const l1 = rnd.uintLessThan(usize, buf.lineCount());
            const p1: Pos = .{ .line = l1, .col = rnd.uintAtMost(usize, buf.line(l1).len) };

            if (rnd.uintLessThan(u8, 10) < 6) {
                const text = pieces[rnd.uintLessThan(usize, pieces.len)];
                const off = model.offset(p1);
                const end = try buf.insert(p1, text);
                try model.bytes.insertSlice(gpa, off, text);
                try testing.expectEqual(off + text.len, model.offset(end));
            } else {
                const l2 = rnd.uintLessThan(usize, buf.lineCount());
                const p2: Pos = .{ .line = l2, .col = rnd.uintAtMost(usize, buf.line(l2).len) };
                const a = Pos.min(p1, p2);
                const b = Pos.max(p1, p2);
                const oa = model.offset(a);
                const ob = model.offset(b);

                const copied = try buf.copyRange(gpa, a, b);
                defer gpa.free(copied);
                try testing.expectEqualStrings(model.bytes.items[oa..ob], copied);

                try buf.delete(a, b);
                model.bytes.replaceRangeAssumeCapacity(oa, ob - oa, &.{});
            }

            try buf.checkInvariants();
            const got = try buf.toBytes(gpa, "\n");
            defer gpa.free(got);
            try testing.expectEqualStrings(model.bytes.items, got);
        }
    }
}
