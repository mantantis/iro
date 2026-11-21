// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! File-finding helpers: which folders are junk, where drives are mounted (both
//! used by the file index in index.zig), and completion of a partly typed path
//! (Tab in the input line).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Folders that never contain anything worth editing by hand. The search skips
/// them, otherwise it drowns in junk.
const junk_dirs = [_][]const u8{
    ".git",        "node_modules", ".cache", ".zig-cache", "zig-cache", "zig-out",
    "zig-pkg",     "__pycache__",  ".venv",  "venv",       "target",    ".cargo",
    ".rustup",     ".npm",         ".var",   ".mozilla",   ".steam",    "Steam",
    "Trash",       ".Trash",
};

pub fn isJunk(name: []const u8) bool {
    for (junk_dirs) |j| {
        if (std.mem.eql(u8, j, name)) return true;
    }
    return false;
}

/// Reads all mount points. On failure the list is empty and nothing is skipped.
pub fn mountPoints(arena: Allocator, io: Io) []const []const u8 {
    // /proc reports size 0, so read as a stream instead of readFileAlloc, which
    // relies on the size in Zig 0.17 and returns nothing (this used to leave
    // the list silently empty).
    const file = Io.Dir.cwd().openFile(io, "/proc/self/mounts", .{}) catch return &.{};
    defer file.close(io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &rbuf);
    const raw = reader.interface.allocRemaining(arena, .limited(4 * 1024 * 1024)) catch return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        const target = fields.next() orelse continue;
        // Spaces in paths appear as "\040" there.
        const clean = std.mem.replaceOwned(u8, arena, target, "\\040", " ") catch continue;
        list.append(arena, clean) catch break;
    }
    return list.items;
}

fn nameLess(_: void, a: []const u8, b: []const u8) bool {
    return switch (std.ascii.orderIgnoreCase(a, b)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a, b),
    };
}

pub const Completion = struct {
    /// How far the typed name can be completed unambiguously. If it is exactly
    /// one folder, the slash is already appended.
    common: []u8,
    /// All matching names. Folders end in "/".
    names: [][]u8,

    pub fn deinit(self: *Completion, gpa: Allocator) void {
        for (self.names) |n| gpa.free(n);
        gpa.free(self.names);
        gpa.free(self.common);
    }
};

/// Finds everything in `dir_path` starting with `prefix`. If nothing matches
/// the exact spelling, case is ignored.
pub fn complete(gpa: Allocator, io: Io, dir_path: []const u8, prefix: []const u8) !Completion {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var exact: std.ArrayList([]u8) = .empty;
    var loose: std.ArrayList([]u8) = .empty;
    defer {
        for (exact.items) |n| gpa.free(n);
        exact.deinit(gpa);
        for (loose.items) |n| gpa.free(n);
        loose.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (!std.unicode.utf8ValidateSlice(e.name)) continue;
        // Dotfiles only if the prefix starts with a dot.
        if (e.name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
        const is_exact = std.mem.startsWith(u8, e.name, prefix);
        if (!is_exact and !std.ascii.startsWithIgnoreCase(e.name, prefix)) continue;
        const is_dir = switch (e.kind) {
            .directory => true,
            .sym_link => if (dir.statFile(io, e.name, .{})) |st| st.kind == .directory else |_| false,
            else => false,
        };
        const name = try std.mem.concat(gpa, u8, &.{ e.name, if (is_dir) "/" else "" });
        errdefer gpa.free(name);
        try (if (is_exact) &exact else &loose).append(gpa, name);
    }
    const hits = if (exact.items.len > 0) &exact else &loose;
    std.mem.sortUnstable([]u8, hits.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return nameLess({}, a, b);
        }
    }.less);

    // Common prefix of all matches.
    var common_len: usize = if (hits.items.len > 0) hits.items[0].len else prefix.len;
    for (hits.items) |n| {
        var i: usize = 0;
        while (i < common_len and i < n.len and std.ascii.toLower(n[i]) == std.ascii.toLower(hits.items[0][i])) i += 1;
        common_len = i;
    }
    const base = if (hits.items.len > 0) hits.items[0] else prefix;
    // Never stop in the middle of a multi-byte character.
    while (common_len > 0 and !std.unicode.utf8ValidateSlice(base[0..common_len])) common_len -= 1;
    const common = try gpa.dupe(u8, base[0..common_len]);
    errdefer gpa.free(common);
    return .{ .common = common, .names = try hits.toOwnedSlice(gpa) };
}

// ───────────── Tests ─────────────

const testing = std.testing;

fn makeFixture(io: Io, tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    try tmp.dir.createDirPath(io, "hypr/scripts");
    try tmp.dir.createDirPath(io, "kitty");
    try tmp.dir.createDirPath(io, ".git/objects");
    try tmp.dir.createDirPath(io, "node_modules/kram");
    try tmp.dir.writeFile(io, .{ .sub_path = "zuletzt.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Anfang.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".versteckt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hypr/hyprland.conf", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hypr/hyprlock.conf", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hypr/scripts/start.sh", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kitty/kitty.conf", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/objects/abc", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/kram/index.js", .data = "" });
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

test "completion: unique, ambiguous, case, nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const io = testing.io;
    const gpa = testing.allocator;
    const root = try makeFixture(io, &tmp, &buf);

    // A unique folder gets its slash right away.
    var a = try complete(gpa, io, root, "ki");
    defer a.deinit(gpa);
    try testing.expectEqualStrings("kitty/", a.common);
    try testing.expectEqual(@as(usize, 1), a.names.len);

    // Several matches: complete as far as unambiguous, plus the choices.
    const hypr = try std.fmt.allocPrint(gpa, "{s}/hypr", .{root});
    defer gpa.free(hypr);
    var b = try complete(gpa, io, hypr, "hy");
    defer b.deinit(gpa);
    try testing.expectEqualStrings("hyprl", b.common);
    try testing.expectEqual(@as(usize, 2), b.names.len);
    try testing.expectEqualStrings("hyprland.conf", b.names[0]);

    // Lowercase input also finds uppercase names.
    var c = try complete(gpa, io, root, "anf");
    defer c.deinit(gpa);
    try testing.expectEqualStrings("Anfang.txt", c.common);

    // Dotfiles only on request.
    var d = try complete(gpa, io, root, "");
    defer d.deinit(gpa);
    for (d.names) |n| try testing.expect(n[0] != '.');
    var e = try complete(gpa, io, root, ".v");
    defer e.deinit(gpa);
    try testing.expectEqualStrings(".versteckt", e.common);

    // No match: input stays as it is.
    var f = try complete(gpa, io, root, "gibtsnicht");
    defer f.deinit(gpa);
    try testing.expectEqualStrings("gibtsnicht", f.common);
    try testing.expectEqual(@as(usize, 0), f.names.len);

    try testing.expectError(error.FileNotFound, complete(gpa, io, "/gibt/es/nicht", "x"));
}

test "mount list is not empty (Zig 0.17 pitfall with /proc)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const mounts = mountPoints(arena_state.allocator(), std.testing.io);
    var has_root = false;
    for (mounts) |m| {
        if (std.mem.eql(u8, m, "/")) has_root = true;
    }
    try std.testing.expect(has_root);
}
