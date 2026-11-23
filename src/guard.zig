// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Config Guard: checks known system and dotfile configs before saving so
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

    // `visudo` lets the editor work on `sudoers.tmp`.
    if (std.mem.eql(u8, base, "sudoers") or std.mem.eql(u8, base, "sudoers.tmp")) return .sudoers;
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

/// With `sudoedit`, the editor only sees a copy in /var/tmp whose name hides
/// the original (`fstab.hrXpcOpD`, `pacman2n5oOGbU.conf`, and the folder is
/// lost entirely). If iro runs under `sudoedit` or `sudo -e`, this returns the
/// original path from its command line, written into `out`, so the right
/// checker applies. `null`: not a sudoedit copy.
pub fn sudoeditOriginal(io: Io, path: []const u8, out: []u8) ?[]const u8 {
    if (@import("builtin").os.tag != .linux) return null;
    if (!std.mem.startsWith(u8, path, "/var/tmp/")) return null;
    const copy = std.fs.path.basename(path);
    // The editor may sit below a monitor process; look a few levels up.
    var pid: i32 = std.os.linux.getppid();
    for (0..4) |_| {
        if (pid <= 1) return null;
        var name_buf: [64]u8 = undefined;
        var buf: [8192]u8 = undefined;
        const cmd_path = std.fmt.bufPrint(&name_buf, "/proc/{d}/cmdline", .{pid}) catch return null;
        const cmdline = Io.Dir.cwd().readFile(io, cmd_path, &buf) catch return null;
        if (originalFromCmdline(cmdline, copy)) |orig| {
            // Only the name and folder matter for detection, so a relative
            // argument is enough once it starts with a slash.
            const sep: []const u8 = if (std.mem.startsWith(u8, orig, "/")) "" else "/";
            return std.fmt.bufPrint(out, "{s}{s}", .{ sep, orig }) catch null;
        }
        const stat_path = std.fmt.bufPrint(&name_buf, "/proc/{d}/stat", .{pid}) catch return null;
        const stat = Io.Dir.cwd().readFile(io, stat_path, &buf) catch return null;
        pid = parentFromStat(stat) orelse return null;
    }
    return null;
}

/// The argument of a `sudoedit` / `sudo -e` command line (NUL-separated)
/// whose temporary copy is called `copy`.
fn originalFromCmdline(cmdline: []const u8, copy: []const u8) ?[]const u8 {
    var args = std.mem.tokenizeScalar(u8, cmdline, 0);
    const prog = std.fs.path.basename(args.next() orelse return null);
    var editing = std.mem.eql(u8, prog, "sudoedit");
    if (!editing and !std.mem.eql(u8, prog, "sudo")) return null;
    var found: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--edit")) editing = true;
        if (arg[0] == '-') continue;
        if (found == null and isSudoeditCopy(std.fs.path.basename(arg), copy)) found = arg;
    }
    return if (editing) found else null;
}

/// Does sudoedit name the copy of a file called `orig` like `copy`? It adds
/// eight random characters: before the last dot if there is one
/// (`pacman.conf` → `pacmanXXXXXXXX.conf`), otherwise after a dot
/// (`fstab` → `fstab.XXXXXXXX`).
fn isSudoeditCopy(orig: []const u8, copy: []const u8) bool {
    if (orig.len == 0) return false;
    if (std.mem.lastIndexOfScalar(u8, orig, '.')) |dot| {
        const stem = orig[0..dot];
        const ext = orig[dot..];
        return copy.len == orig.len + 8 and std.mem.startsWith(u8, copy, stem) and std.mem.endsWith(u8, copy, ext);
    }
    return copy.len == orig.len + 9 and std.mem.startsWith(u8, copy, orig) and copy[orig.len] == '.';
}

/// Parent PID from the content of /proc/<pid>/stat ("pid (comm) state ppid …").
fn parentFromStat(stat: []const u8) ?i32 {
    // The program name may contain spaces and parentheses; it ends at the last ')'.
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    _ = fields.next() orelse return null; // state
    return std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch null;
}

/// Does `path` look like a Hyprland config file? Checked after saving via
/// `hyprctl configerrors`. Current Hyprland reads Lua (`hyprland.lua` and the
/// files it requires); older versions read `hyprland.conf`. The other Hypr
/// tools (hyprlock, hypridle, …) keep their own *.conf files in the same
/// folder. Hyprland never reads those, so its error list says nothing about them.
pub fn isHyprConfig(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "/hypr/") == null) return false;
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".lua")) return true;
    if (!std.mem.endsWith(u8, base, ".conf")) return false;
    const other_tools = [_][]const u8{ "hyprlock", "hypridle", "hyprpaper", "hyprsunset", "hyprtoolkit", "xdph" };
    for (other_tools) |tool| {
        if (std.mem.startsWith(u8, base, tool)) return false;
        var seg_buf: [32]u8 = undefined;
        const seg = std.fmt.bufPrint(&seg_buf, "/{s}/", .{tool}) catch unreachable;
        if (std.mem.indexOf(u8, path, seg) != null) return false;
    }
    return true;
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
    var f = cwd.createFile(io, tmp_path, .{ .exclusive = true, .permissions = fileio.private_file }) catch return null;
    // Registered before writing, so a failed write leaves no copy behind.
    defer cwd.deleteFile(io, tmp_path) catch {};
    {
        defer f.close(io);
        f.writeStreamingAll(io, content) catch return null;
    }

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

test "sudoedit copies are traced back to the original" {
    // Names as sudo 1.9 really creates them.
    try testing.expect(isSudoeditCopy("fstab", "fstab.hrXpcOpD"));
    try testing.expect(isSudoeditCopy("sshd_config", "sshd_config.zsJtpBm9"));
    try testing.expect(isSudoeditCopy("pacman.conf", "pacman2n5oOGbU.conf"));
    try testing.expect(isSudoeditCopy(".bashrc", "Ab3dEf7h.bashrc"));
    try testing.expect(!isSudoeditCopy("fstab", "fstab.bak"));
    try testing.expect(!isSudoeditCopy("hosts", "fstab.hrXpcOpD"));

    try testing.expectEqualStrings("/etc/fstab", originalFromCmdline("sudoedit\x00/etc/fstab\x00", "fstab.hrXpcOpD").?);
    try testing.expectEqualStrings(
        "/etc/sudoers.d/10-wheel",
        originalFromCmdline("sudo\x00-u\x00root\x00-e\x00/etc/hosts\x00/etc/sudoers.d/10-wheel\x00", "10-wheel.Qx81LmZp").?,
    );
    // Plain sudo running something else is not an edit.
    try testing.expect(originalFromCmdline("sudo\x00cat\x00/etc/fstab\x00", "fstab.hrXpcOpD") == null);
    try testing.expect(originalFromCmdline("bash\x00/etc/fstab\x00", "fstab.hrXpcOpD") == null);

    try testing.expectEqual(@as(?i32, 4711), parentFromStat("1234 (iro (a) b) S 4711 1234 1234 0"));

    // With the original path, the right checker applies.
    try testing.expectEqual(@as(?Checker, .sudoers), detect("/etc/sudoers.d/10-wheel", ""));
    try testing.expectEqual(@as(?Checker, .sudoers), detect("/etc/sudoers.tmp", ""));
}

test "Hyprland check covers Lua configs and skips the other Hypr tools" {
    try testing.expect(isHyprConfig("/home/u/.config/hypr/hyprland.lua"));
    try testing.expect(isHyprConfig("/home/u/.config/hypr/custom/keybinds.lua"));
    try testing.expect(isHyprConfig("/home/u/.config/hypr/hyprland.conf"));
    try testing.expect(isHyprConfig("/home/u/.config/hypr/monitors.conf"));
    try testing.expect(!isHyprConfig("/home/u/.config/hypr/hyprlock.conf"));
    try testing.expect(!isHyprConfig("/home/u/.config/hypr/hypridle.conf"));
    try testing.expect(!isHyprConfig("/home/u/.config/hypr/hyprpaper.conf"));
    try testing.expect(!isHyprConfig("/home/u/.config/hypr/hyprlock/colors.conf"));
    try testing.expect(!isHyprConfig("/home/u/.config/nvim/init.lua"));
    try testing.expect(!isHyprConfig("/home/u/.config/hypr/README.md"));
}

test "JSON Config Guard catches syntax errors with line numbers" {
    const gpa = testing.allocator;
    try testing.expect((try checkPreSave(gpa, testing.io, "ok.json", "{\"a\": [1, 2]}\n", .en)) == null);

    const bad = (try checkPreSave(gpa, testing.io, "bad.json", "{\n  \"a\": 1,\n  \"b\": }\n", .en)).?;
    defer bad.deinit(gpa);
    try testing.expectEqualStrings("JSON", bad.tool);
    try testing.expect(std.mem.indexOf(u8, bad.detail, "Line 3") != null);
}

test "shell Config Guard catches broken bash/sh syntax" {
    const gpa = testing.allocator;
    try testing.expect((try checkPreSave(gpa, testing.io, "ok.sh", "#!/bin/sh\nif true; then echo hi; fi\n", .de)) == null);

    const bad = (try checkPreSave(gpa, testing.io, "bad.sh", "#!/usr/bin/env bash\nif true; then echo hi\n", .de)).?;
    defer bad.deinit(gpa);
    try testing.expectEqualStrings("bash", bad.tool);
    try testing.expect(std.mem.indexOf(u8, bad.detail, "iro-check-") == null);
}

test "fstab and sshd Config Guard catches real errors and ignores non-root hostkey warnings" {
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
