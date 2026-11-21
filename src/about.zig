// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! About iro (F9): a card with version, author and thanks.
//!
//! The text builds up like wavemon's (also on F9): each character waits a
//! random while, flickers as scrambled glyphs and finally locks in. No
//! left-to-right wipe; every character has its own clock. iro scrambles with
//! half-width katakana in the accent colour, and each locked character glows
//! briefly. Once everything has settled, all is quiet: no more ticks, no power.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Lang = @import("lang.zig").Lang;

/// Ko-fi address. Empty until Mausmann has an account; the card then says
/// "coming soon". With an address, the line becomes a real link in kitty (OSC
/// 8).
pub const kofi_url: []const u8 = "";

pub const Kind = enum { title, subtitle, normal, dim, heart, coffee, legal, blank };
pub const Line = struct { text: []const u8, kind: Kind };

/// What the card shows. The author lines are required by section 7(b) of the
/// license and must not be removed in modified versions.
pub fn lines(arena: Allocator, version: []const u8, l: Lang) Allocator.Error![]const Line {
    const en = l == .en;
    const ver = try std.fmt.allocPrint(arena, "Version {s}", .{version});
    const coffee = if (kofi_url.len > 0)
        try std.fmt.allocPrint(arena, "{s}{s}", .{ if (en) "☕  Buy me a coffee: " else "☕  Kaffee spendieren: ", kofi_url })
    else if (en) "☕  Buy me a coffee: Ko-fi coming soon" else "☕  Kaffee spendieren: Ko-fi folgt bald";
    const out = [_]Line{
        .{ .text = "色  I R O", .kind = .title },
        .{ .text = "Instant · Riced · Operator", .kind = .subtitle },
        .{ .text = "", .kind = .blank },
        .{ .text = ver, .kind = .normal },
        .{ .text = if (en) "Designed by Mausmann" else "Entworfen von Mausmann", .kind = .normal },
        .{ .text = if (en) "Built with AI (Claude Code & Antigravity)" else "Gebaut mit KI (Claude Code & Antigravity)", .kind = .normal },
        .{ .text = "Zig 0.17 · libvaxis · Lua 5.4", .kind = .dim },
        .{ .text = "", .kind = .blank },
        .{ .text = if (en) "♥  Made with love by Mausmann" else "♥  Mit Liebe gemacht von Mausmann", .kind = .heart },
        .{ .text = coffee, .kind = .coffee },
        .{ .text = "", .kind = .blank },
        .{ .text = if (en) "GNU GPL v3 or later · © 2026 Mausmann" else "GNU GPL v3 oder neuer · © 2026 Mausmann", .kind = .legal },
    };
    return arena.dupe(Line, &out);
}

/// Number of characters (codepoints) on the card, i.e. the number of clocks
/// `Reveal` needs.
pub fn charCount(ls: []const Line) usize {
    var n: usize = 0;
    for (ls) |l| n += std.unicode.utf8CountCodepoints(l.text) catch l.text.len;
    return n;
}

/// Scramble glyphs. All are one cell wide so nothing shifts.
const noise_glyphs = [_][]const u8{
    "ｦ", "ｱ", "ｲ", "ｳ", "ｴ", "ｵ", "ｶ", "ｷ", "ｸ", "ｹ", "ｺ", "ｻ", "ｼ", "ｽ", "ｾ", "ｿ",
    "ﾀ", "ﾁ", "ﾂ", "ﾃ", "ﾄ", "ﾅ", "ﾆ", "ﾇ", "ﾈ", "ﾉ", "ﾊ", "ﾋ", "ﾌ", "ﾍ", "ﾎ", "ﾏ",
    "ﾐ", "ﾑ", "ﾒ", "ﾓ", "ﾔ", "ﾕ", "ﾖ", "ﾗ", "ﾘ", "ﾙ", "ﾚ", "ﾛ", "ﾜ", "ﾝ", "0", "1",
    "2", "3", "4", "5", "7", "8", "9", "Z", ":", "=", "*", "+", "<", ">", "¦", "|",
};

pub const Phase = enum { hidden, noise, glow, shown };

pub const Reveal = struct {
    /// One clock per character, counting down by one each frame (wavemon calls
    /// it `linecd`).
    counters: []u8,
    frame: u32 = 0,

    /// Frames of scrambling; at 16 ms per frame a good quarter of a second.
    pub const noise_frames = 16;
    /// Frames of afterglow once a character locks in.
    pub const glow_frames = 5;
    /// Longest wait before scrambling starts. About one second in total.
    pub const max_wait = 40;

    /// `animate = false` (animations off): everything appears at once.
    pub fn init(gpa: Allocator, n: usize, seed: u64, animate: bool) Allocator.Error!Reveal {
        const c = try gpa.alloc(u8, n);
        if (!animate) {
            @memset(c, 0);
            return .{ .counters = c };
        }
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        for (c) |*v| v.* = noise_frames + glow_frames + r.uintAtMost(u8, max_wait);
        return .{ .counters = c };
    }

    pub fn deinit(self: *Reveal, gpa: Allocator) void {
        gpa.free(self.counters);
        self.* = undefined;
    }

    /// Advance one frame.
    pub fn step(self: *Reveal) void {
        self.frame +%= 1;
        for (self.counters) |*v| v.* -|= 1;
    }

    /// Everything settled? Then the card needs no more ticks.
    pub fn done(self: *const Reveal) bool {
        for (self.counters) |v| if (v != 0) return false;
        return true;
    }

    /// Impatient users press a key: show everything at once.
    pub fn finish(self: *Reveal) void {
        @memset(self.counters, 0);
    }

    pub fn phase(self: *const Reveal, i: usize) Phase {
        if (i >= self.counters.len) return .shown;
        const v = self.counters[i];
        if (v > noise_frames + glow_frames) return .hidden;
        if (v > glow_frames) return .noise;
        if (v > 0) return .glow;
        return .shown;
    }

    /// The scramble glyph at position `i` (and neighbour cell `sub` for wide
    /// characters). Changes every second frame; any faster is just flicker.
    pub fn noise(self: *const Reveal, i: usize, sub: usize) []const u8 {
        var x: u32 = @truncate((i *% 2 +% sub) *% 0x9E3779B1);
        x ^= (self.frame / 2) *% 0x85EBCA6B;
        x ^= x >> 15;
        x *%= 0x2C1B3C6D;
        x ^= x >> 12;
        return noise_glyphs[x % noise_glyphs.len];
    }
};

test "card names Mausmann and the version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for ([_]Lang{ .de, .en }) |lg| {
        const ls = try lines(arena_state.allocator(), "9.9.9", lg);
        var found_author = false;
        var found_version = false;
        for (ls) |l| {
            if (std.mem.indexOf(u8, l.text, "Mausmann") != null) found_author = true;
            if (std.mem.indexOf(u8, l.text, "9.9.9") != null) found_version = true;
        }
        try std.testing.expect(found_author and found_version);
        try std.testing.expect(charCount(ls) > 100);
    }
}

test "decryption: wait, scramble, glow, done" {
    const gpa = std.testing.allocator;
    var r = try Reveal.init(gpa, 50, 42, true);
    defer r.deinit(gpa);
    try std.testing.expect(!r.done());
    for (0..50) |i| try std.testing.expect(r.phase(i) != .shown);

    // Each character goes through the phases exactly once, never backwards.
    var last: [50]Phase = @splat(.hidden);
    var frames: usize = 0;
    while (!r.done()) : (frames += 1) {
        r.step();
        for (0..50) |i| {
            const p = r.phase(i);
            try std.testing.expect(@intFromEnum(p) >= @intFromEnum(last[i]));
            last[i] = p;
        }
    }
    try std.testing.expect(frames <= Reveal.noise_frames + Reveal.glow_frames + Reveal.max_wait);
    for (last) |p| try std.testing.expectEqual(Phase.shown, p);
}

test "without animation everything appears at once, finish jumps to the end" {
    const gpa = std.testing.allocator;
    var still = try Reveal.init(gpa, 10, 1, false);
    defer still.deinit(gpa);
    try std.testing.expect(still.done());

    var r = try Reveal.init(gpa, 10, 1, true);
    defer r.deinit(gpa);
    r.finish();
    try std.testing.expect(r.done());
    try std.testing.expectEqual(Phase.shown, r.phase(3));
}

test "scramble glyphs are one cell wide" {
    for (noise_glyphs) |g| {
        const cp = try std.unicode.utf8Decode(g);
        // ASCII, ¦ or half-width katakana (U+FF66–FF9D)
        try std.testing.expect(cp < 0x7F or cp == 0xA6 or (cp >= 0xFF66 and cp <= 0xFF9D));
    }
}
