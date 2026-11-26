// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! The file tree: which folders are expanded and what is on which row.
//!
//! The tree is a flat list in exactly the order it appears on screen. Each
//! entry knows its depth. Expanding inserts the children right after the
//! folder, collapsing removes them again. A folder is only read when it is
//! expanded.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const finder = @import("finder.zig");

pub const Entry = struct {
    name: []u8,
    depth: u16,
    is_dir: bool,
    expanded: bool = false,
};

/// iro reads no more entries than this from a single folder. Anyone ending up
/// there isn't searching by eye anyway.
pub const max_per_dir = 5000;

pub const Tree = struct {
    gpa: Allocator,
    /// Full path of the top folder.
    root: []u8,
    entries: std.ArrayList(Entry) = .empty,
    selected: usize = 0,
    /// Show dotfiles too? Yes by default; half the work lives in ~/.config.
    show_hidden: bool = true,

    pub fn init(gpa: Allocator, io: Io, root: []const u8) !Tree {
        var self: Tree = .{ .gpa = gpa, .root = try gpa.dupe(u8, root) };
        errdefer gpa.free(self.root);
        const top = try self.readDir(io, self.root, 0);
        defer gpa.free(top);
        errdefer freeNames(gpa, top);
        try self.entries.appendSlice(gpa, top);
        return self;
    }

    pub fn deinit(self: *Tree) void {
        freeNames(self.gpa, self.entries.items);
        self.entries.deinit(self.gpa);
        self.gpa.free(self.root);
    }

    fn freeNames(gpa: Allocator, list: []const Entry) void {
        for (list) |e| gpa.free(e.name);
    }

    /// Reads a folder: folders first, then files, each sorted by name,
    /// case-insensitive.
    fn readDir(self: *const Tree, io: Io, path: []const u8, depth: u16) ![]Entry {
        const gpa = self.gpa;
        var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);

        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            freeNames(gpa, list.items);
            list.deinit(gpa);
        }
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (list.items.len >= max_per_dir) break;
            if (!self.show_hidden and e.name.len > 0 and e.name[0] == '.') continue;
            // Names that are not valid text cannot be shown by the terminal or
            // opened safely by iro. They stay out.
            if (!std.unicode.utf8ValidateSlice(e.name)) continue;
            // Symlinks show where they lead.
            const is_dir = finder.isDir(dir, io, e);
            const name = try gpa.dupe(u8, e.name);
            errdefer gpa.free(name);
            try list.append(gpa, .{ .name = name, .depth = depth, .is_dir = is_dir });
        }
        std.mem.sort(Entry, list.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return switch (std.ascii.orderIgnoreCase(a.name, b.name)) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.lessThan(u8, a.name, b.name),
                };
            }
        }.lessThan);
        return list.toOwnedSlice(gpa);
    }

    /// The folder containing the entry. `null`: top level.
    pub fn parentOf(self: *const Tree, index: usize) ?usize {
        const depth = self.entries.items[index].depth;
        if (depth == 0) return null;
        var i = index;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i].depth < depth) return i;
        }
        return null;
    }

    /// Full path of an entry. Caller owns the result.
    pub fn pathOf(self: *const Tree, gpa: Allocator, index: usize) Allocator.Error![]u8 {
        var total = self.root.len;
        var i: ?usize = index;
        while (i) |n| : (i = self.parentOf(n)) total += 1 + self.entries.items[n].name.len;

        const out = try gpa.alloc(u8, total);
        // Fill from back to front: first the name, then its folders.
        var end = total;
        i = index;
        while (i) |n| : (i = self.parentOf(n)) {
            const name = self.entries.items[n].name;
            end -= name.len;
            @memcpy(out[end..][0..name.len], name);
            end -= 1;
            out[end] = '/';
        }
        @memcpy(out[0..self.root.len], self.root);
        // At the file system root the folder itself already ends in "/".
        if (std.mem.eql(u8, self.root, "/")) {
            std.mem.copyForwards(u8, out[0 .. total - 1], out[1..total]);
            return gpa.realloc(out, total - 1);
        }
        return out;
    }

    /// First entry after the folder that no longer lies inside it.
    fn endOfChildren(self: *const Tree, index: usize) usize {
        const depth = self.entries.items[index].depth;
        var j = index + 1;
        while (j < self.entries.items.len and self.entries.items[j].depth > depth) j += 1;
        return j;
    }

    pub fn expand(self: *Tree, io: Io, index: usize) !void {
        const e = &self.entries.items[index];
        if (!e.is_dir or e.expanded) return;
        const gpa = self.gpa;
        const path = try self.pathOf(gpa, index);
        defer gpa.free(path);
        const kids = try self.readDir(io, path, e.depth + 1);
        defer gpa.free(kids);
        self.entries.insertSlice(gpa, index + 1, kids) catch |err| {
            freeNames(gpa, kids);
            return err;
        };
        self.entries.items[index].expanded = true;
        if (self.selected > index) self.selected += kids.len;
    }

    pub fn collapse(self: *Tree, index: usize) void {
        const e = &self.entries.items[index];
        if (!e.is_dir or !e.expanded) return;
        const end = self.endOfChildren(index);
        const n = end - (index + 1);
        freeNames(self.gpa, self.entries.items[index + 1 .. end]);
        self.entries.replaceRangeAssumeCapacity(index + 1, n, &.{});
        e.expanded = false;
        if (self.selected >= end) {
            self.selected -= n;
        } else if (self.selected > index) {
            self.selected = index;
        }
    }

    pub fn toggle(self: *Tree, io: Io, index: usize) !void {
        if (self.entries.items[index].expanded) self.collapse(index) else try self.expand(io, index);
    }

    /// Selects the entry with this full path, if it is currently visible.
    pub fn selectPath(self: *Tree, path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, self.root)) return false;
        for (self.entries.items, 0..) |_, i| {
            const p = self.pathOf(self.gpa, i) catch return false;
            defer self.gpa.free(p);
            if (std.mem.eql(u8, p, path)) {
                self.selected = i;
                return true;
            }
        }
        return false;
    }

    /// Makes another folder the top one. If reading fails, the tree stays as it
    /// was.
    pub fn setRoot(self: *Tree, io: Io, new_root: []const u8) !void {
        var fresh = try Tree.init(self.gpa, io, new_root);
        fresh.show_hidden = self.show_hidden;
        if (!fresh.show_hidden) {
            // The fresh tree was still read including dotfiles.
            fresh.refresh(io) catch |err| {
                fresh.deinit();
                return err;
            };
        }
        self.deinit();
        self.* = fresh;
    }

    /// One level up. The folder you came from is selected afterwards.
    pub fn goUp(self: *Tree, io: Io) !void {
        const parent = std.fs.path.dirname(self.root) orelse return;
        const came_from = try self.gpa.dupe(u8, self.root);
        defer self.gpa.free(came_from);
        try self.setRoot(io, parent);
        _ = self.selectPath(came_from);
    }

    /// Rereads everything from disk. Expanded folders stay expanded, and the selection
    /// stays on the same entry if it still exists.
    pub fn refresh(self: *Tree, io: Io) !void {
        const gpa = self.gpa;
        var open: std.ArrayList([]u8) = .empty;
        defer {
            for (open.items) |p| gpa.free(p);
            open.deinit(gpa);
        }
        for (self.entries.items, 0..) |e, i| {
            if (!e.expanded) continue;
            const p = try self.pathOf(gpa, i);
            errdefer gpa.free(p);
            try open.append(gpa, p);
        }
        const chosen: ?[]u8 = if (self.selected < self.entries.items.len) try self.pathOf(gpa, self.selected) else null;
        defer if (chosen) |c| gpa.free(c);
        const old_selected = self.selected;

        const top = try self.readDir(io, self.root, 0);
        defer gpa.free(top);
        // Only now that reading has succeeded, discard the old state.
        freeNames(gpa, self.entries.items);
        self.entries.clearRetainingCapacity();
        self.selected = 0;
        self.entries.appendSlice(gpa, top) catch |err| {
            freeNames(gpa, top);
            return err;
        };

        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            if (!self.entries.items[i].is_dir) continue;
            const p = try self.pathOf(gpa, i);
            defer gpa.free(p);
            for (open.items) |o| {
                if (std.mem.eql(u8, o, p)) {
                    // If the folder is gone or locked by now, it simply stays
                    // collapsed.
                    self.expand(io, i) catch {};
                    break;
                }
            }
        }
        const found = if (chosen) |c| self.selectPath(c) else false;
        if (!found) self.selected = @min(old_selected, self.entries.items.len -| 1);
    }

    pub fn toggleHidden(self: *Tree, io: Io) !void {
        self.show_hidden = !self.show_hidden;
        self.refresh(io) catch |err| {
            self.show_hidden = !self.show_hidden;
            return err;
        };
    }

    pub fn moveSelection(self: *Tree, delta: isize) void {
        const n = self.entries.items.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.selected);
        self.selected = @intCast(std.math.clamp(cur + delta, 0, @as(isize, @intCast(n - 1))));
    }
};

// ───────────── Tests ─────────────

const testing = std.testing;

/// Creates a small practice folder and returns its full path.
fn makeFixture(io: Io, tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    try tmp.dir.createDirPath(io, "zeug/tief");
    try tmp.dir.createDirPath(io, "Alpha");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "A.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".versteckt", .data = "v" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zeug/innen.txt", .data = "i" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zeug/tief/ganz_unten.txt", .data = "u" });
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

fn expectNames(tree: *const Tree, want: []const []const u8) !void {
    try testing.expectEqual(want.len, tree.entries.items.len);
    for (want, tree.entries.items) |w, e| try testing.expectEqualStrings(w, e.name);
}

test "folders first, then files by name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try makeFixture(testing.io, &tmp, &buf);

    var tree = try Tree.init(testing.allocator, testing.io, root);
    defer tree.deinit();
    try expectNames(&tree, &.{ "Alpha", "zeug", ".versteckt", "A.txt", "b.txt" });
    try testing.expect(tree.entries.items[0].is_dir);
    try testing.expect(!tree.entries.items[3].is_dir);
}

test "expand, paths, collapse" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const io = testing.io;
    const gpa = testing.allocator;
    const root = try makeFixture(io, &tmp, &buf);

    var tree = try Tree.init(gpa, io, root);
    defer tree.deinit();
    tree.selected = 4; // b.txt
    try tree.expand(io, 1); // zeug
    try expectNames(&tree, &.{ "Alpha", "zeug", "tief", "innen.txt", ".versteckt", "A.txt", "b.txt" });
    try testing.expectEqual(@as(usize, 6), tree.selected); // still b.txt
    try tree.expand(io, 2); // zeug/tief
    try testing.expectEqualStrings("ganz_unten.txt", tree.entries.items[3].name);
    try testing.expectEqual(@as(u16, 2), tree.entries.items[3].depth);
    try testing.expectEqual(@as(?usize, 2), tree.parentOf(3));
    try testing.expectEqual(@as(?usize, null), tree.parentOf(0));

    const p = try tree.pathOf(gpa, 3);
    defer gpa.free(p);
    const want = try std.fmt.allocPrint(gpa, "{s}/zeug/tief/ganz_unten.txt", .{root});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, p);
    try testing.expect(tree.selectPath(want));
    try testing.expectEqual(@as(usize, 3), tree.selected);

    // Collapsing also removes the deeper levels; the selection moves to the folder.
    tree.collapse(1);
    try expectNames(&tree, &.{ "Alpha", "zeug", ".versteckt", "A.txt", "b.txt" });
    try testing.expectEqual(@as(usize, 1), tree.selected);
    try testing.expect(!tree.selectPath(want));
}

test "hide dotfiles and reread" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const io = testing.io;
    const root = try makeFixture(io, &tmp, &buf);

    var tree = try Tree.init(testing.allocator, io, root);
    defer tree.deinit();
    try tree.expand(io, 1);
    tree.selected = 6; // b.txt
    try tree.toggleHidden(io);
    // "zeug" is still expanded, the dotfile is gone, b.txt stays selected.
    try expectNames(&tree, &.{ "Alpha", "zeug", "tief", "innen.txt", "A.txt", "b.txt" });
    try testing.expectEqual(@as(usize, 5), tree.selected);

    // A new file appears after rereading, a deleted folder disappears.
    try tmp.dir.writeFile(io, .{ .sub_path = "neu.txt", .data = "" });
    try tmp.dir.deleteTree(io, "zeug");
    try tree.refresh(io);
    try expectNames(&tree, &.{ "Alpha", "A.txt", "b.txt", "neu.txt" });
    try testing.expectEqual(@as(usize, 2), tree.selected);
}

test "going up a level selects the folder you came from" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const io = testing.io;
    const gpa = testing.allocator;
    const root = try makeFixture(io, &tmp, &buf);

    const sub = try std.fmt.allocPrint(gpa, "{s}/zeug", .{root});
    defer gpa.free(sub);
    var tree = try Tree.init(gpa, io, sub);
    defer tree.deinit();
    try expectNames(&tree, &.{ "tief", "innen.txt" });
    try tree.goUp(io);
    try testing.expectEqualStrings(root, tree.root);
    try testing.expectEqualStrings("zeug", tree.entries.items[tree.selected].name);

    // A folder that doesn't exist leaves the tree untouched.
    try testing.expectError(error.FileNotFound, tree.setRoot(io, "/gibt/es/nicht"));
    try testing.expectEqualStrings(root, tree.root);
}

test "symlink to a folder counts as a folder" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const io = testing.io;
    const root = try makeFixture(io, &tmp, &buf);
    try tmp.dir.symLink(io, "zeug", "abkürzung", .{});
    try tmp.dir.symLink(io, "nirgendwo", "kaputt", .{});

    var tree = try Tree.init(testing.allocator, io, root);
    defer tree.deinit();
    try expectNames(&tree, &.{ "abkürzung", "Alpha", "zeug", ".versteckt", "A.txt", "b.txt", "kaputt" });
    try tree.expand(io, 0);
    try testing.expectEqualStrings("tief", tree.entries.items[1].name);
}
