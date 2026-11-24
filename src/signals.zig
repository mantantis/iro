// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! SIGTERM and SIGHUP end iro gracefully: `killall iro`, a closed terminal
//! window, logging out. Without this, the kernel ends iro on the spot, the
//! last two seconds of typing never reach the recovery file and the terminal
//! stays in raw mode.
//!
//! A signal handler may do almost nothing safely, so it only writes one byte
//! into a pipe (the same pattern libvaxis uses for SIGWINCH). A normal task
//! reads it and calls `on_signal`, which can then post an event to the loop.
//! The handler resets itself after the first signal: if shutting down hangs, a
//! second SIGTERM ends iro the hard way.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;

const caught = [_]posix.SIG{ .TERM, .HUP };

pub const Callback = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,
};

var pipe_fds: [2]posix.fd_t = .{ -1, -1 };
var quit: std.atomic.Value(bool) = .init(false);
var task: ?Io.Future(void) = null;

fn handle(_: posix.SIG) callconv(.c) void {
    const byte = [1]u8{1};
    _ = posix.system.write(pipe_fds[1], &byte, byte.len);
}

fn run(io: Io, cb: Callback) void {
    const reader: Io.File = .{ .handle = pipe_fds[0], .flags = .{ .nonblocking = false } };
    var buf: [16]u8 = undefined;
    while (true) {
        const n = reader.readStreaming(io, &.{&buf}) catch return;
        if (n == 0 or quit.load(.acquire)) return;
        cb.func(cb.ctx);
    }
}

fn setFd(fd: posix.fd_t, cmd: i32, arg: u32) !void {
    switch (posix.errno(posix.system.fcntl(fd, cmd, arg))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// Catches SIGTERM and SIGHUP from now on and reports them through `cb`
/// (called from a background task, not from the signal handler).
pub fn start(io: Io, cb: Callback) !void {
    if (task != null) return;
    var fds: [2]posix.fd_t = undefined;
    switch (posix.errno(posix.system.pipe(&fds))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
    errdefer {
        _ = posix.system.close(fds[0]);
        _ = posix.system.close(fds[1]);
    }
    for (fds) |fd| try setFd(fd, posix.F.SETFD, posix.FD_CLOEXEC);
    // Never block inside the signal handler, even if nobody reads.
    try setFd(fds[1], posix.F.SETFL, @bitCast(posix.O{ .NONBLOCK = true }));
    pipe_fds = fds;
    quit.store(false, .release);
    task = try io.concurrent(run, .{ io, cb });

    var act: posix.Sigaction = .{
        .handler = .{ .handler = handle },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESETHAND,
    };
    for (caught) |sig| posix.sigaction(sig, &act, null);
}

/// Puts the default handlers back and ends the background task.
pub fn stop(io: Io) void {
    var t = task orelse return;
    var act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (caught) |sig| posix.sigaction(sig, &act, null);
    quit.store(true, .release);
    const byte = [1]u8{0};
    _ = posix.system.write(pipe_fds[1], &byte, byte.len);
    t.await(io);
    _ = posix.system.close(pipe_fds[0]);
    _ = posix.system.close(pipe_fds[1]);
    pipe_fds = .{ -1, -1 };
    task = null;
}

// ───────────── Tests ─────────────

var test_hits: std.atomic.Value(u32) = .init(0);

fn countHit(_: *anyopaque) void {
    _ = test_hits.fetchAdd(1, .release);
}

test "SIGTERM reaches the callback instead of ending the process" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var dummy: u8 = 0;
    try start(io, .{ .ctx = &dummy, .func = countHit });
    defer stop(io);
    _ = posix.system.kill(posix.system.getpid(), posix.SIG.TERM);
    var waited: u32 = 0;
    while (test_hits.load(.acquire) == 0 and waited < 200) : (waited += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(u32, 1), test_hits.load(.acquire));
}
