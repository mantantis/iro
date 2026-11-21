// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! The file index for file search (Ctrl+O).
//!
//! Several workers read a directory tree in parallel; each takes the next
//! folder from a shared queue. The UI never waits: it collects what has been
//! found so far with `poll`, and the result list fills up while you type. A
//! finished index stays in memory so the next Ctrl+O shows results immediately;
//! refreshing then happens in the background.
//!
//! What goes in: all regular files, including hidden ones (they just rank
//! lower). What stays out: junk folders such as .git or node_modules (see
//! finder.zig), mounted drives, symlinks to folders.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const finder = @import("finder.zig");

pub const Entry = struct {
    /// Path relative to the root.
    path: []const u8,
    /// How far down the entry ranks without a query. Lower is better: depth in
    /// the tree plus a hefty penalty for hidden paths.
    rank: u32,
};

pub const Options = struct {
    /// The index takes no more files than this (protection against memory
    /// hunger).
    max_files: usize = 1_000_000,
    /// Workers. 0: as many as cores, at most 8.
    workers: usize = 0,
    skip_mounts: bool = true,
};

/// Called from a worker when there is something new. Must therefore be
/// thread-safe (e.g. `Loop.postEvent`).
pub const Notify = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,
};

/// Rank for a path: depth times 4, hidden components (".config") +400.
pub fn rankOf(path: []const u8) u32 {
    var rank: u32 = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (rank % 400 < 396) rank += 4;
        if (part.len > 1 and part[0] == '.') rank += 400;
    }
    return rank;
}

/// State shared by the workers. Everything behind `mutex` except `cancel`.
const Shared = struct {
    io: Io,
    root: []const u8,
    mounts: []const []const u8,
    max_files: usize,
    notify: ?Notify,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Folders still waiting to be read (relative to the root).
    queue: std.ArrayList([]const u8) = .empty,
    /// Folders in the queue plus those currently being read.
    pending: usize = 1,
    /// Found, but not yet collected by the UI.
    inbox: std.ArrayList(Entry) = .empty,
    total: usize = 0,
    truncated: bool = false,
    running: usize = 0,
    last_notify: usize = 0,
    cancel: std.atomic.Value(bool) = .init(false),
    /// Each worker stores its paths in its own arena.
    arenas: []std.heap.ArenaAllocator,
    /// For the queue, the mailbox and the folder list.
    misc: std.heap.ArenaAllocator,
};

const alloc = std.heap.smp_allocator;

pub const Index = struct {
    gpa: Allocator,
    io: Io,
    root: []u8,
    /// What the UI has already collected. Owned by the UI alone.
    entries: std.ArrayList(Entry) = .empty,
    shared: *Shared,
    group: Io.Group = .init,
    finished: bool = false,
    truncated: bool = false,
    started: Io.Timestamp,
    took_ms: i64 = 0,

    /// Starts the work and returns immediately; the work runs in the
    /// background. Without concurrency, `start` reads everything itself.
    pub fn start(gpa: Allocator, io: Io, root: []const u8, opts: Options, notify: ?Notify) !*Index {
        const n_workers = if (opts.workers > 0) opts.workers else std.math.clamp(std.Thread.getCpuCount() catch 2, 2, 8);
        const sh = try alloc.create(Shared);
        errdefer alloc.destroy(sh);
        const arenas = try alloc.alloc(std.heap.ArenaAllocator, n_workers);
        for (arenas) |*a| a.* = .init(alloc);
        sh.* = .{
            .io = io,
            .root = undefined,
            .mounts = &.{},
            .max_files = opts.max_files,
            .notify = notify,
            .arenas = arenas,
            .misc = .init(alloc),
        };
        const misc = sh.misc.allocator();
        sh.root = try misc.dupe(u8, root);
        if (opts.skip_mounts) sh.mounts = finder.mountPoints(misc, io);
        try sh.queue.append(misc, "");

        const self = try gpa.create(Index);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .root = try gpa.dupe(u8, root),
            .shared = sh,
            .started = Io.Timestamp.now(io, .awake),
        };
        var spawned: usize = 0;
        for (0..n_workers) |w| {
            sh.mutex.lockUncancelable(io);
            sh.running += 1;
            sh.mutex.unlock(io);
            self.group.concurrent(io, worker, .{ sh, w }) catch {
                sh.mutex.lockUncancelable(io);
                sh.running -= 1;
                sh.mutex.unlock(io);
                break;
            };
            spawned += 1;
        }
        if (spawned == 0) {
            // No second thread available: do it here and now.
            sh.running = 1;
            worker(sh, 0) catch {};
        }
        return self;
    }

    pub fn deinit(self: *Index) void {
        const sh = self.shared;
        sh.cancel.store(true, .release);
        sh.mutex.lockUncancelable(self.io);
        sh.cond.broadcast(self.io);
        sh.mutex.unlock(self.io);
        self.group.await(self.io) catch {};
        for (sh.arenas) |*a| a.deinit();
        alloc.free(sh.arenas);
        sh.misc.deinit();
        alloc.destroy(sh);
        self.entries.deinit(self.gpa);
        self.gpa.free(self.root);
        self.gpa.destroy(self);
    }

    /// Collects what the workers have found so far. `true` if something was
    /// added or the index has just finished.
    pub fn poll(self: *Index) bool {
        if (self.finished) return false;
        const sh = self.shared;
        sh.mutex.lockUncancelable(self.io);
        defer sh.mutex.unlock(self.io);
        const got = sh.inbox.items.len;
        self.entries.appendSlice(self.gpa, sh.inbox.items) catch return false;
        sh.inbox.clearRetainingCapacity();
        const now_done = sh.running == 0;
        if (now_done) {
            self.finished = true;
            self.truncated = sh.truncated;
            self.took_ms = self.started.durationTo(Io.Timestamp.now(self.io, .awake)).toMilliseconds();
        }
        return got > 0 or now_done;
    }

    /// Blocks until everything is read (for tests and the search probe).
    pub fn wait(self: *Index) void {
        self.group.await(self.io) catch {};
        _ = self.poll();
    }
};

fn worker(sh: *Shared, w: usize) Io.Cancelable!void {
    const io = sh.io;
    const arena = sh.arenas[w].allocator();
    var files: std.ArrayList(Entry) = .empty;
    defer files.deinit(alloc);
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(alloc);

    defer {
        sh.mutex.lockUncancelable(io);
        sh.running -= 1;
        const last = sh.running == 0;
        sh.cond.broadcast(io);
        sh.mutex.unlock(io);
        if (last) if (sh.notify) |n| n.func(n.ctx);
    }

    while (true) {
        sh.mutex.lockUncancelable(io);
        while (sh.queue.items.len == 0 and sh.pending > 0 and !sh.cancel.load(.acquire)) {
            sh.cond.waitUncancelable(io, &sh.mutex);
        }
        if (sh.queue.items.len == 0 or sh.cancel.load(.acquire)) {
            sh.mutex.unlock(io);
            return;
        }
        const rel = sh.queue.pop().?;
        sh.mutex.unlock(io);

        files.clearRetainingCapacity();
        dirs.clearRetainingCapacity();
        readDir(sh, arena, rel, &files, &dirs);

        sh.mutex.lockUncancelable(io);
        const room = sh.max_files -| sh.total;
        if (files.items.len > room) sh.truncated = true;
        const take = @min(files.items.len, room);
        sh.inbox.appendSlice(sh.misc.allocator(), files.items[0..take]) catch {};
        sh.total += take;
        if (sh.total < sh.max_files) {
            sh.queue.appendSlice(sh.misc.allocator(), dirs.items) catch {};
            sh.pending += dirs.items.len;
        } else if (dirs.items.len > 0) sh.truncated = true;
        sh.pending -= 1;
        if (sh.pending == 0 or dirs.items.len > 0) sh.cond.broadcast(io);
        // Don't flood the UI with events: roughly every 4000 files.
        const ping = sh.total >= sh.last_notify + 4000;
        if (ping) sh.last_notify = sh.total;
        sh.mutex.unlock(io);
        if (ping) if (sh.notify) |n| n.func(n.ctx);
    }
}

/// Reads a folder: files into `files`, subfolders into `dirs`.
fn readDir(sh: *Shared, arena: Allocator, rel: []const u8, files: *std.ArrayList(Entry), dirs: *std.ArrayList([]const u8)) void {
    const io = sh.io;
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const full = if (rel.len == 0) sh.root else std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sh.root, rel }) catch return;
    // Folders without read permission or just deleted are skipped.
    var dir = Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (sh.cancel.load(.monotonic)) return;
        if (!std.unicode.utf8ValidateSlice(e.name)) continue;
        const kind = switch (e.kind) {
            // Some file systems don't report the type right away; ask explicitly.
            .unknown => if (dir.statFile(io, e.name, .{ .follow_symlinks = false })) |st| st.kind else |_| continue,
            // Symlink to a file: yes. To a folder: no (cycles!).
            .sym_link => if (dir.statFile(io, e.name, .{})) |st|
                (if (st.kind == .directory) continue else st.kind)
            else |_|
                continue,
            else => e.kind,
        };
        if (kind == .directory and finder.isJunk(e.name)) continue;
        if (kind != .directory and kind != .file) continue;
        const path = (if (rel.len == 0) arena.dupe(u8, e.name) else std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, e.name })) catch return;
        if (kind == .directory) {
            const sub = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sh.root, path }) catch continue;
            const is_mount = for (sh.mounts) |m| {
                if (std.mem.eql(u8, m, sub)) break true;
            } else false;
            if (!is_mount) dirs.append(alloc, path) catch return;
        } else files.append(alloc, .{ .path = path, .rank = rankOf(path) }) catch return;
    }
}

/// The git root above `dir` (the folder containing `.git`), or `null`.
pub fn gitRoot(io: Io, dir: []const u8) ?[]const u8 {
    var cur = dir;
    while (true) {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const probe = std.fmt.bufPrint(&buf, "{s}/.git", .{std.mem.trimEnd(u8, cur, "/")}) catch return null;
        if (Io.Dir.cwd().access(io, probe, .{})) |_| return cur else |_| {}
        cur = std.fs.path.dirname(cur) orelse return null;
    }
}

// ───────────── Tests ─────────────

test "rank: shallow before deep, visible before hidden" {
    try std.testing.expect(rankOf("a.txt") < rankOf("x/a.txt"));
    try std.testing.expect(rankOf("x/y/z/a.txt") < rankOf(".config/a.txt"));
    try std.testing.expect(rankOf(".gitignore") > rankOf("tief/tiefer/am/tiefsten/datei"));
}

test "index reads everything in parallel, skips junk and cycles" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b/c");
    try tmp.dir.createDirPath(io, "node_modules/kram");
    try tmp.dir.createDirPath(io, ".config/hypr");
    var name_buf: [64]u8 = undefined;
    for (0..300) |i| {
        const n = try std.fmt.bufPrint(&name_buf, "a/b/c/datei{d}.txt", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = n, .data = "" });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "oben.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".config/hypr/hyprland.lua", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/kram/index.js", .data = "" });
    tmp.dir.symLink(io, "..", "a/schleife", .{ .is_directory = true }) catch {};

    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root_buf);
    const idx = try Index.start(gpa, io, root_buf[0..n], .{ .workers = 4 }, null);
    defer idx.deinit();
    idx.wait();
    try std.testing.expect(idx.finished);
    try std.testing.expectEqual(@as(usize, 302), idx.entries.items.len);
    var saw_hypr = false;
    for (idx.entries.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.path, "node_modules") == null);
        if (std.mem.eql(u8, e.path, ".config/hypr/hyprland.lua")) saw_hypr = true;
    }
    try std.testing.expect(saw_hypr);
}

test "limit applies and is reported" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buf: [64]u8 = undefined;
    for (0..50) |i| {
        const n = try std.fmt.bufPrint(&name_buf, "d{d}.txt", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = n, .data = "" });
    }
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root_buf);
    const idx = try Index.start(gpa, io, root_buf[0..n], .{ .max_files = 20 }, null);
    defer idx.deinit();
    idx.wait();
    try std.testing.expectEqual(@as(usize, 20), idx.entries.items.len);
    try std.testing.expect(idx.truncated);
}

test "git root is found upwards" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/.git");
    try tmp.dir.createDirPath(io, "proj/src/tief");
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root_buf);
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const deep = try std.fmt.bufPrint(&buf, "{s}/proj/src/tief", .{root_buf[0..n]});
    const got = gitRoot(io, deep).?;
    try std.testing.expect(std.mem.endsWith(u8, got, "/proj"));
}
