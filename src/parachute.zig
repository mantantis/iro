// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Config parachute: checks known system and dotfile configs before saving so
//! a typo in fstab, sudoers, sshd_config, systemd units, shell scripts or JSON
//! is caught before it hits disk. For Hyprland configs, queries `hyprctl
//! configerrors` right after saving.
//!
//! If the matching checker program is not installed (or times out), iro stays
//! quiet and saves normally.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fileio = @import("fileio.zig");
const Lang = @import("lang.zig").Lang;

pub const Checker = enum {
    fstab,
    sudoers,
    sshd,
    systemd,
    bash,
    sh,
    json,

    pub fn toolName(self: Checker) []const u8 {
        return switch (self) {
            .fstab => "findmnt",
            .sudoers => "visudo",
            .sshd => "sshd",
            .systemd => "systemd-analyze",
            .bash => "bash",
            .sh => "sh",
            .json => "JSON",
        };
    }
};

pub const Problem = struct {
    tool: []const u8,
    detail: []u8,

    pub fn deinit(self: Problem, gpa: Allocator) void {
        gpa.free(self.detail);
    }
};

/// Which pre-save checker (if any) applies to `path` and its contents.
pub fn detect(path: []const u8, content: []const u8) ?Checker {
    const base = std.fs.path.basename(path);
    if (base.len == 0) return null;

    if (std.mem.eql(u8, base, "fstab") or std.mem.endsWith(u8, base, ".fstab")) return .fstab;

    if (std.mem.eql(u8, base, "sudoers")) return .sudoers;
    if (std.mem.indexOf(u8, path, "/sudoers.d/") != null) {
        if (!std.mem.startsWith(u8, base, ".") and !std.mem.endsWith(u8, base, "~") and
            !std.ascii.eqlIgnoreCase(base, "README"))
        {
            return .sudoers;
        }
    }

    if (std.mem.eql(u8, base, "sshd_config")) return .sshd;
    if (std.mem.indexOf(u8, path, "/sshd_config.d/") != null and std.mem.endsWith(u8, base, ".conf")) {
        return .sshd;
    }

    const unit_exts = [_][]const u8{
        ".service", ".socket", ".timer", ".mount", ".automount", ".path", ".target", ".slice",
    };
    for (unit_exts) |ext| {
        if (std.mem.endsWith(u8, base, ext) and base.len > ext.len) return .systemd;
    }

    if (std.mem.endsWith(u8, base, ".json")) return .json;

    // For scripts, an explicit shebang overrides the extension so we never run
    // `sh -n` on a zsh, fish or Python file.
    if (shebangShell(content)) |sh_kind| return sh_kind;
    if (std.mem.startsWith(u8, content, "#!")) return null;
    if (std.mem.endsWith(u8, base, ".bash")) return .bash;
    if (std.mem.endsWith(u8, base, ".sh")) return .sh;
    return null;
}

/// Does `path` look like a Hyprland config file? Checked after saving via
/// `hyprctl configerrors`.
pub fn isHyprConfig(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".conf") and std.mem.indexOf(u8, path, "/hypr/") != null;
}

fn shebangShell(content: []const u8) ?Checker {
    if (!std.mem.startsWith(u8, content, "#!")) return null;
    const line = std.mem.trim(u8, std.mem.sliceTo(content[2..], '\n'), " \t\r");
    var tok = std.mem.tokenizeAny(u8, line, " \t");
    const first = tok.next() orelse return null;
    const prog = std.fs.path.basename(first);
    const target = if (std.mem.eql(u8, prog, "env")) blk: {
        // Skip optional flags like `env -S`.
        while (tok.next()) |arg| {
            if (arg.len > 0 and arg[0] != '-') break :blk std.fs.path.basename(arg);
        }
        return null;
    } else prog;
    if (std.mem.eql(u8, target, "bash")) return .bash;
    if (std.mem.eql(u8, target, "sh") or std.mem.eql(u8, target, "dash")) return .sh;
    return null;
}

/// Validates `content` before it is written to `path`. Returns `null` when the
/// file is valid, no checker applies, or the external checker is unavailable.
pub fn checkPreSave(gpa: Allocator, io: Io, path: []const u8, content: []const u8, l: Lang) Allocator.Error!?Problem {
    const kind = detect(path, content) orelse return null;
    if (kind == .json) return checkJson(gpa, content, l);
    return checkExternal(gpa, io, kind, path, content, l);
}

/// Queries Hyprland for active configuration errors right after saving a
/// Hyprland config file. Returns `null` if Hyprland reports no errors or
/// `hyprctl` is unavailable.
pub fn checkHyprland(gpa: Allocator, io: Io) Allocator.Error!?[]u8 {
    const result = fileio.runHelper(
        gpa,
        io,
        &.{ "hyprctl", "configerrors" },
        .limited(64 * 1024),
        .limited(16 * 1024),
    ) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return null;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.ascii.eqlIgnoreCase(line, "ok")) continue;
        return try cleanSummary(gpa, line, "");
    }
    return null;
}

fn checkJson(gpa: Allocator, content: []const u8, l: Lang) Allocator.Error!?Problem {
    var body = content;
    if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) body = body[3..];
    var scanner = std.json.Scanner.initCompleteInput(gpa, body);
    defer scanner.deinit();
    while (true) {
        const tok = scanner.next() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const pos = @min(scanner.cursor, body.len);
            const line = 1 + std.mem.count(u8, body[0..pos], "\n");
            const msg = if (l == .en)
                try std.fmt.allocPrint(gpa, "Line {d}: syntax error ({s})", .{ line, @errorName(err) })
            else
                try std.fmt.allocPrint(gpa, "Zeile {d}: Syntaxfehler ({s})", .{ line, @errorName(err) });
            return .{ .tool = Checker.json.toolName(), .detail = msg };
        };
        if (tok == .end_of_document) return null;
    }
}

fn checkExternal(gpa: Allocator, io: Io, kind: Checker, path: []const u8, content: []const u8, l: Lang) Allocator.Error!?Problem {
    const cwd = Io.Dir.cwd();
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    var dir_buf: [128]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "/tmp/iro-check-{x}", .{std.mem.readInt(u64, &rnd, .little)}) catch return null;
    cwd.createDir(io, dir_path, fileio.private_dir) catch return null;
    defer cwd.deleteDir(io, dir_path) catch {};

    const raw_base = std.fs.path.basename(path);
    const safe_base = if (isSafeFileName(raw_base)) raw_base else "check.tmp";
    var file_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&file_buf, "{s}/{s}", .{ dir_path, safe_base }) catch return null;
    {
        var f = cwd.createFile(io, tmp_path, .{ .exclusive = true, .permissions = fileio.private_file }) catch return null;
        defer f.close(io);
        f.writeStreamingAll(io, content) catch return null;
    }
    defer cwd.deleteFile(io, tmp_path) catch {};

    const argv: []const []const u8 = switch (kind) {
        .fstab => &.{ "findmnt", "--verify", "--tab-file", tmp_path },
        .sudoers => &.{ "visudo", "-cf", tmp_path },
        .sshd => &.{ "sshd", "-t", "-f", tmp_path },
        .systemd => &.{ "systemd-analyze", "verify", "--recursive-errors=no", tmp_path },
        .bash => &.{ "bash", "-n", tmp_path },
        .sh => &.{ "sh", "-n", tmp_path },
        .json => unreachable,
    };

    const result = fileio.runHelper(gpa, io, argv, .limited(64 * 1024), .limited(64 * 1024)) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return null;

    // Running `sshd -t` as a non-root user (e.g. under sudoedit) cannot read
    // `/etc/ssh/ssh_host_*_key`. Syntax errors are reported before host keys,
    // so if only host-key errors appear, the config itself is fine.
    if (kind == .sshd and onlySshdHostKeyError(result.stderr, result.stdout)) return null;

    const picked = pickErrorLine(kind, result.stderr, result.stdout);
    const detail = if (picked.len > 0)
        try cleanSummary(gpa, picked, dir_path)
    else
        try gpa.dupe(u8, if (l == .en) "check failed" else "Prüfung fehlgeschlagen");
    return .{ .tool = kind.toolName(), .detail = detail };
}

fn isSafeFileName(name: []const u8) bool {
    if (name.len == 0 or name.len > 120) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (c < 0x20 or c == '/' or c == 0x7f) return false;
    }
    return true;
}

fn onlySshdHostKeyError(stderr: []const u8, stdout: []const u8) bool {
    var saw_hostkey = false;
    for ([_][]const u8{ stderr, stdout }) |buf| {
        var it = std.mem.tokenizeScalar(u8, buf, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (std.mem.indexOf(u8, line, "no hostkeys available") != null or
                std.mem.indexOf(u8, line, "Could not load host key") != null or
                std.mem.indexOf(u8, line, "Unable to load host key") != null or
                std.mem.indexOf(u8, line, "Permission denied") != null)
            {
                saw_hostkey = true;
            } else {
                return false;
            }
        }
    }
    return saw_hostkey;
}

fn pickErrorLine(kind: Checker, stderr: []const u8, stdout: []const u8) []const u8 {
    if (kind == .fstab) {
        // `findmnt --verify` prints errors to stdout marked with `[E]`.
        for ([_][]const u8{ stdout, stderr }) |buf| {
            var it = std.mem.tokenizeScalar(u8, buf, '\n');
            while (it.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (std.mem.startsWith(u8, line, "[E]")) return line;
            }
        }
    }
    if (kind == .sudoers) {
        // `visudo` may warn about `/etc/sudo.conf` before the real syntax line.
        for ([_][]const u8{ stderr, stdout }) |buf| {
            var it = std.mem.tokenizeScalar(u8, buf, '\n');
            while (it.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0) continue;
                if (std.mem.indexOf(u8, line, "/etc/sudo.conf") != null) continue;
                return line;
            }
        }
    }
    for ([_][]const u8{ stderr, stdout }) |buf| {
        var it = std.mem.tokenizeScalar(u8, buf, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0) return line;
        }
    }
    return "";
}

/// Strips the temporary directory prefix and keeps the summary compact and safe
/// for the status line.
fn cleanSummary(gpa: Allocator, raw: []const u8, tmp_dir: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var prefix_buf: [140]u8 = undefined;
    const prefix = if (tmp_dir.len > 0)
        std.fmt.bufPrint(&prefix_buf, "{s}/", .{tmp_dir}) catch ""
    else
        "";
    var i: usize = 0;
    while (i < raw.len and out.items.len < 120) {
        if (prefix.len > 0 and std.mem.startsWith(u8, raw[i..], prefix)) {
            i += prefix.len;
            continue;
        }
        const c = raw[i];
        i += 1;
        if (c == '\r' or c == '\n' or c == '\t') {
            try out.append(gpa, ' ');
        } else if (c >= 0x20 and c != 0x7f) {
            try out.append(gpa, c);
        }
    }
    while (out.items.len > 0 and !std.unicode.utf8ValidateSlice(out.items)) {
        out.items.len -= 1;
    }
    return out.toOwnedSlice(gpa);
}

// ───────────── Tests ─────────────

const testing = std.testing;

test "detect matches known configs and respects shebangs" {
    try testing.expectEqual(@as(?Checker, .fstab), detect("/etc/fstab", ""));
    try testing.expectEqual(@as(?Checker, .sudoers), detect("/etc/sudoers", ""));
    try testing.expectEqual(@as(?Checker, .sudoers), detect("/etc/sudoers.d/wheel", ""));
    try testing.expectEqual(@as(?Checker, null), detect("/etc/sudoers.d/README", ""));
    try testing.expectEqual(@as(?Checker, .sshd), detect("/etc/ssh/sshd_config", ""));
    try testing.expectEqual(@as(?Checker, .sshd), detect("/etc/ssh/sshd_config.d/10-local.conf", ""));
    try testing.expectEqual(@as(?Checker, .systemd), detect("/etc/systemd/system/backup.service", ""));
    try testing.expectEqual(@as(?Checker, .systemd), detect("/home/u/.config/systemd/user/sync.timer", ""));
    try testing.expectEqual(@as(?Checker, .json), detect("/home/u/settings.json", ""));
    try testing.expectEqual(@as(?Checker, null), detect("/home/u/settings.jsonc", ""));
    try testing.expectEqual(@as(?Checker, .sh), detect("/home/u/run.sh", "echo hi\n"));
    try testing.expectEqual(@as(?Checker, .bash), detect("/home/u/run.sh", "#!/usr/bin/env bash\necho hi\n"));
    try testing.expectEqual(@as(?Checker, null), detect("/home/u/run.sh", "#!/usr/bin/env zsh\necho hi\n"));
    try testing.expectEqual(@as(?Checker, null), detect("/home/u/notes.txt", "hello\n"));
    try testing.expect(isHyprConfig("/home/u/.config/hypr/hyprland.conf"));
    try testing.expect(!isHyprConfig("/home/u/.config/kitty/kitty.conf"));
}

test "JSON parachute catches syntax errors with line numbers" {
    const gpa = testing.allocator;
    try testing.expect((try checkPreSave(gpa, testing.io, "ok.json", "{\"a\": [1, 2]}\n", .en)) == null);

    const bad = (try checkPreSave(gpa, testing.io, "bad.json", "{\n  \"a\": 1,\n  \"b\": }\n", .en)).?;
    defer bad.deinit(gpa);
    try testing.expectEqualStrings("JSON", bad.tool);
    try testing.expect(std.mem.indexOf(u8, bad.detail, "Line 3") != null);
}

test "shell parachute catches broken bash/sh syntax" {
    const gpa = testing.allocator;
    try testing.expect((try checkPreSave(gpa, testing.io, "ok.sh", "#!/bin/sh\nif true; then echo hi; fi\n", .de)) == null);

    const bad = (try checkPreSave(gpa, testing.io, "bad.sh", "#!/usr/bin/env bash\nif true; then echo hi\n", .de)).?;
    defer bad.deinit(gpa);
    try testing.expectEqualStrings("bash", bad.tool);
    try testing.expect(std.mem.indexOf(u8, bad.detail, "iro-check-") == null);
}

test "fstab and sshd parachutes catch real errors and ignore non-root hostkey warnings" {
    const gpa = testing.allocator;
    const io = testing.io;

    // fstab: valid tmpfs passes, garbage fails.
    try testing.expect((try checkPreSave(gpa, io, "/etc/fstab", "tmpfs /tmp tmpfs defaults 0 0\n", .en)) == null);
    if (try checkPreSave(gpa, io, "/etc/fstab", "broken line here\n", .en)) |p| {
        defer p.deinit(gpa);
        try testing.expectEqualStrings("findmnt", p.tool);
    }

    // sshd: valid config must not fail just because host keys are root-only;
    // a bogus directive must be caught.
    try testing.expect((try checkPreSave(gpa, io, "/etc/ssh/sshd_config", "Port 22\n", .en)) == null);
    if (try checkPreSave(gpa, io, "/etc/ssh/sshd_config", "Port 22\nBogusOption yes\n", .en)) |p| {
        defer p.deinit(gpa);
        try testing.expectEqualStrings("sshd", p.tool);
        try testing.expect(std.mem.indexOf(u8, p.detail, "BogusOption") != null);
    }
}
