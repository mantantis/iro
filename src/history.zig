// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Local history: before iro overwrites a file, the old content goes into
//! iro's state folder. Each file keeps its last `max_versions` states, named by
//! the time they were written, so "how did this look before my change?" has an
//! answer even after the tab is long closed.
//!
//! Secrets get no copies: files only their owner may read (SSH keys, WireGuard
//! configs, tokens) and a few well-known names like `.env` are skipped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fileio = @import("fileio.zig");

pub const max_versions = 20;
/// Larger files get no history. It is meant for configs and source code.
pub const max_size = 2 * 1024 * 1024;

const ext = ".v";

/// Should `path` get copies at all? `mode` is its permission bits.
pub fn wanted(path: []const u8, mode: u32) bool {
    // Only the owner may read it: treat it as a secret.
    if (mode & 0o044 == 0) return false;
    const secret_dirs = [_][]const u8{ "/.ssh/", "/.gnupg/", "/.password-store/", "/etc/wireguard/" };
    for (secret_dirs) |d| if (std.mem.indexOf(u8, path, d) != null) return false;
    const base = std.fs.path.basename(path);
    const secret_names = [_][]const u8{ ".env", ".netrc", ".git-credentials", ".pgpass", "shadow", "gshadow" };
    for (secret_names) |n| if (std.mem.eql(u8, base, n)) return false;
    const secret_prefixes = [_][]const u8{ ".env.", "id_" };
    for (secret_prefixes) |p| if (std.mem.startsWith(u8, base, p)) return false;
    const secret_exts = [_][]const u8{ ".key", ".pem", ".p12", ".pfx", ".kdbx", ".age", ".gpg", ".asc" };
    for (secret_exts) |e| if (std.mem.endsWith(u8, base, e)) return false;
    return true;
}

/// Folder holding the versions of `path`, below `root` (iro's history folder).
pub fn dirFor(buf: []u8, root: []const u8, path: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{x:0>16}", .{ root, std.hash.Wyhash.hash(0, path) }) catch null;
}

pub const Version = struct {
    /// File name inside the folder; its number is the time in nanoseconds.
    name: []const u8,
    written_ns: i96,
};

/// Before saving: puts the file's current content into its history. Does
/// nothing if the file doesn't exist yet, is too large, is a secret or is
/// already the newest version.
pub fn keep(gpa: Allocator, io: Io, root: []const u8, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch return;
    if (st.kind != .file or st.size > max_size) return;
    if (!wanted(path, @intCast(st.permissions.toMode() & 0o777))) return;
    const old = cwd.readFileAlloc(io, path, gpa, .limited(max_size)) catch return;
    defer gpa.free(old);
    try store(gpa, io, root, path, old, st.mtime.nanoseconds);
}

/// Puts `bytes` (unsaved text that is about to be replaced, say) into the
/// history of `path`, stamped with the current time. Same rules as `keep`.
/// Returns whether a copy exists afterwards.
pub fn keepBytes(gpa: Allocator, io: Io, root: []const u8, path: []const u8, bytes: []const u8) !bool {
    if (bytes.len > max_size) return false;
    const mode: u32 = if (Io.Dir.cwd().statFile(io, path, .{})) |st| @intCast(st.permissions.toMode() & 0o777) else |_| 0o644;
    if (!wanted(path, mode)) return false;
    try store(gpa, io, root, path, bytes, Io.Timestamp.now(io, .real).nanoseconds);
    return true;
}

fn store(gpa: Allocator, io: Io, root: []const u8, path: []const u8, old: []const u8, written_ns: i96) !void {
    const cwd = Io.Dir.cwd();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dirFor(&dir_buf, root, path) orelse return;
    try cwd.createDirPath(io, dir_path);
    // Copies of configs stay as private as the backups.
    cwd.setFilePermissions(io, root, fileio.private_dir, .{}) catch {};
    cwd.setFilePermissions(io, dir_path, fileio.private_dir, .{}) catch {};
    var dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const versions = try listIn(arena, io, dir);
    if (versions.len > 0) {
        const newest = dir.readFileAlloc(io, versions[0].name, arena, .limited(max_size)) catch "";
        if (std.mem.eql(u8, newest, old)) return;
    }

    var name_buf: [32]u8 = undefined;
    const written: u96 = @intCast(@max(written_ns, 0));
    const name = std.fmt.bufPrint(&name_buf, "{d:0>24}" ++ ext, .{written}) catch return;
    try fileio.writeAtomicMode(io, dir, name, old, fileio.private_file);
    // For humans looking into the folder: which file this is.
    if (dir.statFile(io, "path", .{})) |_| {} else |_| {
        const line = try std.mem.concat(arena, u8, &.{ path, "\n" });
        fileio.writeAtomicMode(io, dir, "path", line, fileio.private_file) catch {};
    }

    // The new version is not in `versions` yet: keep max_versions - 1 of those.
    if (versions.len >= max_versions) {
        for (versions[max_versions - 1 ..]) |v| dir.deleteFile(io, v.name) catch {};
    }
}

/// All versions of `path`, newest first. Empty if there are none.
pub fn list(arena: Allocator, io: Io, root: []const u8, path: []const u8) ![]Version {
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dirFor(&dir_buf, root, path) orelse return &.{};
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    return listIn(arena, io, dir);
}

fn listIn(arena: Allocator, io: Io, dir: Io.Dir) ![]Version {
    var out: std.ArrayList(Version) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ext)) continue;
        const ns = std.fmt.parseInt(u96, e.name[0 .. e.name.len - ext.len], 10) catch continue;
        try out.append(arena, .{ .name = try arena.dupe(u8, e.name), .written_ns = @intCast(ns) });
    }
    std.mem.sortUnstable(Version, out.items, {}, struct {
        fn newer(_: void, a: Version, b: Version) bool {
            return a.written_ns > b.written_ns;
        }
    }.newer);
    return out.items;
}

/// Content of one version. Caller owns the result.
pub fn read(gpa: Allocator, io: Io, root: []const u8, path: []const u8, v: Version) ![]u8 {
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dirFor(&dir_buf, root, path) orelse return error.NameTooLong;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, v.name, gpa, .limited(max_size));
}

// ───────────────────────────── Tests ─────────────────────────────

const testing = std.testing;

test "secrets get no copies" {
    try testing.expect(wanted("/home/m/.config/hypr/hyprland.lua", 0o644));
    try testing.expect(!wanted("/home/m/.config/rclone/rclone.conf", 0o600));
    try testing.expect(!wanted("/home/m/.ssh/config", 0o644));
    try testing.expect(!wanted("/home/m/projekt/.env", 0o644));
    try testing.expect(!wanted("/home/m/projekt/.env.local", 0o644));
    try testing.expect(!wanted("/etc/ssl/private/server.key", 0o644));
    try testing.expect(!wanted("/etc/wireguard/wg0.conf", 0o644));
}

test "versions: kept before saving, deduplicated, capped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = buf[0..n];
    const file = try std.fs.path.join(gpa, &.{ base, "a.conf" });
    defer gpa.free(file);
    const root = try std.fs.path.join(gpa, &.{ base, "history" });
    defer gpa.free(root);

    // Nothing to keep before the file exists.
    try keep(gpa, io, root, file);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try list(arena.allocator(), io, root, file)).len);

    var i: usize = 0;
    while (i < max_versions + 5) : (i += 1) {
        var content_buf: [32]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "stand {d}\n", .{i});
        try fileio.writeAtomic(io, Io.Dir.cwd(), file, content);
        // mtime must differ between versions, even on coarse file systems.
        try Io.Dir.cwd().setTimestamps(io, file, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, @intCast(i + 1)) * std.time.ns_per_s } } });
        try keep(gpa, io, root, file);
        // The same content twice gives no second copy.
        try keep(gpa, io, root, file);
    }

    const versions = try list(arena.allocator(), io, root, file);
    try testing.expectEqual(@as(usize, max_versions), versions.len);
    const newest = try read(gpa, io, root, file, versions[0]);
    defer gpa.free(newest);
    try testing.expectEqualStrings("stand 24\n", newest);
    const oldest = try read(gpa, io, root, file, versions[versions.len - 1]);
    defer gpa.free(oldest);
    try testing.expectEqualStrings("stand 5\n", oldest);
}

test "unsaved text can be kept too, secrets excepted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = try std.fs.path.join(gpa, &.{ buf[0..n], "history" });
    defer gpa.free(root);
    const file = try std.fs.path.join(gpa, &.{ buf[0..n], "b.conf" });
    defer gpa.free(file);
    const secret = try std.fs.path.join(gpa, &.{ buf[0..n], ".env" });
    defer gpa.free(secret);

    try testing.expect(try keepBytes(gpa, io, root, file, "noch nicht gespeichert\n"));
    try testing.expect(!try keepBytes(gpa, io, root, secret, "TOKEN=geheim\n"));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const versions = try list(arena.allocator(), io, root, file);
    try testing.expectEqual(@as(usize, 1), versions.len);
    const got = try read(gpa, io, root, file, versions[0]);
    defer gpa.free(got);
    try testing.expectEqualStrings("noch nicht gespeichert\n", got);
    try testing.expectEqual(@as(usize, 0), (try list(arena.allocator(), io, root, secret)).len);
}
