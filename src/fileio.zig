// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Loading files and saving them safely.
//!
//! Two guarantees live here:
//!
//! 1. A file that iro loads and saves unchanged is byte-for-byte identical
//! afterwards. Line endings (Unix or Windows), the final newline and a BOM stay
//! as they were.
//!
//! 2. Saving never destroys the original. The new content is first written
//! completely to a temporary file and forced to disk. Only then is it moved
//! over the original. If power fails halfway, either the old or the new version
//! is there, never half of one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Buffer = @import("buffer.zig").Buffer;

/// iro does not load larger files. The buffer is built for configs and source
/// code, not database dumps.
pub const max_file_size = 256 * 1024 * 1024;

const bom = "\xEF\xBB\xBF";

pub const Eol = enum {
    lf,
    crlf,

    pub fn bytes(self: Eol) []const u8 {
        return switch (self) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    }
};

/// What iro remembers about a file in order to write it back faithfully.
pub const Meta = struct {
    eol: Eol = .lf,
    final_newline: bool = true,
    bom: bool = false,
    /// The file was completely empty when loaded (or is new).
    was_empty: bool = false,
    /// Modification time and size at the last load or save. This is how iro
    /// notices that another program has changed the file in the meantime.
    disk: ?struct { mtime: Io.Timestamp, size: u64 } = null,
};

pub const Loaded = struct {
    buf: Buffer,
    meta: Meta,
};

pub const DecodeError = Allocator.Error || error{NotUtf8};

/// Splits file content into the buffer and the file info. Pure computation, no file
/// access.
pub fn decode(gpa: Allocator, raw: []const u8) DecodeError!Loaded {
    var meta: Meta = .{};
    var content = raw;

    if (std.mem.startsWith(u8, content, bom)) {
        meta.bom = true;
        content = content[bom.len..];
    }
    if (!std.unicode.utf8ValidateSlice(content)) return error.NotUtf8;

    // Assume Windows line endings only if really every line ends that way.
    const lf_count = std.mem.count(u8, content, "\n");
    const crlf_count = std.mem.count(u8, content, "\r\n");
    if (lf_count > 0 and lf_count == crlf_count) meta.eol = .crlf;

    const eol = meta.eol.bytes();
    if (content.len == 0) {
        meta.final_newline = true; // new files end properly with a newline
        meta.was_empty = true;
    } else if (std.mem.endsWith(u8, content, eol)) {
        meta.final_newline = true;
        content = content[0 .. content.len - eol.len];
    } else {
        meta.final_newline = false;
    }

    if (meta.eol == .lf) {
        return .{ .buf = try Buffer.fromBytes(gpa, content), .meta = meta };
    }
    const unix = try std.mem.replaceOwned(u8, gpa, content, "\r\n", "\n");
    defer gpa.free(unix);
    return .{ .buf = try Buffer.fromBytes(gpa, unix), .meta = meta };
}

/// Rebuilds the file content from buffer and file info. Caller owns the result.
pub fn encode(gpa: Allocator, buf: *const Buffer, meta: Meta) Allocator.Error![]u8 {
    const eol = meta.eol.bytes();
    const body = try buf.toBytes(gpa, eol);
    defer gpa.free(body);

    // An empty file that still contains nothing stays empty.
    const stays_empty = meta.was_empty and body.len == 0;
    const tail: []const u8 = if (meta.final_newline and !stays_empty) eol else "";
    const head: []const u8 = if (meta.bom) bom else "";

    const out = try gpa.alloc(u8, head.len + body.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..][0..body.len], body);
    @memcpy(out[head.len + body.len ..], tail);
    return out;
}

/// Loads a file. `error.FileNotFound` means it does not exist yet.
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !Loaded {
    const raw = dir.readFileAlloc(io, path, gpa, .limited(max_file_size)) catch |err| switch (err) {
        error.StreamTooLong => return error.FileTooBig,
        else => return err,
    };
    defer gpa.free(raw);
    var loaded = try decode(gpa, raw);
    errdefer loaded.buf.deinit();
    loaded.meta.disk = diskState(io, dir, path);
    return loaded;
}

fn diskState(io: Io, dir: Io.Dir, path: []const u8) @FieldType(Meta, "disk") {
    const st = dir.statFile(io, path, .{}) catch return null;
    return .{ .mtime = st.mtime, .size = st.size };
}

/// Has another program changed the file since the last load or save?
pub fn changedOnDisk(io: Io, dir: Io.Dir, path: []const u8, meta: Meta) bool {
    const known = meta.disk orelse return false;
    const now = diskState(io, dir, path) orelse return false;
    return now.size != known.size or !std.meta.eql(now.mtime, known.mtime);
}

/// Saves the text and updates the file info.
pub fn save(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, buf: *const Buffer, meta: *Meta) !void {
    const bytes = try encode(gpa, buf, meta.*);
    defer gpa.free(bytes);
    try writeAtomic(io, dir, path, bytes);
    meta.disk = diskState(io, dir, path);
}

/// Permissions for files that concern only the owner (backups).
pub const private_file: Io.File.Permissions = .fromMode(0o600);
pub const private_dir: Io.File.Permissions = .fromMode(0o700);

/// Writes `bytes` to `path` so that a half-written file never exists.
pub fn writeAtomic(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    return writeAtomicMode(io, dir, path, bytes, null);
}

/// Like `writeAtomic`. `fresh` is the mode in case the file is new (`null`: the
/// usual one). An existing file always keeps its mode.
pub fn writeAtomicMode(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8, fresh: ?Io.File.Permissions) !void {
    // If the target is a symlink (common with dotfiles), write to the real file
    // behind it. Otherwise the link would be replaced by a regular file.
    var real_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const target: []const u8 = if (dir.realPathFile(io, path, &real_buf)) |n| real_buf[0..n] else |_| path;

    const dir_path = std.fs.path.dirname(target) orelse ".";
    const base = std.fs.path.basename(target);
    const old_stat: ?Io.File.Stat = dir.statFile(io, target, .{}) catch null;

    // The temporary file gets its mode at creation, not after writing.
    // Otherwise the content of a protected file would briefly be readable by
    // everyone.
    const wanted: ?Io.File.Permissions = if (old_stat) |st| st.permissions else fresh;

    var tdir = dir.openDir(io, dir_path, .{}) catch return writeInPlace(io, dir, target, bytes, fresh);
    defer tdir.close(io);

    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    var name_buf: [300]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&name_buf, ".{s}.iro-{x}.tmp", .{
        base[0..@min(base.len, 200)],
        std.mem.readInt(u64, &rnd, .little),
    }) catch unreachable;

    // If no temporary file can be created in the folder (e.g. only the file
    // itself is writable), overwriting in place is the only option.
    var file = tdir.createFile(io, tmp_name, .{
        .exclusive = true,
        // Never allow more than owner-only at creation, until the final mode is
        // set.
        .permissions = private_file,
    }) catch return writeInPlace(io, dir, target, bytes, fresh);
    var file_open = true;
    errdefer {
        if (file_open) file.close(io);
        tdir.deleteFile(io, tmp_name) catch {};
    }

    try file.writeStreamingAll(io, bytes);
    // The new file gets the same mode as the old one. New files get what the
    // shell would give them (default minus umask).
    file.setPermissions(io, wanted orelse defaultFilePermissions()) catch {};
    try file.sync(io);
    file.close(io);
    file_open = false;

    try tdir.rename(tmp_name, tdir, base, io);
    // The folder must reach the disk too, otherwise the rename can be lost on
    // power failure.
    syncDir(tdir);
}

/// The mode a newly created file usually gets.
fn defaultFilePermissions() Io.File.Permissions {
    const linux = std.os.linux;
    if (@import("builtin").os.tag != .linux) return .default_file;
    // The umask can only be read by setting it and restoring it.
    const mask = linux.syscall1(.umask, 0o077);
    _ = linux.syscall1(.umask, mask);
    return .fromMode(@intCast(0o666 & ~mask));
}

fn syncDir(dir: Io.Dir) void {
    if (@import("builtin").os.tag != .linux) return;
    _ = std.os.linux.fsync(dir.handle);
}

fn writeInPlace(io: Io, dir: Io.Dir, target: []const u8, bytes: []const u8, fresh: ?Io.File.Permissions) !void {
    var file = try dir.createFile(io, target, .{ .permissions = fresh orelse .default_file });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

// ───────────────────────────── Tests ─────────────────────────────

const testing = std.testing;

fn roundTrip(raw: []const u8) !void {
    var loaded = try decode(testing.allocator, raw);
    defer loaded.buf.deinit();
    try loaded.buf.checkInvariants();
    const out = try encode(testing.allocator, &loaded.buf, loaded.meta);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(raw, out);
}

test "loading and saving unchanged yields identical bytes" {
    try roundTrip("");
    try roundTrip("eine zeile");
    try roundTrip("eine zeile\n");
    try roundTrip("a\nb\nc\n");
    try roundTrip("a\n\n\n");
    try roundTrip("\n");
    try roundTrip("windows\r\nzeilen\r\n");
    try roundTrip("windows\r\nohne ende");
    try roundTrip("gemischt\r\nund\nso\n");
    try roundTrip(bom ++ "mit bom\n");
    try roundTrip("Größe 🦅 👨‍👩‍👧\n");
}

test "Windows line endings are detected and hidden" {
    var loaded = try decode(testing.allocator, "eins\r\nzwei\r\n");
    defer loaded.buf.deinit();
    try testing.expectEqual(Eol.crlf, loaded.meta.eol);
    try testing.expectEqual(@as(usize, 2), loaded.buf.lineCount());
    try testing.expectEqualStrings("eins", loaded.buf.line(0));
}

test "non-UTF-8 is rejected" {
    try testing.expectError(error.NotUtf8, decode(testing.allocator, "bin\xff\xfe\x00"));
}

test "save and reload from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try testing.expectError(error.FileNotFound, load(testing.allocator, io, tmp.dir, "neu.txt"));

    var buf = try Buffer.fromBytes(testing.allocator, "hallo\nwelt");
    defer buf.deinit();
    var meta: Meta = .{};
    try save(testing.allocator, io, tmp.dir, "neu.txt", &buf, &meta);
    try testing.expect(!changedOnDisk(io, tmp.dir, "neu.txt", meta));

    var loaded = try load(testing.allocator, io, tmp.dir, "neu.txt");
    defer loaded.buf.deinit();
    try testing.expectEqualStrings("welt", loaded.buf.line(1));

    // Overwriting an existing file leaves no temporary file behind.
    _ = try buf.insert(buf.endPos(), "!");
    try save(testing.allocator, io, tmp.dir, "neu.txt", &buf, &meta);
    const raw = try tmp.dir.readFileAlloc(io, "neu.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(raw);
    try testing.expectEqualStrings("hallo\nwelt!\n", raw);

    var d = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "file permissions survive saving" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try writeAtomic(io, tmp.dir, "skript.sh", "#!/bin/sh\n");
    {
        var f = try tmp.dir.openFile(io, "skript.sh", .{ .mode = .read_write });
        defer f.close(io);
        try f.setPermissions(io, .executable_file);
    }
    const before = try tmp.dir.statFile(io, "skript.sh", .{});
    try writeAtomic(io, tmp.dir, "skript.sh", "#!/bin/sh\necho neu\n");
    const after = try tmp.dir.statFile(io, "skript.sh", .{});
    try testing.expectEqual(before.permissions, after.permissions);
}

test "permissions: protected file stays protected, new file follows umask" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try writeAtomicMode(io, tmp.dir, "geheim.swap", "abc\n", private_file);
    const s1 = try tmp.dir.statFile(io, "geheim.swap", .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(s1.permissions.toMode() & 0o777)));
    // Overwriting without a mode keeps the permissions.
    try writeAtomic(io, tmp.dir, "geheim.swap", "def\n");
    const s2 = try tmp.dir.statFile(io, "geheim.swap", .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(s2.permissions.toMode() & 0o777)));

    // An ordinary new file is not suddenly owner-only.
    try writeAtomic(io, tmp.dir, "normal.txt", "abc\n");
    const s3 = try tmp.dir.statFile(io, "normal.txt", .{});
    try testing.expectEqual(defaultFilePermissions().toMode() & 0o777, s3.permissions.toMode() & 0o777);
}

test "symlink stays a symlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try writeAtomic(io, tmp.dir, "echt.conf", "alt\n");
    try tmp.dir.symLink(io, "echt.conf", "verweis.conf", .{});
    try writeAtomic(io, tmp.dir, "verweis.conf", "neu\n");

    const raw = try tmp.dir.readFileAlloc(io, "echt.conf", testing.allocator, .limited(1024));
    defer testing.allocator.free(raw);
    try testing.expectEqualStrings("neu\n", raw);

    var link_buf: [256]u8 = undefined;
    const n = try tmp.dir.readLink(io, "verweis.conf", &link_buf);
    try testing.expectEqualStrings("echt.conf", link_buf[0..n]);
}

test "external change on disk is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try writeAtomic(io, tmp.dir, "a.txt", "eins\n");
    var loaded = try load(testing.allocator, io, tmp.dir, "a.txt");
    defer loaded.buf.deinit();
    try testing.expect(!changedOnDisk(io, tmp.dir, "a.txt", loaded.meta));
    try writeAtomic(io, tmp.dir, "a.txt", "eins und mehr\n");
    try testing.expect(changedOnDisk(io, tmp.dir, "a.txt", loaded.meta));
}
