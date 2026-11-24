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
//! is there, never half of one. Owner, group, extended attributes (ACLs
//! included) and hard links survive too: if a new file cannot carry them, iro
//! writes into the original instead of replacing it.

const std = @import("std");
const linux = std.os.linux;
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

/// Modification time and size of the file right now, `null` if it is gone.
pub fn diskState(io: Io, dir: Io.Dir, path: []const u8) @FieldType(Meta, "disk") {
    const st = dir.statFile(io, path, .{}) catch return null;
    return .{ .mtime = st.mtime, .size = st.size };
}

/// How long an external helper (`git`, `wl-paste`, `gio`, `zoxide`) may take
/// before iro gives up and kills it, so a hung clipboard or dead mount cannot
/// freeze the editor.
pub const helper_timeout_ms: i64 = 2_000;

/// Runs a short-lived helper program with output limits and a fixed deadline.
pub fn runHelper(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    stdout_limit: Io.Limit,
    stderr_limit: Io.Limit,
) std.process.RunError!std.process.RunResult {
    return runBounded(gpa, io, argv, stdout_limit, stderr_limit, helper_timeout_ms);
}

pub fn runBounded(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    stdout_limit: Io.Limit,
    stderr_limit: Io.Limit,
    timeout_ms: i64,
) std.process.RunError!std.process.RunResult {
    // Like `std.process.run`, which in Zig 0.17 only sends SIGTERM on timeout
    // and then waits without limit for the child to exit, and also waits
    // without limit once the child has closed its output. Here the deadline
    // covers everything, and a helper that overstays it is killed with its
    // whole process group (`git` and `gio` start helpers of their own).
    const deadline = (Io.Timeout{ .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    } }).toDeadline(io);
    reapAbandoned();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    var done = false;
    defer if (!done) killHard(io, &child);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(64, deadline)) |_| {
        if (stdout_limit.toInt()) |limit| if (stdout_reader.buffered().len > limit) return error.StreamTooLong;
        if (stderr_limit.toInt()) |limit| if (stderr_reader.buffered().len > limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try waitUntil(io, &child, deadline);
    done = true;
    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    return .{ .stdout = stdout_slice, .stderr = stderr_slice, .term = term };
}

/// Waits for the child to exit, but not past `deadline`.
fn waitUntil(io: Io, child: *std.process.Child, deadline: Io.Timeout) Io.Timeout.Error!std.process.Child.Term {
    const pid = child.id.?;
    const end = deadline.toTimestamp(io).?;
    var pause_ms: i64 = 1;
    while (true) {
        var status: c_int = 0;
        const got = std.c.wait4(pid, &status, std.posix.W.NOHANG, null);
        if (got == pid) {
            releaseChild(io, child);
            return std.Io.Threaded.statusToTerm(@bitCast(status));
        }
        if (got < 0 and std.posix.errno(got) != .INTR) {
            // Already reaped elsewhere: nothing left to wait for.
            releaseChild(io, child);
            return .{ .unknown = 0 };
        }
        if (Io.Timestamp.now(io, .awake).durationTo(end.raw).toMilliseconds() <= 0) return error.Timeout;
        io.sleep(.fromMilliseconds(pause_ms), .awake) catch return error.Timeout;
        pause_ms = @min(pause_ms * 2, 20);
    }
}

/// Closes the pipes and forgets the child, so `Child` holds nothing anymore.
fn releaseChild(io: Io, child: *std.process.Child) void {
    if (child.stdout) |f| f.close(io);
    if (child.stderr) |f| f.close(io);
    child.stdout = null;
    child.stderr = null;
    child.id = null;
}

/// Children killed but not yet gone (stuck in the kernel, for example on a
/// dead network mount). They are reaped later instead of being waited for.
var abandoned: [16]std.posix.pid_t = @splat(0);

fn killHard(io: Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    // The whole group first, then the child itself in case it left the group.
    _ = std.c.kill(-pid, std.posix.SIG.KILL);
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    // SIGKILL usually takes effect at once; a process stuck in the kernel only
    // dies when the kernel lets go. Wait briefly, never indefinitely.
    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        var status: c_int = 0;
        if (std.c.wait4(pid, &status, std.posix.W.NOHANG, null) != 0) break;
        io.sleep(.fromMilliseconds(5), .awake) catch break;
    } else for (&abandoned) |*slot| {
        if (slot.* == 0) {
            slot.* = pid;
            break;
        }
    }
    releaseChild(io, child);
}

fn reapAbandoned() void {
    for (&abandoned) |*slot| {
        if (slot.* == 0) continue;
        var status: c_int = 0;
        if (std.c.wait4(slot.*, &status, std.posix.W.NOHANG, null) != 0) slot.* = 0;
    }
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
    const target_z = std.posix.toPosixPath(target) catch return writeInPlace(io, dir, target, bytes, fresh);
    const old_owner: ?Owner = if (old_stat != null) ownerOf(dir.handle, &target_z, 0) else null;
    // A second name for the same file (hard link) would keep the old content
    // if the file were replaced.
    if (old_owner) |o| if (o.nlink > 1) return writeInPlace(io, dir, target, bytes, fresh);

    // The temporary file gets its mode at creation, not after writing.
    // Otherwise the content of a protected file would briefly be readable by
    // everyone.
    const wanted: ?Io.File.Permissions = if (old_stat) |st| st.permissions else fresh;

    // Only a missing permission justifies falling back to overwriting in place.
    // Any other error (full disk, quota, name too long) is reported, and the
    // file on disk stays untouched.
    var tdir = dir.openDir(io, dir_path, .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return writeInPlace(io, dir, target, bytes, fresh),
        else => return err,
    };
    defer tdir.close(io);

    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    var name_buf: [128]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&name_buf, ".{s}.iro-{x}.tmp", .{
        tmpPrefix(base),
        std.mem.readInt(u64, &rnd, .little),
    }) catch unreachable;

    // If no temporary file can be created in the folder (e.g. only the file
    // itself is writable), overwriting in place is the only option.
    var file = tdir.createFile(io, tmp_name, .{
        .exclusive = true,
        // Never allow more than owner-only at creation, until the final mode is
        // set.
        .permissions = private_file,
    }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return writeInPlace(io, dir, target, bytes, fresh),
        else => return err,
    };
    var file_open = true;
    errdefer {
        if (file_open) file.close(io);
        tdir.deleteFile(io, tmp_name) catch {};
    }

    try file.writeStreamingAll(io, bytes);
    // Owner and group first: changing them clears setuid/setgid, so the mode
    // comes after.
    const owner_kept = if (old_owner) |o| keepOwner(file.handle, o) else true;
    // The new file gets the same mode as the old one. New files get what the
    // shell would give them (default minus umask).
    if (owner_kept) file.setPermissions(io, wanted orelse defaultFilePermissions()) catch {};
    if (!owner_kept or (old_stat != null and !copyXattrs(&target_z, file.handle))) {
        // The new file cannot look like the old one (someone else's file, a
        // group we are not in, an attribute only root may set). Replacing it
        // would quietly change who may read it, so write into it instead.
        file.close(io);
        file_open = false;
        tdir.deleteFile(io, tmp_name) catch {};
        return writeInPlace(io, dir, target, bytes, fresh);
    }
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
    if (@import("builtin").os.tag != .linux) return .default_file;
    // The umask can only be read by setting it and restoring it.
    const mask = linux.syscall1(.umask, 0o077);
    _ = linux.syscall1(.umask, mask);
    return .fromMode(@intCast(0o666 & ~mask));
}

/// Everything about a file that replacing it by rename would silently change.
const Owner = struct { uid: linux.uid_t, gid: linux.gid_t, nlink: u32 };

/// `path` relative to `fd`; an empty path with `AT_EMPTY_PATH` means `fd` itself.
fn ownerOf(fd: linux.fd_t, path: [*:0]const u8, flags: u32) ?Owner {
    var sx: linux.Statx = undefined;
    const rc = linux.statx(fd, path, flags, .{ .UID = true, .GID = true, .NLINK = true }, &sx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .uid = sx.uid, .gid = sx.gid, .nlink = sx.nlink };
}

/// Gives the new file the owner and group of the old one. Without root only
/// the group can change, and only to one we are in. Returns whether both match.
fn keepOwner(fd: linux.fd_t, want: Owner) bool {
    const have = ownerOf(fd, "", linux.AT.EMPTY_PATH) orelse return false;
    if (have.uid == want.uid and have.gid == want.gid) return true;
    return linux.errno(linux.fchown(fd, want.uid, want.gid)) == .SUCCESS;
}

/// Copies all extended attributes (POSIX ACLs live there too) from `src` to
/// the new file. Returns false if one cannot be copied.
fn copyXattrs(src: [*:0]const u8, dst: linux.fd_t) bool {
    var names: [64 * 1024]u8 = undefined;
    const len = linux.listxattr(src, &names, names.len);
    switch (linux.errno(len)) {
        .SUCCESS => {},
        .OPNOTSUPP => return true, // the file system has none
        else => return false,
    }
    // A list of NUL-terminated names.
    var i: usize = 0;
    while (i < len) {
        const name: [*:0]const u8 = @ptrCast(names[i..].ptr);
        const name_len = std.mem.len(name);
        i += name_len + 1;
        if (name_len == 0) continue;
        var value: [64 * 1024]u8 = undefined;
        const value_len = linux.getxattr(src, name, &value, value.len);
        if (linux.errno(value_len) != .SUCCESS) return false;
        if (linux.errno(linux.fsetxattr(dst, name, &value, value_len, 0)) != .SUCCESS) return false;
    }
    return true;
}

fn syncDir(dir: Io.Dir) void {
    if (@import("builtin").os.tag != .linux) return;
    _ = std.os.linux.fsync(dir.handle);
}

/// Start of the file name for the temporary file. Kept short because some file
/// systems (eCryptfs) allow far less than 255 bytes per name, and cut only
/// between whole UTF-8 characters.
fn tmpPrefix(base: []const u8) []const u8 {
    var n = @min(base.len, 64);
    while (n > 0 and n < base.len and (base[n] & 0xC0) == 0x80) n -= 1;
    return base[0..n];
}

/// Overwrites the file itself. Used only when the replace-by-rename way is not
/// possible. The old content is not cut off up front: space for the new content
/// is reserved first, and the file is shortened only after everything has been
/// written. On a full disk the old file stays as it was. (Copy-on-write file
/// systems like btrfs can still run out of space while overwriting; then the
/// file is mixed, but never empty.)
fn writeInPlace(io: Io, dir: Io.Dir, target: []const u8, bytes: []const u8, fresh: ?Io.File.Permissions) !void {
    var file = try dir.createFile(io, target, .{ .truncate = false, .permissions = fresh orelse .default_file });
    defer file.close(io);
    if (@import("builtin").os.tag == .linux and bytes.len > 0) {
        switch (linux.errno(linux.fallocate(file.handle, 0, 0, @intCast(bytes.len)))) {
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            // Not supported everywhere (some network and FUSE file systems);
            // then writing has to show whether there is room.
            else => {},
        }
    }
    try file.writePositionalAll(io, bytes, 0);
    try file.setLength(io, bytes.len);
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

test "hard links keep sharing the content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try writeAtomic(io, tmp.dir, "eins.conf", "alt\n");
    try tmp.dir.hardLink("eins.conf", tmp.dir, "zwei.conf", io, .{});
    try writeAtomic(io, tmp.dir, "eins.conf", "neu\n");

    const raw = try tmp.dir.readFileAlloc(io, "zwei.conf", testing.allocator, .limited(1024));
    defer testing.allocator.free(raw);
    try testing.expectEqualStrings("neu\n", raw);
    const st = try tmp.dir.statFile(io, "eins.conf", .{});
    try testing.expectEqual(@as(@TypeOf(st.nlink), 2), st.nlink);
}

test "overwriting in place leaves no old tail and keeps longer content whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try writeAtomic(io, tmp.dir, "a.conf", "a rather long old line\n");
    try writeInPlace(io, tmp.dir, "a.conf", "short\n", null);
    const shorter = try tmp.dir.readFileAlloc(io, "a.conf", testing.allocator, .limited(1024));
    defer testing.allocator.free(shorter);
    try testing.expectEqualStrings("short\n", shorter);

    try writeInPlace(io, tmp.dir, "a.conf", "now longer than before\n", null);
    const longer = try tmp.dir.readFileAlloc(io, "a.conf", testing.allocator, .limited(1024));
    defer testing.allocator.free(longer);
    try testing.expectEqualStrings("now longer than before\n", longer);

    try writeInPlace(io, tmp.dir, "a.conf", "", null);
    const st = try tmp.dir.statFile(io, "a.conf", .{});
    try testing.expectEqual(@as(u64, 0), st.size);
}

test "temporary name prefix is short and cut between characters" {
    try testing.expectEqualStrings("kitty.conf", tmpPrefix("kitty.conf"));
    // "x" + 40 × "ä" (2 bytes each): byte 64 is the middle of an "ä".
    var buf: [81]u8 = undefined;
    buf[0] = 'x';
    for (0..40) |i| @memcpy(buf[1 + 2 * i ..][0..2], "ä");
    const p = tmpPrefix(&buf);
    try testing.expectEqual(@as(usize, 63), p.len);
    try testing.expect(std.unicode.utf8ValidateSlice(p));
    // Without the "x", byte 64 starts a new "ä": nothing to cut back.
    try testing.expectEqual(@as(usize, 64), tmpPrefix(buf[1..]).len);
}

test "extended attributes survive saving" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try writeAtomic(io, tmp.dir, "a.txt", "alt\n");
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "a.txt", &buf);
    const path = try std.posix.toPosixPath(buf[0..n]);
    const rc = linux.setxattr(&path, "user.iro.test", "wert", 4, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest; // no xattrs here

    try writeAtomic(io, tmp.dir, "a.txt", "neu\n");
    var value: [16]u8 = undefined;
    const len = linux.getxattr(&path, "user.iro.test", &value, value.len);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(len));
    try testing.expectEqualStrings("wert", value[0..len]);
}

test "group survives saving" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    // Needs a second group the user is in (wheel, video, ...).
    var groups: [64]linux.gid_t = undefined;
    const count = linux.getgroups(groups.len, &groups);
    if (linux.errno(count) != .SUCCESS) return error.SkipZigTest;
    const other = for (groups[0..count]) |g| {
        if (g != linux.getegid()) break g;
    } else return error.SkipZigTest;

    try writeAtomic(io, tmp.dir, "geteilt.conf", "alt\n");
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "geteilt.conf", &buf);
    const path = try std.posix.toPosixPath(buf[0..n]);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchownat(linux.AT.FDCWD, &path, linux.geteuid(), other, 0)));

    try writeAtomic(io, tmp.dir, "geteilt.conf", "neu\n");
    const after = ownerOf(linux.AT.FDCWD, &path, 0).?;
    try testing.expectEqual(other, after.gid);
}

test "hung helper program times out and is killed" {
    const io = testing.io;
    try testing.expectError(
        error.Timeout,
        runBounded(
            testing.allocator,
            io,
            &.{ "sh", "-c", "printf hallo; exec sleep 10" },
            .limited(1024),
            .limited(1024),
            40,
        ),
    );
}

test "helper output and exit status come back" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const r = try runBounded(gpa, io, &.{ "sh", "-c", "echo hi; echo oops >&2; exit 3" }, .limited(1024), .limited(1024), 2000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqualStrings("hi\n", r.stdout);
    try std.testing.expectEqualStrings("oops\n", r.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, r.term);
}

fn expectTimeoutWithin(argv: []const []const u8, max_ms: i64) !void {
    const io = std.testing.io;
    const t0 = Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, runBounded(std.testing.allocator, io, argv, .limited(1024), .limited(1024), 300));
    try std.testing.expect(t0.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds() < max_ms);
}

test "a helper that ignores SIGTERM cannot outlast the deadline" {
    try expectTimeoutWithin(&.{ "sh", "-c", "trap '' TERM; sleep 30" }, 2000);
}

test "a helper that closes its output but keeps running cannot outlast the deadline" {
    try expectTimeoutWithin(&.{ "sh", "-c", "exec >&- 2>&-; sleep 30" }, 2000);
}

test "a timed-out helper takes its own children with it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root_buf);
    var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf, "sleep 30 & echo $! > {s}/pid; wait", .{root_buf[0..n]});
    try expectTimeoutWithin(&.{ "sh", "-c", script }, 2000);
    var pid_buf: [32]u8 = undefined;
    const raw = try tmp.dir.readFile(io, "pid", &pid_buf);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, raw, " \n"), 10);
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    // Signal 0 only asks whether the process still exists.
    try std.testing.expect(std.c.kill(pid, @enumFromInt(0)) != 0);
}
