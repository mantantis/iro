// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Ranking for file search (Ctrl+O): which file comes first?
//!
//! 1. The typed letters must appear in the path in order (fuzzy.zig); a match in
//! the file name counts more than one spread across the folders. 2. Recently
//! opened files and files next to the current one get a bonus, hidden and deeply
//! buried ones a penalty. 3. If that finds almost nothing (from four letters on),
//! the search forgives one typo in the file name: one letter too many, wrong or
//! swapped.
//!
//! To keep typing smooth even with hundreds of thousands of files, a fast
//! prefilter first discards everything that doesn't contain the letters at all.
//! Only the rest is scored exactly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fuzzy = @import("fuzzy.zig");
const Entry = @import("index.zig").Entry;

pub const Hit = struct {
    /// Position in the index.
    index: u32,
    score: i32,
    /// Approximate match (typo forgiven)?
    typo: bool = false,
};

/// The search doesn't fully sort more matches than this; the rest follows
/// unordered. Nobody scrolls to position 2000.
const sorted_max = 2000;

fn lowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Prepares the query for the prefilter: lowercase, no spaces. `null`: it
/// contains non-ASCII, so only the exact scoring applies.
fn prepNeedle(needle: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    for (needle) |c| {
        if (c >= 0x80) return null;
        if (c == ' ') continue;
        if (n == buf.len) return null;
        buf[n] = lowerAscii(c);
        n += 1;
    }
    return buf[0..n];
}

/// Do all letters of `want` appear in `hay` in this order?
fn subsequence(want: []const u8, hay: []const u8) bool {
    var i: usize = 0;
    for (hay) |c| {
        if (i == want.len) return true;
        if (lowerAscii(c) == want[i]) i += 1;
    }
    return i == want.len;
}

fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

fn dirname(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[0..i] else "";
}

/// Bonus and penalty that don't depend on the query.
fn extra(e: Entry, recent: []const []const u8, near: []const u8) i32 {
    // Mild penalty for burial: one point per level, 15 per hidden folder. No more
    // than that, because .config often holds exactly what you're looking for.
    // (Without a query the full rank sorts anyway, and hidden entries come last
    // there.)
    const hidden: i32 = @intCast(e.rank / 400);
    const depth: i32 = @intCast((e.rank % 400) / 4);
    var bonus: i32 = -depth - 15 * hidden;
    for (recent, 0..) |r, i| {
        if (std.mem.eql(u8, r, e.path)) {
            bonus += @max(300 - @as(i32, @intCast(i)) * 4, 60);
            break;
        }
    }
    if (near.len > 0) {
        const d = dirname(e.path);
        if (std.mem.eql(u8, d, near)) {
            bonus += 60;
        } else if (d.len > near.len and std.mem.startsWith(u8, d, near) and d[near.len] == '/') {
            bonus += 25;
        }
    } else if (std.mem.indexOfScalar(u8, e.path, '/') == null) bonus += 20;
    return bonus;
}

fn better(entries: []const Entry, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    const ra = entries[a.index].rank;
    const rb = entries[b.index].rank;
    if (ra != rb) return ra < rb;
    const pa = entries[a.index].path;
    const pb = entries[b.index].path;
    if (pa.len != pb.len) return pa.len < pb.len;
    return std.mem.lessThan(u8, pa, pb);
}

pub const Query = struct {
    needle: []const u8,
    /// Recently opened paths (relative to the root), newest first.
    recent: []const []const u8 = &.{},
    /// Folder of the current file (relative to the root), "" for the root.
    near: []const u8 = "",
};

/// From this many entries on, spreading the work across all cores pays off.
const parallel_from = 30_000;

const Prepared = struct {
    q: Query,
    fast: ?[]const u8,
    empty: bool,
    /// Typo variants of the query (one letter dropped, two swapped).
    variants: [64][32]u8 = undefined,
    vlen: [64]usize = undefined,
    nv: usize = 0,

    fn initVariants(p: *Prepared, want: []const u8) void {
        const w = want[0..@min(want.len, 31)];
        for (0..w.len) |skip| {
            if (p.nv == p.variants.len) break;
            var n: usize = 0;
            for (w, 0..) |c, j| {
                if (j == skip) continue;
                p.variants[p.nv][n] = c;
                n += 1;
            }
            p.vlen[p.nv] = n;
            p.nv += 1;
        }
        for (0..w.len -| 1) |s| {
            if (p.nv == p.variants.len) break;
            @memcpy(p.variants[p.nv][0..w.len], w);
            std.mem.swap(u8, &p.variants[p.nv][s], &p.variants[p.nv][s + 1]);
            p.vlen[p.nv] = w.len;
            p.nv += 1;
        }
    }
};

const Phase = enum { normal, typo };

/// One chunk of work: score entries `from..to` (or from `subset`).
const Chunk = struct {
    p: *const Prepared,
    entries: []const Entry,
    subset: ?[]const u32,
    from: usize,
    to: usize,
    phase: Phase,
    list: std.ArrayList(Hit) = .empty,
    /// Matches where all letters are in the file name itself.
    strong: usize = 0,
    oom: bool = false,

    fn run(c: *Chunk) void {
        const a = std.heap.smp_allocator;
        var k = c.from;
        while (k < c.to) : (k += 1) {
            const i: u32 = if (c.subset) |s| s[k] else @intCast(k);
            const e = c.entries[i];
            switch (c.phase) {
                .normal => {
                    const sc: i32 = if (c.p.empty) 0 else blk: {
                        if (c.p.fast) |w| {
                            if (!subsequence(w, e.path)) continue;
                            // Strong: the letters are in the file name and
                            // mostly contiguous (not just scattered across a
                            // long name).
                            const name = basename(e.path);
                            if (subsequence(w, name)) {
                                const ns = fuzzy.score(c.p.q.needle, name) orelse 0;
                                if (ns >= @as(i32, @intCast(w.len)) * 18) c.strong += 1;
                            }
                        }
                        break :blk fuzzy.scorePath(c.p.q.needle, e.path) orelse continue;
                    };
                    c.list.append(a, .{ .index = i, .score = sc + extra(e, c.p.q.recent, c.p.q.near) }) catch {
                        c.oom = true;
                        return;
                    };
                },
                .typo => {
                    const name = basename(e.path);
                    if (name.len + 1 < c.p.vlen[0]) continue;
                    // Let all variants compete; the best counts (swapped often
                    // beats "one dropped").
                    var best: ?i32 = null;
                    for (0..c.p.nv) |v| {
                        const pat = c.p.variants[v][0..c.p.vlen[v]];
                        if (!subsequence(pat, name)) continue;
                        const sc = fuzzy.score(pat, name) orelse continue;
                        if (best == null or sc > best.?) best = sc;
                    }
                    // Like a match in the file name (+40), but a bit weaker (-30).
                    const sc = (best orelse continue) + 40 - 30;
                    c.list.append(a, .{ .index = i, .score = sc + extra(e, c.p.q.recent, c.p.q.near), .typo = true }) catch {
                        c.oom = true;
                        return;
                    };
                },
            }
        }
    }

    fn task(c: *Chunk) Io.Cancelable!void {
        c.run();
    }
};

/// One pass over all entries, on all cores for many entries. Appends matches to
/// `out` and returns how many were strong.
fn runPhase(gpa: Allocator, io: ?Io, p: *const Prepared, entries: []const Entry, subset: ?[]const u32, phase: Phase, out: *std.ArrayList(Hit)) Allocator.Error!usize {
    const n = if (subset) |s| s.len else entries.len;
    var chunks_buf: [8]Chunk = undefined;
    const n_chunks: usize = if (io == null or n < parallel_from) 1 else std.math.clamp(std.Thread.getCpuCount() catch 1, 1, 8);
    const chunks = chunks_buf[0..n_chunks];
    for (chunks, 0..) |*c, k| c.* = .{
        .p = p,
        .entries = entries,
        .subset = subset,
        .from = n * k / n_chunks,
        .to = n * (k + 1) / n_chunks,
        .phase = phase,
    };
    if (n_chunks == 1) {
        chunks[0].run();
    } else {
        var group: Io.Group = .init;
        for (chunks) |*c| group.concurrent(io.?, Chunk.task, .{c}) catch c.run();
        group.await(io.?) catch {};
    }
    var strong: usize = 0;
    var oom = false;
    for (chunks) |*c| {
        defer c.list.deinit(std.heap.smp_allocator);
        strong += c.strong;
        if (c.oom) oom = true;
        try out.appendSlice(gpa, c.list.items);
    }
    if (oom) return error.OutOfMemory;
    return strong;
}

/// Scores the entries against the query and puts the matches into `out`, best
/// first. With `io` it uses all cores for large lists. `subset`: only look at
/// these entries (if the query just grew longer, only the previous matches
/// qualify). Returns `true` if an approximate match is on top.
pub fn rank(gpa: Allocator, io: ?Io, entries: []const Entry, q: Query, subset: ?[]const u32, out: *std.ArrayList(Hit)) Allocator.Error!bool {
    out.clearRetainingCapacity();
    var buf: [256]u8 = undefined;
    var p: Prepared = .{
        .q = q,
        .fast = prepNeedle(q.needle, &buf),
        .empty = std.mem.trim(u8, q.needle, " ").len == 0,
    };
    const strong = try runPhase(gpa, io, &p, entries, subset, .normal, out);

    // If the query hardly appears in any file name itself, it may have been
    // mistyped: run one more pass that forgives one error.
    var typo = false;
    // Only from four letters on: with three, "one dropped" leaves a pair that
    // occurs in almost every name.
    if (!p.empty and strong < 3) {
        if (p.fast) |w| if (w.len >= 4) {
            p.initVariants(w);
            const from = out.items.len;
            _ = try runPhase(gpa, io, &p, entries, null, .typo, out);
            typo = out.items.len > from;
            if (typo) try dedupe(gpa, entries.len, out, from);
        };
    }
    sortTop(entries, out.items);
    return typo and out.items.len > 0 and out.items[0].typo;
}

/// An entry that matches both exactly AND approximately should appear only
/// once, with the better score.
fn dedupe(gpa: Allocator, n: usize, out: *std.ArrayList(Hit), typo_from: usize) Allocator.Error!void {
    const pos = try gpa.alloc(u32, n);
    defer gpa.free(pos);
    @memset(pos, std.math.maxInt(u32));
    for (out.items[0..typo_from], 0..) |h, k| pos[h.index] = @intCast(k);
    var w = typo_from;
    for (out.items[typo_from..]) |h| {
        const at = pos[h.index];
        if (at != std.math.maxInt(u32)) {
            if (h.score > out.items[at].score) out.items[at] = h;
            continue;
        }
        out.items[w] = h;
        w += 1;
    }
    out.items.len = w;
}

/// Bring the best `sorted_max` to the front and sort them; the rest stays
/// behind.
fn sortTop(entries: []const Entry, hits: []Hit) void {
    const Ctx = struct {
        entries: []const Entry,
        fn lt(ctx: @This(), a: Hit, b: Hit) bool {
            return better(ctx.entries, a, b);
        }
    };
    const ctx: Ctx = .{ .entries = entries };
    if (hits.len > sorted_max * 2) {
        // Rough presort: everything scoring above the threshold goes to the
        // front.
        var hist_min: i32 = std.math.maxInt(i32);
        var hist_max: i32 = std.math.minInt(i32);
        for (hits) |h| {
            hist_min = @min(hist_min, h.score);
            hist_max = @max(hist_max, h.score);
        }
        // Lower the threshold until enough entries are in front.
        var cut = hist_max;
        var front: usize = 0;
        while (cut > hist_min) {
            front = 0;
            for (hits) |h| {
                if (h.score >= cut) front += 1;
            }
            if (front >= sorted_max) break;
            cut -= @max(@divTrunc(hist_max - hist_min, 32), 1);
        }
        var w: usize = 0;
        for (hits, 0..) |h, r| {
            if (h.score >= cut) {
                std.mem.swap(Hit, &hits[w], &hits[r]);
                w += 1;
            }
        }
        std.sort.pdq(Hit, hits[0..w], ctx, Ctx.lt);
        return;
    }
    std.sort.pdq(Hit, hits, ctx, Ctx.lt);
}

// ───────────── Tests ─────────────

fn mk(paths: []const []const u8, buf: []Entry) []Entry {
    for (paths, 0..) |p, i| buf[i] = .{ .path = p, .rank = @import("index.zig").rankOf(p) };
    return buf[0..paths.len];
}

test "file name beats folder path, hidden ranks last" {
    const gpa = std.testing.allocator;
    var buf: [8]Entry = undefined;
    const es = mk(&.{ "kitty/themes/dunkel.conf", ".config/kitty/kitty.conf", "Projekte/kitty-tools/kitty.conf" }, &buf);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(gpa);
    _ = try rank(gpa, null, es, .{ .needle = "kitty.conf" }, null, &out);
    try std.testing.expectEqualStrings("Projekte/kitty-tools/kitty.conf", es[out.items[0].index].path);
    // dunkel.conf matches too (k-i-t-t-y … .conf), but ranks lower.
    try std.testing.expectEqualStrings("kitty/themes/dunkel.conf", es[out.items[out.items.len - 1].index].path);
}

test "recently opened and proximity win" {
    const gpa = std.testing.allocator;
    var buf: [8]Entry = undefined;
    const es = mk(&.{ "a/notiz.md", "b/notiz.md", "c/notiz.md" }, &buf);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(gpa);
    _ = try rank(gpa, null, es, .{ .needle = "notiz", .recent = &.{"c/notiz.md"} }, null, &out);
    try std.testing.expectEqualStrings("c/notiz.md", es[out.items[0].index].path);
    _ = try rank(gpa, null, es, .{ .needle = "notiz", .near = "b" }, null, &out);
    try std.testing.expectEqualStrings("b/notiz.md", es[out.items[0].index].path);
    // Without a query: everything, recently opened first.
    _ = try rank(gpa, null, es, .{ .needle = "", .recent = &.{"a/notiz.md"} }, null, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("a/notiz.md", es[out.items[0].index].path);
}

test "typos are forgiven: extra, wrong, swapped" {
    const gpa = std.testing.allocator;
    var buf: [8]Entry = undefined;
    const es = mk(&.{ ".config/hypr/hyprland.lua", "Dokumente/rechnung.pdf", "x/waybar.css" }, &buf);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(gpa);
    for ([_][]const u8{ "hyprlnad", "hyprxland", "hyprkand", "rechnugn", "waybra" }) |q| {
        const typo = try rank(gpa, null, es, .{ .needle = q }, null, &out);
        try std.testing.expect(typo);
        try std.testing.expect(out.items.len >= 1);
    }
    // Scattered letters in long names don't count as a good match.
    var buf2: [8]Entry = undefined;
    const es2 = mk(&.{ ".config/hypr/hyprland.lua", "games/Hyper Rally (EU)-manual.pdf", "Pictures/hyper/Landscape_dark.png", "backgrounds_HYPRLAND/neon_grid_red.png" }, &buf2);
    _ = try rank(gpa, null, es2, .{ .needle = "hyprlnad" }, null, &out);
    try std.testing.expectEqualStrings(".config/hypr/hyprland.lua", es2[out.items[0].index].path);
    // Typed correctly: not "approximate".
    try std.testing.expect(!try rank(gpa, null, es, .{ .needle = "hyprland" }, null, &out));
    // Completely off: nothing.
    _ = try rank(gpa, null, es, .{ .needle = "zzzqqq" }, null, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "prefilter and exact scoring agree" {
    // Whatever the fast prefilter discards, the exact scoring must not find.
    const paths = [_][]const u8{ "Hallo/Welt.txt", "a/b/c", "README.md", "src/main.zig", "x.Y.z" };
    const needles = [_][]const u8{ "hw", "abc", "rdm", "smz", "xyz", "q", "Me" };
    var nb: [64]u8 = undefined;
    for (paths) |p| for (needles) |n| {
        const w = prepNeedle(n, &nb).?;
        if (!subsequence(w, p)) try std.testing.expect(fuzzy.scorePath(n, p) == null);
    };
}
