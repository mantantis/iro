// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! iro in the terminal: drawing the screen, receiving keys and mouse input.
//!
//! The actual work on the text is done by the core (`src/editor.zig`). This
//! file only translates: key in, command to the core, picture out.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const iro = @import("iro");

const Editor = iro.Editor;
const Pos = iro.Pos;
const text = iro.text;
const fileio = iro.fileio;
const syntax = iro.syntax;
const Tree = iro.tree.Tree;
const config = iro.config;
const Lang = iro.lang.Lang;
const Cmd = config.Cmd;
const Key = vaxis.Key;
const draw_mod = @import("draw.zig");

pub const version = "0.2.0";
pub const logo_png = @embedFile("logo.png");

/// If iro crashes, the terminal is reset first. Otherwise an unusable window
/// would be left behind.
pub const panic = vaxis.Panic;

const Event = union(enum) {
    key_press: Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    /// The terminal's answer to a query for one of its colours.
    color_report: vaxis.Color.Report,
    paste_start,
    paste_end,
    /// Fires two seconds after a change the recovery file doesn't know yet.
    tick,
    /// Fires every ten seconds: has the wallpaper (and with it the terminal
    /// palette) changed?
    color_tick,
    /// The terminal window has the focus again: did another program change a
    /// file in the meantime?
    focus_in,
    /// The file index has found something new (comes from a worker thread).
    index_progress,
};

const Loop = vaxis.Loop(Event);

pub const PromptKind = enum { search, save_as, open, goto_line, tree_new_file, tree_new_dir, tree_rename, confirm_quit, confirm_close, confirm_overwrite, confirm_guard, confirm_trash, recover, confirm_replace_file, replace_find, replace_with, confirm_each };

pub const Prompt = struct {
    kind: PromptKind,
    input: std.ArrayList(u8) = .empty,
};

pub fn toVaxisColor(c: config.ColorSpec) vaxis.Color {
    return switch (c) {
        .default => .default,
        .index => |i| .{ .index = i },
        .rgb => |rgb| .{ .rgb = rgb },
    };
}

/// One row in the search box: a command, an open tab, a file or a folder.
pub const PaletteItem = struct {
    name: []const u8,
    key: []const u8 = "",
    score: i32 = 0,
    /// Position in the unfiltered list; breaks ties between equal scores.
    order: u32 = 0,
    action: union(enum) {
        cmd: Cmd,
        tab: usize,
        /// Path relative to the search folder.
        file: []const u8,
        /// Full path of a folder.
        dir: []const u8,
        /// An earlier version of the current file.
        version: iro.history.Version,
    },
};

/// The search box can show four things: commands (Ctrl+P), files below the
/// tree's folder (Ctrl+O), folders from zoxide (Alt+Z) or earlier versions of
/// the current file (Alt+R).
pub const PaletteMode = enum { commands, files, dirs, versions };

pub const Palette = struct {
    mode: PaletteMode,
    input: std.ArrayList(u8) = .empty,
    selected: usize = 0,
    top: usize = 0,
    /// Everything the box offers lives here until it closes.
    arena: std.heap.ArenaAllocator,
    all: []PaletteItem = &.{},
    /// What matches the current query, best first.
    shown: std.ArrayList(PaletteItem) = .empty,
    /// Has the query changed since `shown` was computed?
    stale: bool = true,
    /// Folder the file search runs under.
    base: []const u8 = "",
    /// Are entries missing because a limit kicked in?
    truncated: bool = false,

    // ── file search only ──
    /// The index being searched (owned by the app, not the box).
    idx: ?*iro.index.Index = null,
    /// Which search scopes exist (project/folder, home) and which one applies.
    scopes: [2]Scope = undefined,
    n_scopes: usize = 0,
    scope: usize = 0,
    /// All matches for query `hits_query`, computed over `hits_n` entries.
    hits: std.ArrayList(iro.search.Hit) = .empty,
    hits_query: std.ArrayList(u8) = .empty,
    hits_n: usize = std.math.maxInt(usize),
    hits_idx: ?*iro.index.Index = null,
    /// Are only approximate matches on top (typo forgiven)?
    typo: bool = false,
    /// Recently opened (relative to the search scope) and folder of the current
    /// file.
    recent_rel: []const []const u8 = &.{},
    near: []const u8 = "",
    /// Folder of the current file (or of the tree), full path.
    here: []const u8 = "",
    last_rank: ?Io.Timestamp = null,
};

/// One search scope of the file search.
pub const Scope = struct {
    root: []const u8,
    kind: enum { project, folder, home },
};

/// An open file with everything that belongs to it. Every tab is a `Doc`.
pub const Doc = struct {
    ed: Editor,
    meta: fileio.Meta = .{},
    /// Full path of the file. `null`: not named yet.
    path: ?[]u8 = null,
    /// Fixed name for a tab without a file (the help page).
    title: ?[]const u8 = null,
    /// Read-only: nothing in it can be changed (the help page).
    read_only: bool = false,

    top_line: usize = 0,
    left_col: usize = 0,
    /// Should the view follow the cursor? Not while scrolling with the mouse
    /// wheel.
    follow: bool = true,

    /// Language for syntax colours. `null`: no colours.
    lang: ?*const syntax.Lang = null,
    /// State at the start of each line (inside a block comment? inside a long
    /// string?).
    syn_states: std.ArrayList(syntax.State) = .empty,
    /// This many entries of `syn_states` are still valid.
    syn_valid: usize = 0,

    swap_path: ?[]u8 = null,
    swapped_rev: u64 = 0,
    /// Random identifier for the backup while the file has no name.
    scratch_id: u64 = 0,

    /// The file as it is in the last git commit (`null`: not in git).
    git_raw: ?[]u8 = null,
    /// Its lines; they point into `git_raw`.
    git_base: ?[][]const u8 = null,
    /// Mark per line for the git gutter, matching text revision `git_rev`.
    git_marks: std.ArrayList(iro.gitdiff.Mark) = .empty,
    git_rev: u64 = std.math.maxInt(u64),
    /// Content of a recovery file found, while the question is pending.
    recover_text: ?[]u8 = null,
    /// Has it been checked whether anything is left over from a crash? Until
    /// then nobody may touch the recovery file.
    recover_checked: bool = false,
    /// Lock on the file while this tab has it open, so a second iro notices.
    /// It is an `flock`: if iro dies, the kernel lets go by itself.
    lock_fd: ?std.os.linux.fd_t = null,
    lock_path: ?[:0]u8 = null,
    /// Another iro already has this file open (its PID, 0 if unknown). This
    /// tab is then read-only and leaves the other one's backup alone.
    foreign: ?u32 = null,
    /// Disk state of an outside change already reported for this tab, so the
    /// warning comes once and not on every return to iro.
    outside_seen: @FieldType(fileio.Meta, "disk") = null,
    /// The file has vanished from disk, and iro has said so.
    gone_noted: bool = false,

    /// Takes ownership of `ed` and `path`. If creation fails, both still belong to the caller.
    fn create(gpa: Allocator, ed: Editor, meta: fileio.Meta, path: ?[]u8) Allocator.Error!*Doc {
        const self = try gpa.create(Doc);
        self.* = .{ .ed = ed, .meta = meta, .path = path };
        return self;
    }

    fn destroy(self: *Doc, gpa: Allocator) void {
        self.unlock(gpa);
        self.ed.deinit();
        if (self.path) |p| gpa.free(p);
        self.syn_states.deinit(gpa);
        if (self.swap_path) |p| gpa.free(p);
        if (self.recover_text) |t| gpa.free(t);
        if (self.git_base) |b| gpa.free(b);
        if (self.git_raw) |r| gpa.free(r);
        self.git_marks.deinit(gpa);
        gpa.destroy(self);
    }

    fn unlock(self: *Doc, gpa: Allocator) void {
        const linux = std.os.linux;
        const fd = self.lock_fd orelse return;
        // Remove the file before letting go: whoever opens it next creates a
        // fresh one instead of locking a file that is about to vanish.
        if (self.lock_path) |p| {
            _ = linux.unlink(p.ptr);
            gpa.free(p);
        }
        _ = linux.close(fd);
        self.lock_fd = null;
        self.lock_path = null;
    }

    pub fn name(self: *const Doc, lang: iro.lang.Lang) []const u8 {
        if (self.path) |p| return std.fs.path.basename(p);
        return self.title orelse (if (lang == .en) "untitled" else "unbenannt");
    }

    /// Empty, unnamed, untouched: such a tab may be replaced when opening a
    /// file.
    pub fn pristine(self: *const Doc) bool {
        return self.path == null and !self.ed.isModified() and
            self.ed.buf.lineCount() == 1 and self.ed.buf.line(0).len == 0;
    }
};

pub const TabSpan = struct { x0: u16, x1: u16, index: usize };

pub const scroll_margin = 3;
const wheel_lines = 3;

pub const App = struct {
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,

    /// All open files, in tab order.
    docs: std.ArrayList(*Doc) = .empty,
    cur: usize = 0,
    /// The file in the front tab. Always points to `docs.items[cur]`.
    d: *Doc,
    /// Hint bar above the status line: shows which keys do something right now.
    /// F1 toggles it, and the choice is remembered.
    hints_on: bool = true,
    /// Height of the hint bar at the last draw (0 or 1).
    hints_h: usize = 0,
    /// Height of the tab bar at the last draw: 1 as soon as more than one file is open.
    tabs_h: usize = 0,
    /// Where each tab sits in the bar, for mouse clicks. Valid until the next draw.
    tab_spans: []const TabSpan = &.{},

    /// Dimensions of the text area at the last draw, for mouse and page-wise
    /// scrolling.
    text_h: usize = 1,
    text_w: usize = 1,
    gutter_w: usize = 4,

    prompt: ?Prompt = null,
    /// The command palette, while it is open.
    palette: ?Palette = null,
    /// Where the palette list was last drawn, for mouse clicks.
    pal_box: struct { x0: u16 = 0, x1: u16 = 0, y0: u16 = 0, y1: u16 = 0, x: u16 = 0, y: u16 = 0, w: u16 = 0, rows: u16 = 0 } = .{},
    search_origin: Pos = .{},
    last_search: std.ArrayList(u8) = .empty,
    /// What is still pending after a successful save.
    after_save: enum { stay, quit, close } = .stay,
    /// Did the last save succeed?
    save_ok: bool = false,
    should_quit: bool = false,
    /// "Save as" onto an existing file: the path, while the confirmation is
    /// pending.
    pending_save_as: ?[]u8 = null,
    /// Config Guard warning while waiting for confirmation to save anyway.
    guard_tool: []const u8 = "",
    guard_err: ?[]u8 = null,
    /// Whether the save that the Config Guard question interrupted had
    /// already been allowed to overwrite a changed file.
    guard_overwrite: bool = false,
    /// Find and replace: what is searched for, what it is replaced with and how
    /// many replacements so far.
    replace_needle: std.ArrayList(u8) = .empty,
    replace_with: std.ArrayList(u8) = .empty,
    replace_count: usize = 0,

    /// The file tree on the left. Only read when first shown.
    tree: ?Tree = null,
    tree_visible: bool = false,
    /// Where do keys go: to the text or to the tree?
    focus: enum { text, tree } = .text,
    /// Width of the tree including the separator at the last draw. 0: not
    /// visible.
    tree_w: usize = 0,
    tree_top: usize = 0,
    /// Should the tree follow the selection? Not while scrolling with the mouse
    /// wheel.
    tree_follow: bool = true,
    /// What the open tree prompt is about: the folder where something new is
    /// created, or the entry being renamed or trashed.
    tree_target: ?[]u8 = null,
    /// If iro was started with a folder, it is the root of the tree.
    start_dir: ?[]u8 = null,
    /// Blade (text only) or Forge (tree, minimap, git). Alt+G switches.
    gear: config.Gear = .forge,
    /// UI language, and the system's for `language = "auto"`.
    lang: Lang = .de,
    sys_lang: Lang = .de,

    msg_buf: [240]u8 = undefined,
    msg_len: usize = 0,
    msg_bad: bool = false,

    clipboard: std.ArrayList(u8) = .empty,
    /// Does `clipboard` hold a whole line (Ctrl+C/X without a selection)? Then
    /// Ctrl+V inserts it as its own line above the current one.
    clip_is_line: bool = false,
    pasting: bool = false,
    paste_buf: std.ArrayList(u8) = .empty,

    dragging: bool = false,
    /// Is the scrollbar or the minimap currently being dragged?
    scroll_drag: bool = false,
    scroll_w: usize = 0,
    minimap_w: usize = 0,
    minimap_forced: bool = false,
    minimap_drag: bool = false,
    flash_line: ?usize = null,
    flash_frames: u8 = 0,
    tree_anim_w: usize = 0,
    /// Word completion (Ctrl+Space / Alt+Space).
    comp_open: bool = false,
    comp_sel: usize = 0,
    comp_prefix_len: usize = 0,
    /// Split view (Alt+V): a second viewport next to the active one.
    split_on: bool = false,
    split_right_active: bool = false,
    split_other_doc: usize = 0,
    split_other_top: usize = 0,
    split_x: usize = 0,
    split_div_col: usize = 0,
    /// Underline search matches in the text until Esc clears them.
    show_hits: bool = false,
    /// Main menu (Esc/F10): open? Which entry is selected?
    menu_open: bool = false,
    menu_sel: usize = 0,
    /// Where the menu entries were last drawn, for the mouse: row of entry 0,
    /// left and right edge of the card.
    menu_box: struct { x0: u16 = 0, x1: u16 = 0, y0: u16 = 0, y1: u16 = 0, first_row: u16 = 0 } = .{},
    /// About (F9) while the card is open, including the decryption clocks.
    about: ?iro.about.Reveal = null,
    /// Settings page: open? Selected entry, first visible row, is it waiting
    /// for a new key?
    settings_open: bool = false,
    set_sel: usize = 0,
    set_top: usize = 0,
    set_capture: bool = false,
    /// Where card and list were last drawn, for the mouse.
    set_box: struct { x0: u16 = 0, x1: u16 = 0, y0: u16 = 0, y1: u16 = 0, list_y: u16 = 0, list_h: u16 = 0 } = .{},
    /// What was chosen on the settings page (= content of gewaehlt.lua).
    chosen: iro.settings.Chosen = .{},
    /// File indexes per search scope, so the next Ctrl+O shows results at once.
    /// Most recently used first.
    indexes: [3]?*iro.index.Index = @splat(null),
    /// Is a background refresh running? It replaces the old index of the same
    /// root once it has finished.
    refresh: ?*iro.index.Index = null,
    /// Recently opened files (full paths), newest first.
    recent: std.ArrayList([]u8) = .empty,
    loop: ?*Loop = null,
    /// Explicitly chosen search folder (folder at start, zoxide jump).
    search_dir: ?[]u8 = null,
    /// Terminal colours, if the terminal reveals them. iro computes the cursor
    /// line, selection and indent guides from them.
    term_bg: ?[3]u8 = null,
    term_fg: ?[3]u8 = null,
    accent_rgb: ?[3]u8 = null,
    /// Is the recovery timer running? Only while there is something to back up.
    swap_armed: bool = false,
    last_click: ?struct { at: Io.Timestamp, pos: Pos, count: u8 } = null,

    cfg: config.Config = .{},
    logo_img: ?vaxis.Image = null,
    showing_logo: bool = false,
    frame: std.heap.ArenaAllocator,

    fn deinit(self: *App) void {
        const gpa = self.gpa;
        for (self.docs.items) |doc| doc.destroy(gpa);
        self.docs.deinit(gpa);
        if (self.prompt) |*p| p.input.deinit(gpa);
        self.closePalette();
        self.last_search.deinit(gpa);
        self.replace_needle.deinit(gpa);
        self.replace_with.deinit(gpa);
        if (self.pending_save_as) |p| gpa.free(p);
        if (self.guard_err) |e| gpa.free(e);
        self.clipboard.deinit(gpa);
        self.paste_buf.deinit(gpa);
        if (self.tree) |*t| t.deinit();
        if (self.start_dir) |d| gpa.free(d);
        if (self.tree_target) |t| gpa.free(t);
        if (self.about) |*a| a.deinit(gpa);
        self.chosen.deinit(gpa);
        for (&self.indexes) |*slot| if (slot.*) |idx| {
            idx.deinit();
            slot.* = null;
        };
        if (self.refresh) |r| r.deinit();
        for (self.recent.items) |r| gpa.free(r);
        self.recent.deinit(gpa);
        if (self.search_dir) |d| gpa.free(d);
        self.cfg.deinit(gpa);
        self.frame.deinit();
    }

    /// Colour of normal text (for most themes: the terminal's).
    pub fn textColor(self: *const App) vaxis.Color {
        return toVaxisColor(self.cfg.theme.text);
    }

    pub fn accentColor(self: *const App) vaxis.Color {
        return toVaxisColor(self.cfg.theme.akzent);
    }

    pub fn pinkColor(self: *const App) vaxis.Color {
        return toVaxisColor(self.cfg.theme.tasten);
    }

    pub fn warnColor(self: *const App) vaxis.Color {
        return toVaxisColor(self.cfg.theme.warnung);
    }

    pub fn badColor(self: *const App) vaxis.Color {
        return toVaxisColor(self.cfg.theme.fehler);
    }

    /// Formatted text in the UI language, in `arena`.
    fn pickFmt(self: *const App, arena: Allocator, comptime de: []const u8, comptime en: []const u8, args: anytype) []const u8 {
        return (if (self.lang == .en) std.fmt.allocPrint(arena, en, args) else std.fmt.allocPrint(arena, de, args)) catch "";
    }

    /// How long ago, for a span in nanoseconds: "vor 12 Min." / "12 min ago".
    fn agoText(self: *const App, arena: Allocator, ns: i96) []const u8 {
        const s: u64 = @intCast(@max(@divTrunc(ns, std.time.ns_per_s), 0));
        if (s < 60) return self.pick("gerade eben", "just now");
        const m = s / 60;
        if (m < 60) return self.pickFmt(arena, "vor {d} Min.", "{d} min ago", .{m});
        const h = m / 60;
        if (h < 24) return self.pickFmt(arena, "vor {d} Std.", "{d} h ago", .{h});
        const days = h / 24;
        if (days == 1) return self.pick("vor 1 Tag", "1 day ago");
        return self.pickFmt(arena, "vor {d} Tagen", "{d} days ago", .{days});
    }

    /// Short text in the UI language.
    fn pick(self: *const App, de: []const u8, en: []const u8) []const u8 {
        return if (self.lang == .en) en else de;
    }

    fn sayOom(self: *App) void {
        self.say(true, "Zu wenig Speicher", "Not enough memory", .{});
    }

    /// "Yes" in a prompt: J in German, Y in English. Only the letter currently
    /// shown counts.
    fn yes(self: *const App, key: vaxis.Key) bool {
        return letter(key, if (self.lang == .en) 'y' else 'j');
    }

    /// "Discard": V in German, D in English.
    fn discard(self: *const App, key: vaxis.Key) bool {
        return letter(key, if (self.lang == .en) 'd' else 'v');
    }

    /// A letter answering a question. The questions show it in capitals, so
    /// Shift and Caps Lock count as well; with Ctrl, Alt or Super it is a
    /// shortcut, not an answer.
    fn letter(key: vaxis.Key, c: u8) bool {
        const m = key.mods;
        if (m.ctrl or m.alt or m.super or m.hyper or m.meta) return false;
        const upper: u21 = std.ascii.toUpper(c);
        if (key.codepoint == c or key.codepoint == upper) return true;
        if (key.shifted_codepoint) |s| if (s == upper) return true;
        if (key.text) |txt| return txt.len == 1 and std.ascii.toLower(txt[0]) == c;
        return false;
    }

    /// Message in the UI language. The compiler checks both versions.
    fn say(self: *App, is_bad: bool, comptime de: []const u8, comptime en: []const u8, args: anytype) void {
        switch (self.lang) {
            .de => self.setMsg(is_bad, de, args),
            .en => self.setMsg(is_bad, en, args),
        }
    }

    /// Like `say`, but into a buffer (for messages that appear later).
    fn tr(self: *const App, buf: []u8, comptime de: []const u8, comptime en: []const u8, args: anytype) []const u8 {
        return switch (self.lang) {
            .de => std.fmt.bufPrint(buf, de, args),
            .en => std.fmt.bufPrint(buf, en, args),
        } catch "";
    }

    fn setMsg(self: *App, is_bad: bool, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&self.msg_buf, fmt, args) catch self.msg_buf[0..self.msg_buf.len];
        self.msg_len = out.len;
        // Don't cut in the middle of a character.
        while (self.msg_len > 0 and !std.unicode.utf8ValidateSlice(self.msg_buf[0..self.msg_len])) self.msg_len -= 1;
        // Messages contain file names and output of other programs. Control
        // characters in them have no place in the status line.
        const m = self.msg_buf[0..self.msg_len];
        for (m, 0..) |b, i| {
            if (b < 0x20 or b == 0x7f) {
                m[i] = '?';
            } else if (b == 0xC2 and i + 1 < m.len and m[i + 1] >= 0x80 and m[i + 1] <= 0x9f) {
                m[i] = '?';
                m[i + 1] = '?';
            }
        }
        self.msg_bad = is_bad;
    }

    pub fn fileName(self: *const App) []const u8 {
        return self.d.name(self.lang);
    }

    // ───────────── Syntax colours ─────────────

    fn detectLang(self: *App) void {
        self.d.lang = if (self.d.path) |p| syntax.detect(p, self.d.ed.buf.line(0)) else null;
        self.d.syn_valid = 0;
    }

    /// Makes sure the line-start state is computed up to `upto`. Computation
    /// starts at the first changed line only.
    pub fn syncSyntax(self: *App, upto: usize, arena: Allocator) void {
        const lang = self.d.lang orelse return;
        const ed = &self.d.ed;
        const none = std.math.maxInt(usize);
        if (ed.dirty_from != none) {
            self.d.syn_valid = @min(self.d.syn_valid, ed.dirty_from + 1);
            ed.dirty_from = none;
        }
        const need = @min(upto + 1, ed.buf.lineCount());
        if (self.d.syn_states.items.len < need) {
            self.d.syn_states.resize(self.gpa, need) catch {
                self.d.lang = null; // better no colours than wrong ones
                return;
            };
        }
        const states = self.d.syn_states.items;
        if (self.d.syn_valid == 0) {
            states[0] = syntax.normal_state;
            self.d.syn_valid = 1;
        }
        while (self.d.syn_valid < need) : (self.d.syn_valid += 1) {
            const l = ed.buf.line(self.d.syn_valid - 1);
            const scratch = arena.alloc(syntax.Kind, l.len) catch {
                self.d.lang = null;
                return;
            };
            states[self.d.syn_valid] = syntax.highlightLine(lang, l, states[self.d.syn_valid - 1], scratch);
        }
    }

    pub fn kindStyle(self: *const App, kind: syntax.Kind) vaxis.Style {
        const t = self.cfg.theme;
        return switch (kind) {
            .normal => .{ .fg = toVaxisColor(t.text) },
            .comment => .{ .fg = toVaxisColor(t.kommentar), .italic = true },
            .string => .{ .fg = toVaxisColor(t.zeichenkette) },
            .number => .{ .fg = toVaxisColor(t.zahl) },
            .keyword => .{ .fg = toVaxisColor(t.befehlswort) },
            .key => .{ .fg = toVaxisColor(t.schluessel) },
            .heading => .{ .fg = toVaxisColor(t.ueberschrift), .bold = true },
            .added => .{ .fg = toVaxisColor(t.git_neu) },
            .removed => .{ .fg = toVaxisColor(t.git_weg) },
        };
    }

    // ───────────── Colours from the terminal ─────────────

    /// Asks the terminal for its background, foreground and accent colours. The
    /// answers arrive as events. Terminals that don't support this simply stay
    /// silent; the plain look remains.
    fn queryColors(self: *App) void {
        const w = self.tty.writer();
        self.vx.queryColor(w, .bg) catch {};
        self.vx.queryColor(w, .fg) catch {};
        switch (self.cfg.theme.akzent) {
            .index => |i| self.vx.queryColor(w, .{ .index = i }) catch {},
            else => {},
        }
    }

    /// Stores a colour answer. Returns whether anything changed.
    fn onColorReport(self: *App, r: vaxis.Color.Report) bool {
        const slot: *?[3]u8 = switch (r.kind) {
            .bg => &self.term_bg,
            .fg => &self.term_fg,
            .index => |i| blk: {
                switch (self.cfg.theme.akzent) {
                    .index => |a| if (a == i) break :blk &self.accent_rgb,
                    else => {},
                }
                return false;
            },
            .cursor => return false,
        };
        if (slot.*) |old| {
            if (std.mem.eql(u8, &old, &r.value)) return false;
        }
        slot.* = r.value;
        return true;
    }

    /// Blends two colours: `percent` percent of `b` into `a`.
    pub fn mix(a: [3]u8, b: [3]u8, percent: u32) vaxis.Color {
        var out: [3]u8 = undefined;
        for (&out, a, b) |*o, x, y| {
            o.* = @intCast((@as(u32, x) * (100 - percent) + @as(u32, y) * percent) / 100);
        }
        return .{ .rgb = out };
    }

    pub fn accentRgb(self: *const App) ?[3]u8 {
        return switch (self.cfg.theme.akzent) {
            .rgb => |c| c,
            .index => self.accent_rgb,
            .default => self.term_fg,
        };
    }

    /// Background of the cursor line: a touch lighter (or darker) than the
    /// background. `null`: no highlight.
    pub fn cursorLineBg(self: *const App) ?vaxis.Color {
        return switch (self.cfg.theme.cursorzeile) {
            .off => null,
            .color => |c| toVaxisColor(c),
            .auto => mix(self.term_bg orelse return null, self.term_fg orelse return null, 18),
        };
    }

    /// Background of selected text. `null`: invert colours as before.
    pub fn selectionBg(self: *const App) ?vaxis.Color {
        return switch (self.cfg.theme.auswahl) {
            .off => null,
            .color => |c| toVaxisColor(c),
            .auto => mix(self.term_bg orelse return null, self.accentRgb() orelse return null, 36),
        };
    }

    /// Style for everything subtle: indent guides, scrollbar, minimap.
    pub fn faintStyle(self: *const App) vaxis.Style {
        const bg = self.term_bg orelse return .{ .dim = true };
        const fg = self.term_fg orelse return .{ .dim = true };
        return .{ .fg = mix(bg, fg, 28) };
    }

    /// What is currently being searched for (for underlining all matches).
    pub fn activeNeedle(self: *const App) []const u8 {
        if (self.prompt) |p| switch (p.kind) {
            .search, .replace_find => return p.input.items,
            .replace_with, .confirm_each => return self.replace_needle.items,
            else => {},
        };
        return if (self.show_hits) self.last_search.items else "";
    }

    // ───────────── Git gutter ─────────────

    /// Fetches the file as it is in the last commit. Only git's object store is
    /// read (`cat-file`), so no filters or hooks of the repository run. Without
    /// git or without a commit there is simply no gutter.
    fn loadGitBase(self: *App, d: *Doc) void {
        const gpa = self.gpa;
        if (d.git_base) |b| gpa.free(b);
        if (d.git_raw) |r| gpa.free(r);
        d.git_base = null;
        d.git_raw = null;
        d.git_marks.clearRetainingCapacity();
        d.git_rev = std.math.maxInt(u64);
        if (!self.gitWanted()) return;
        const path = d.path orelse return;
        const dir = std.fs.path.dirname(path) orelse return;
        const spec = std.fmt.allocPrint(gpa, "HEAD:./{s}", .{std.fs.path.basename(path)}) catch return;
        defer gpa.free(spec);
        const result = fileio.runHelper(
            gpa,
            self.io,
            &.{ "git", "--no-optional-locks", "-C", dir, "cat-file", "blob", spec },
            .limited(8 * 1024 * 1024),
            .limited(64 * 1024),
        ) catch return;
        gpa.free(result.stderr);
        const ok = result.term == .exited and result.term.exited == 0 and std.unicode.utf8ValidateSlice(result.stdout);
        if (!ok) return gpa.free(result.stdout);
        d.git_base = iro.gitdiff.splitLines(gpa, result.stdout) catch return gpa.free(result.stdout);
        d.git_raw = result.stdout;
    }

    /// The git gutter exists only in Forge. Blade skips the git call.
    fn gitWanted(self: *const App) bool {
        return self.cfg.git_gutter and self.gear == .forge;
    }

    /// Recomputes the git gutter marks when the text has changed.
    pub fn syncGit(self: *App, arena: Allocator) void {
        const d = self.d;
        const base = d.git_base orelse return d.git_marks.clearRetainingCapacity();
        const n = d.ed.buf.lineCount();
        const rev = d.ed.revision();
        if (d.git_rev == rev and d.git_marks.items.len == n) return;
        d.git_rev = rev;
        d.git_marks.clearRetainingCapacity();
        // For huge files the comparison would be too expensive on every
        // keystroke.
        if (n > 100_000) return;
        const lines = arena.alloc([]const u8, n) catch return;
        for (lines, 0..) |*l, i| l.* = d.ed.buf.line(i);
        d.git_marks.resize(self.gpa, n) catch return;
        iro.gitdiff.marks(self.gpa, base, lines, d.git_marks.items) catch d.git_marks.clearRetainingCapacity();
    }

    // ───────────── Animations (0 W when idle) ─────────────

    fn triggerFlash(self: *App, line: usize) void {
        if (!self.cfg.animations or self.term_bg == null) return;
        self.flash_line = line;
        self.flash_frames = 6;
    }

    fn isAnimating(self: *const App) bool {
        if (!self.cfg.animations) return false;
        if (self.about) |*a| if (!a.done()) return true;
        return self.flash_frames > 0 or self.tree_anim_w > 0;
    }

    fn stepAnimation(self: *App) void {
        if (self.about) |*a| a.step();
        if (self.flash_frames > 0) {
            self.flash_frames -= 1;
            if (self.flash_frames == 0) self.flash_line = null;
        }
        if (self.tree_anim_w > 0) {
            const w = self.vx.window().width;
            if (!self.tree_visible or !self.cfg.animations or w < 50) {
                self.tree_anim_w = 0;
            } else {
                const target = std.math.clamp(w / 4, 22, 34);
                self.tree_anim_w += 6;
                if (self.tree_anim_w >= target) self.tree_anim_w = 0;
            }
        }
    }

    // ───────────── Settings (Lua) ─────────────

    fn configPath(self: *App, buf: []u8) ?[]const u8 {
        return if (self.env.get("XDG_CONFIG_HOME")) |x|
            std.fmt.bufPrint(buf, "{s}/iro/init.lua", .{x}) catch null
        else if (self.env.get("HOME")) |h|
            std.fmt.bufPrint(buf, "{s}/.config/iro/init.lua", .{h}) catch null
        else
            null;
    }

    /// The file the settings page writes to: next to init.lua.
    fn chosenPath(self: *App, buf: []u8) ?[]const u8 {
        var tmp: [Io.Dir.max_path_bytes]u8 = undefined;
        const init_path = self.configPath(&tmp) orelse return null;
        const dir = std.fs.path.dirname(init_path) orelse return null;
        return std.fmt.bufPrint(buf, "{s}/gewaehlt.lua", .{dir}) catch null;
    }

    /// Is `path` our own init.lua? Also via detours such as a symlink.
    fn isConfigFile(self: *App, path: []const u8) bool {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const cfg_path = self.configPath(&buf) orelse return false;
        if (std.mem.eql(u8, cfg_path, path)) return true;
        var real: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().realPathFile(self.io, cfg_path, &real) catch return false;
        return std.mem.eql(u8, real[0..n], path);
    }

    fn configureEditor(self: *const App, ed: *Editor) void {
        ed.tab_width = self.cfg.tab_width;
        if (self.cfg.soft_tabs) |s| ed.soft_tabs = s;
    }

    fn applyConfig(self: *App) void {
        self.lang = self.cfg.language orelse self.sys_lang;
        self.cfg.lang = self.lang;
        if (self.cfg.hints_on) |h| self.hints_on = h;
        for (self.docs.items) |doc| {
            self.configureEditor(&doc.ed);
            // The git gutter may have been switched on or off in the config.
            if (self.gitWanted() != (doc.git_base != null)) self.loadGitBase(doc);
        }
        self.accent_rgb = null;
        self.minimap_forced = false;
        self.closeComp();
        if (!self.cfg.animations) {
            self.flash_frames = 0;
            self.flash_line = null;
            self.tree_anim_w = 0;
        }
        if (self.tree) |*t| {
            if (t.show_hidden != self.cfg.show_hidden) {
                t.show_hidden = self.cfg.show_hidden;
                t.refresh(self.io) catch {};
            }
        }
    }

    /// Reads gewaehlt.lua (clicks on the settings page) and init.lua (by hand)
    /// and stacks them; init.lua wins.
    fn loadConfig(self: *App, announce: bool) void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = self.configPath(&buf) orelse {
            if (announce) self.say(true, "Kein Config-Ordner gefunden", "No config folder found", .{});
            return;
        };
        const cwd = Io.Dir.cwd();
        const limit: Io.Limit = .limited(1024 * 1024);
        const raw: ?[]u8 = cwd.readFileAlloc(self.io, path, self.gpa, limit) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                self.say(true, "init.lua nicht lesbar ({s})", "init.lua not readable ({s})", .{@errorName(err)});
                return;
            },
        };
        defer if (raw) |r| self.gpa.free(r);
        var cbuf: [Io.Dir.max_path_bytes]u8 = undefined;
        const chosen_raw: ?[]u8 = if (self.chosenPath(&cbuf)) |cp|
            cwd.readFileAlloc(self.io, cp, self.gpa, limit) catch null
        else
            null;
        defer if (chosen_raw) |r| self.gpa.free(r);

        // The page remembers what was chosen even without Lua.
        if (iro.settings.Chosen.parse(self.gpa, chosen_raw orelse "")) |c| {
            self.chosen.deinit(self.gpa);
            self.chosen = c;
        } else |_| {}

        if (raw == null and chosen_raw == null) {
            if (announce) {
                var old = self.cfg;
                self.cfg = .{};
                old.deinit(self.gpa);
                self.applyConfig();
                self.say(false, "Standardeinstellungen aktiv (keine init.lua)", "Default settings active (no init.lua)", .{});
            }
            return;
        }

        var next = config.Config.loadLayered(self.gpa, chosen_raw, raw) catch {
            return self.say(true, "Zu wenig Speicher für init.lua", "Not enough memory for init.lua", .{});
        };
        // On a syntax or runtime error while reloading, the working settings are kept
        // so the mistake can be fixed in peace.
        if (announce and next.fatal_lua) {
            defer next.deinit(self.gpa);
            next.lang = self.lang;
            if (next.errText()) |m| self.setMsg(true, "{s}: {s}", .{ next.err_src, m });
            return;
        }
        var old = self.cfg;
        self.cfg = next;
        old.deinit(self.gpa);
        self.applyConfig();
        if (self.cfg.errText()) |m| {
            self.setMsg(true, "{s}: {s}", .{ self.cfg.err_src, m });
        } else if (announce) {
            self.say(false, "Einstellungen neu geladen", "Settings reloaded", .{});
        }
    }

    fn openConfigFile(self: *App) void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = self.configPath(&buf) orelse return self.say(true, "Kein Config-Ordner gefunden", "No config folder found", .{});
        const cwd = Io.Dir.cwd();
        if (cwd.access(self.io, path, .{})) |_| {} else |_| {
            if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(self.io, dir) catch {};
            fileio.writeAtomic(self.io, cwd, path, config.defaultInitLua(self.lang)) catch |err| {
                return self.say(true, "Konnte init.lua nicht anlegen ({s})", "Could not create init.lua ({s})", .{@errorName(err)});
            };
        }
        const owned = self.gpa.dupe(u8, path) catch return self.sayOom();
        self.openPath(owned, false);
    }

    // ───────────── Help page ─────────────

    /// Is the front tab read-only? Then the status line says so right away, so
    /// nobody wonders why nothing happens.
    fn locked(self: *App) bool {
        if (!self.d.read_only) return false;
        if (self.d.foreign != null) {
            self.sayForeign();
            return true;
        }
        self.say(false, "Die Hilfe ist nur zum Lesen. {s} schließt sie.", "The help is read-only. {s} closes it.", .{self.cfg.keyLabel(.close_tab)});
        return true;
    }

    /// Opens the help as its own tab. The text is built fresh from the current
    /// key bindings, so it always shows what actually applies.
    fn openHelp(self: *App) void {
        const gpa = self.gpa;
        for (self.docs.items, 0..) |doc, i| {
            if (doc.title != null and doc.path == null) {
                self.switchTo(i);
                self.focus = .text;
                return;
            }
        }
        const txt = iro.help.generate(self.frame.allocator(), &self.cfg) catch return self.sayOom();
        const buf = iro.Buffer.fromBytes(gpa, txt) catch return self.sayOom();
        var ed = Editor.fromBuffer(gpa, buf);
        self.configureEditor(&ed);
        const doc = Doc.create(gpa, ed, .{}, null) catch {
            ed.deinit();
            return self.sayOom();
        };
        doc.title = self.pick("Hilfe", "Help");
        doc.read_only = true;
        self.addDoc(doc) catch {
            doc.destroy(gpa);
            return self.sayOom();
        };
        // Headings and quotes get colours like in a Markdown file.
        self.d.lang = syntax.detect("hilfe.md", "");
        self.d.syn_valid = 0;
        self.focus = .text;
        self.say(false, "{s} schließt die Hilfe wieder", "{s} closes the help again", .{self.cfg.keyLabel(.close_tab)});
    }

    // ───────────── Recovery file ─────────────

    const swap_magic = "IRO-WIEDERHERSTELLUNG 1\n";

    /// iro's folder for everything it remembers: `sub` inside it, full path.
    /// `null`: the system doesn't say where such things belong.
    fn statePath(self: *App, buf: []u8, sub: []const u8) ?[]const u8 {
        return if (self.env.get("XDG_STATE_HOME")) |x|
            std.fmt.bufPrint(buf, "{s}/iro/{s}", .{ x, sub }) catch null
        else if (self.env.get("HOME")) |h|
            std.fmt.bufPrint(buf, "{s}/.local/state/iro/{s}", .{ h, sub }) catch null
        else
            null;
    }

    /// Recovery files of secrets: a folder in RAM that only the user can
    /// read and that is cleared at logout. `null`: there is none.
    fn runtimeSwapDir(self: *App, buf: []u8) ?[]const u8 {
        const run = self.env.get("XDG_RUNTIME_DIR") orelse return null;
        if (!std.fs.path.isAbsolute(run)) return null;
        return std.fmt.bufPrint(buf, "{s}/iro/swap", .{run}) catch null;
    }

    /// Reads at start whether the hint bar was switched off.
    fn loadHintsChoice(self: *App) void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const file = self.statePath(&buf, "hinweise") orelse return;
        var content: [16]u8 = undefined;
        const got = Io.Dir.cwd().readFile(self.io, file, &content) catch return;
        if (std.mem.startsWith(u8, got, "aus")) self.hints_on = false;
    }

    /// F1: hint bar off or on. iro remembers the choice in its state folder.
    fn toggleHints(self: *App) void {
        self.hints_on = !self.hints_on;
        self.setMsg(false, "{s}", .{if (self.hints_on) self.pick("Hinweise an", "Hints on") else self.pick("Hinweise aus, F1 holt sie zurück", "Hints off, F1 brings them back")});
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const file = self.statePath(&buf, "hinweise") orelse return;
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, std.fs.path.dirname(file) orelse return) catch return;
        fileio.writeAtomic(self.io, cwd, file, if (self.hints_on) "an\n" else "aus\n") catch {};
    }

    /// Determines where the recovery file for the current file lives.
    fn initSwapPath(self: *App) !void {
        if (self.d.swap_path) |p| {
            self.gpa.free(p);
            self.d.swap_path = null;
        }
        // Secrets (keys, tokens, owner-only files, sudoedit copies) never get a
        // recovery file on disk. Theirs lives in RAM ($XDG_RUNTIME_DIR), which
        // survives a crash of iro but is gone after logout. Without such a
        // folder they get none.
        const secret = if (self.d.path) |p| iro.history.isSecret(self.io, p) else false;
        var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const swap_dir = if (secret) self.runtimeSwapDir(&dir_buf) else self.statePath(&dir_buf, "swap");
        defer if (self.d.path != null) self.lockDoc(self.d);
        const state_dir = swap_dir orelse return;
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, state_dir) catch return;
        // Backups contain the content of open files, protected ones included.
        // The folder is therefore owner-only.
        cwd.setFilePermissions(self.io, state_dir, fileio.private_dir, .{}) catch {};
        if (self.d.path) |path| {
            self.d.swap_path = try std.fmt.allocPrint(self.gpa, "{s}/{x:0>16}.swap", .{ state_dir, std.hash.Wyhash.hash(0, path) });
        } else {
            // Even a file without a name is backed up. The name records which
            // iro has it open, so a second one leaves it alone.
            if (self.d.scratch_id == 0) {
                var rnd: [8]u8 = undefined;
                self.io.random(&rnd);
                self.d.scratch_id = std.mem.readInt(u64, &rnd, .little) | 1;
            }
            self.d.swap_path = try std.fmt.allocPrint(self.gpa, "{s}/" ++ scratch_prefix ++ "{d}-{x:0>16}.swap", .{ state_dir, std.os.linux.getpid(), self.d.scratch_id });
        }
    }

    /// Takes the lock for `d`'s file (and lets go of an earlier one). If
    /// another iro holds it, the tab becomes read-only.
    fn lockDoc(self: *App, d: *Doc) void {
        const linux = std.os.linux;
        d.unlock(self.gpa);
        d.foreign = null;
        const file = d.path orelse return;
        d.read_only = false;
        var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const state_dir = self.statePath(&dir_buf, "swap") orelse return;
        const path = std.fmt.allocPrintSentinel(self.gpa, "{s}/{x:0>16}.lock", .{ state_dir, std.hash.Wyhash.hash(0, file) }, 0) catch return;
        const rc = linux.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(rc) != .SUCCESS) return self.gpa.free(path);
        const fd: linux.fd_t = @intCast(rc);
        switch (linux.errno(linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
            .SUCCESS => {
                // The PID is only for the message in the other iro.
                var buf: [16]u8 = undefined;
                const pid = std.fmt.bufPrint(&buf, "{d}\n", .{linux.getpid()}) catch unreachable;
                _ = linux.ftruncate(fd, 0);
                _ = linux.pwrite(fd, pid.ptr, pid.len, 0);
                d.lock_fd = fd;
                d.lock_path = path;
            },
            .AGAIN => {
                var buf: [16]u8 = undefined;
                const n = linux.pread(fd, &buf, buf.len, 0);
                const got = if (linux.errno(n) == .SUCCESS) buf[0..n] else buf[0..0];
                d.foreign = std.fmt.parseInt(u32, std.mem.trim(u8, got, " \n"), 10) catch 0;
                d.read_only = true;
                _ = linux.close(fd);
                self.gpa.free(path);
            },
            // A file system without locks: carry on as before.
            else => {
                _ = linux.close(fd);
                self.gpa.free(path);
            },
        }
    }

    fn sayForeign(self: *App) void {
        const pid = self.d.foreign orelse return;
        const name = self.d.name(self.lang);
        if (pid != 0) {
            self.say(true, "Nur zum Lesen: {s} ist schon in iro PID {d} offen", "Read-only: {s} is already open in iro PID {d}", .{ name, pid });
        } else {
            self.say(true, "Nur zum Lesen: {s} ist schon in einem anderen iro offen", "Read-only: {s} is already open in another iro", .{name});
        }
    }

    const scratch_prefix = "unbenannt-";

    /// At start, recovers unnamed files a previous iro had open when it crashed
    /// or vanished with its window.
    fn recoverScratch(self: *App) usize {
        const gpa = self.gpa;
        var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const state_dir = self.statePath(&dir_buf, "swap") orelse return 0;
        var dir = Io.Dir.cwd().openDir(self.io, state_dir, .{ .iterate = true }) catch return 0;
        defer dir.close(self.io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (!std.mem.startsWith(u8, e.name, scratch_prefix) or !std.mem.endsWith(u8, e.name, ".swap")) continue;
            if (names.items.len >= 20) break;
            const owned = gpa.dupe(u8, e.name) catch break;
            names.append(gpa, owned) catch {
                gpa.free(owned);
                break;
            };
        }
        std.mem.sortUnstable([]u8, names.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);

        var count: usize = 0;
        for (names.items) |name| {
            // Does the backup belong to an iro that is still running? Then
            // hands off.
            const rest = name[scratch_prefix.len..];
            const dash = std.mem.indexOfScalar(u8, rest, '-') orelse continue;
            const pid = std.fmt.parseInt(u32, rest[0..dash], 10) catch continue;
            if (self.iroAlive(pid)) continue;

            const raw = dir.readFileAlloc(self.io, name, gpa, .limited(fileio.max_file_size + 8192)) catch continue;
            defer gpa.free(raw);
            if (!std.mem.startsWith(u8, raw, swap_magic ++ "\n")) continue;
            var loaded = fileio.decode(gpa, raw[swap_magic.len + 1 ..]) catch continue;
            const body = loaded.buf.toBytes(gpa, "\n") catch {
                loaded.buf.deinit();
                continue;
            };
            loaded.buf.deinit();
            defer gpa.free(body);

            var ed = Editor.init(gpa) catch continue;
            self.configureEditor(&ed);
            ed.insertText(body) catch {
                ed.deinit();
                continue;
            };
            ed.setCursor(.{}, false);
            const doc = Doc.create(gpa, ed, loaded.meta, null) catch {
                ed.deinit();
                continue;
            };
            doc.recover_checked = true;
            self.addDoc(doc) catch {
                doc.destroy(gpa);
                continue;
            };
            // Only once the new backup is in place may the old one go.
            doc.swapped_rev = std.math.maxInt(u64);
            self.writeSwap(doc);
            if (doc.swapped_rev != std.math.maxInt(u64)) dir.deleteFile(self.io, name) catch {};
            count += 1;
        }
        return count;
    }

    /// Is an iro (still) running under this process ID?
    fn iroAlive(self: *App, pid: u32) bool {
        if (pid == std.os.linux.getpid()) return true;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return true;
        var buf: [64]u8 = undefined;
        const got = Io.Dir.cwd().readFile(self.io, path, &buf) catch return false;
        return std.mem.eql(u8, std.mem.trim(u8, got, " \n"), "iro");
    }

    /// Does `d` hold a change its recovery file doesn't know yet?
    fn swapDue(d: *const Doc) bool {
        // The backup of a file another iro has open belongs to that one.
        if (d.swap_path == null or d.foreign != null) return false;
        // As long as an old backup has not been offered or the question about
        // it has not been answered, it stays untouched.
        if (!d.recover_checked or d.recover_text != null) return false;
        return d.ed.revision() != d.swapped_rev;
    }

    fn writeSwap(self: *App, d: *Doc) void {
        if (!swapDue(d)) return;
        const swap = d.swap_path.?;
        const rev = d.ed.revision();
        if (!d.ed.isModified()) return self.removeSwap(d);

        const body = fileio.encode(self.gpa, &d.ed.buf, d.meta) catch return;
        defer self.gpa.free(body);
        const all = std.mem.concat(self.gpa, u8, &.{ swap_magic, d.path orelse "", "\n", body }) catch return;
        defer self.gpa.free(all);
        const cwd = Io.Dir.cwd();
        fileio.writeAtomicMode(self.io, cwd, swap, all, fileio.private_file) catch return;
        // Backups from older iro versions were world-readable.
        cwd.setFilePermissions(self.io, swap, fileio.private_file, .{}) catch {};
        d.swapped_rev = rev;
    }

    fn removeSwap(self: *App, d: *Doc) void {
        const swap = d.swap_path orelse return;
        if (!d.recover_checked or d.foreign != null) return;
        Io.Dir.cwd().deleteFile(self.io, swap) catch {};
        d.swapped_rev = d.ed.revision();
    }

    /// Checks at start whether anything is left over from an earlier crash.
    fn checkRecovery(self: *App) void {
        const swap = self.d.swap_path orelse return;
        // Unnamed files are recovered by `recoverScratch` at start.
        const own_path = self.d.path orelse return;
        // A backup of a file another iro has open is that one's live work, not
        // something left over from a crash.
        if (self.d.foreign != null) return;
        const cwd = Io.Dir.cwd();
        const raw = cwd.readFileAlloc(self.io, swap, self.gpa, .limited(fileio.max_file_size + 8192)) catch return;
        defer self.gpa.free(raw);
        if (!std.mem.startsWith(u8, raw, swap_magic)) return;
        const after_magic = raw[swap_magic.len..];
        const nl = std.mem.indexOfScalar(u8, after_magic, '\n') orelse return;
        if (!std.mem.eql(u8, after_magic[0..nl], own_path)) return;
        const body = after_magic[nl + 1 ..];

        // If the same content is already on disk, the backup is obsolete.
        const current = fileio.encode(self.gpa, &self.d.ed.buf, self.d.meta) catch return;
        defer self.gpa.free(current);
        if (std.mem.eql(u8, body, current)) return self.removeSwap(self.d);

        var loaded = fileio.decode(self.gpa, body) catch return;
        defer loaded.buf.deinit();
        self.d.recover_text = loaded.buf.toBytes(self.gpa, "\n") catch return;
        self.prompt = .{ .kind = .recover };
    }

    // ───────────── Saving ─────────────

    const SaveOpts = struct {
        /// The user agreed to overwrite what is on disk (changed elsewhere, or
        /// an existing file chosen in "Save as").
        overwrite: bool = false,
        /// The user saw the Config Guard warning and saves anyway.
        guard_ok: bool = false,
    };

    fn save(self: *App, opts: SaveOpts) void {
        self.save_ok = false;
        const path = self.d.path orelse return self.openPrompt(.save_as, "");
        const cwd = Io.Dir.cwd();
        if (!opts.overwrite and fileio.changedOnDisk(self.io, cwd, path, self.d.meta)) {
            return self.openPrompt(.confirm_overwrite, "");
        }
        if (!opts.guard_ok and self.cfg.config_guard) {
            const draft = fileio.encode(self.gpa, &self.d.ed.buf, self.d.meta) catch null;
            defer if (draft) |b| self.gpa.free(b);
            // Under sudoedit the file is a copy in /var/tmp; check it as what
            // it really is.
            var orig_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const check_path = iro.guard.sudoeditOriginal(self.io, path, &orig_buf) orelse path;
            if (draft) |bytes| {
                if (iro.guard.checkPreSave(self.gpa, self.io, check_path, bytes, self.lang) catch null) |prob| {
                    self.openPrompt(.confirm_guard, "");
                    self.guard_overwrite = opts.overwrite;
                    self.guard_tool = prob.tool;
                    self.guard_err = prob.detail;
                    return;
                }
            }
        }
        // The state on disk goes into the history before it is overwritten.
        // Saving an untouched tab changes nothing on disk, unless it overwrites
        // someone else's edit, which is worth keeping too.
        if (self.cfg.history and (self.d.ed.isModified() or opts.overwrite)) {
            var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            if (self.statePath(&root_buf, "history")) |root| iro.history.keep(self.gpa, self.io, root, path) catch {};
        }
        fileio.save(self.gpa, self.io, cwd, path, &self.d.ed.buf, &self.d.meta) catch |err| {
            self.after_save = .stay;
            return self.say(true, "Speichern fehlgeschlagen: {s}", "Saving failed: {s}", .{@errorName(err)});
        };
        self.save_ok = true;
        self.d.ed.markSaved();
        // Maybe something was committed elsewhere in the meantime.
        self.loadGitBase(self.d);
        self.removeSwap(self.d);
        const n = self.d.ed.buf.lineCount();
        self.say(false, "Gespeichert: {s} ({d} {s})", "Saved: {s} ({d} {s})", .{ self.fileName(), n, if (self.lang == .en) (if (n == 1) "line" else "lines") else (if (n == 1) "Zeile" else "Zeilen") });
        // Saving your init.lua should take effect immediately, without hunting
        // for "Reload settings". An error in it stays a message, and the
        // running settings stay as they are.
        if (self.isConfigFile(path)) {
            self.loadConfig(true);
            if (!self.msg_bad) self.say(false, "Gespeichert und sofort übernommen: {s}", "Saved and applied right away: {s}", .{self.fileName()});
        }
        if (self.cfg.config_guard and iro.guard.isHyprConfig(path) and self.env.get("HYPRLAND_INSTANCE_SIGNATURE") != null) {
            // Give Hyprland a moment to reload the saved config, then check for errors.
            self.io.sleep(.fromMilliseconds(80), .awake) catch {};
            if (iro.guard.checkHyprland(self.gpa, self.io) catch null) |err_line| {
                defer self.gpa.free(err_line);
                self.after_save = .stay;
                self.say(true, "Hyprland: {s} ({s} holt alte Version)", "Hyprland: {s} ({s} restores previous)", .{ err_line, self.cfg.keyLabel(.history) });
            }
        }
        const after = self.after_save;
        self.after_save = .stay;
        switch (after) {
            .stay => self.triggerFlash(self.d.ed.cursor.line),
            // Maybe another tab with changes is still waiting.
            .quit => self.requestQuit(),
            .close => self.closeCurrent(),
        }
    }

    /// "Save as": gives the file its new name and saves. If saving fails, everything stays
    /// with the old name. From here on `new_path` belongs to iro.
    fn saveAs(self: *App, new_path: []u8) void {
        const gpa = self.gpa;
        const d = self.d;
        const old_path = d.path;
        const old_swap = d.swap_path;
        const old_disk = d.meta.disk;
        const old_read_only = d.read_only;
        d.swap_path = null;
        d.path = new_path;
        d.meta.disk = null;
        self.initSwapPath() catch {};
        // Another iro has the target open: writing into it would destroy its
        // work, so nothing is saved.
        const foreign = d.foreign;
        if (foreign == null) self.save(.{ .overwrite = true });
        // If the Config Guard asks first, the tab keeps its new name; the
        // answer then saves under it (or not).
        const guard_asks = if (self.prompt) |p| p.kind == .confirm_guard else false;
        if (foreign != null or (!self.save_ok and !guard_asks)) {
            // Back to square one; the error message from `save` stays.
            if (d.swap_path) |p| gpa.free(p);
            d.swap_path = old_swap;
            d.path = old_path;
            d.meta.disk = old_disk;
            self.lockDoc(d);
            // A tab without a file has no lock to decide; it keeps what it
            // was (the help stays read-only, an unnamed text stays editable).
            if (old_path == null) d.read_only = old_read_only;
            if (foreign) |pid| {
                const name = std.fs.path.basename(new_path);
                if (pid != 0) {
                    self.say(true, "Nicht gespeichert: {s} ist schon in iro PID {d} offen", "Not saved: {s} is already open in iro PID {d}", .{ name, pid });
                } else {
                    self.say(true, "Nicht gespeichert: {s} ist schon in einem anderen iro offen", "Not saved: {s} is already open in another iro", .{name});
                }
            }
            gpa.free(new_path);
            return;
        }
        // The backup under the old name is obsolete. If it stayed, iro would wrongly offer
        // it the next time the old file is opened. (After `save`, `d` may already be
        // closed, so only touch locals.)
        if (old_swap) |p| {
            Io.Dir.cwd().deleteFile(self.io, p) catch {};
            gpa.free(p);
        }
        if (old_path) |p| gpa.free(p);
        for (self.docs.items) |doc| {
            if (doc != d) continue;
            const keep = self.d;
            self.d = d;
            self.detectLang();
            self.d = keep;
            break;
        }
        self.updateTitle();
        // The new file should show up in the tree too.
        if (self.tree) |*t| t.refresh(self.io) catch {};
    }

    // ───────────── Switching files ─────────────

    fn updateTitle(self: *App) void {
        var title_buf: [300]u8 = undefined;
        // The name is sent to the terminal as a command. Control characters in
        // it could smuggle in commands of their own, so they go.
        const clean = text.cleanName(self.frame.allocator(), self.fileName());
        const title = std.fmt.bufPrint(&title_buf, "iro – {s}", .{clean}) catch "iro";
        self.vx.setTitle(self.tty.writer(), title) catch {};
    }

    /// What's due after every tab switch.
    fn activate(self: *App) void {
        self.d = self.docs.items[self.cur];
        self.dragging = false;
        self.scroll_drag = false;
        self.minimap_drag = false;
        self.flash_frames = 0;
        self.flash_line = null;
        self.closeComp();
        self.last_click = null;
        self.closePrompt();
        if (self.d.swap_path == null) self.initSwapPath() catch {};
        if (!self.d.recover_checked) {
            self.d.recover_checked = true;
            self.checkRecovery();
        }
        // Coming back to a tab is a good moment to look at its file again.
        const outside = self.checkOutside(self.d);
        if (outside != .none) self.sayOutside(outside, self.d) else self.sayForeign();
        self.updateTitle();
    }

    fn switchTo(self: *App, index: usize) void {
        if (index >= self.docs.items.len) return;
        self.cur = index;
        self.msg_len = 0;
        self.activate();
    }

    /// One tab forward (`step` = 1) or back (-1), wrapping around at the ends.
    fn cycleTab(self: *App, step: isize) void {
        const n: isize = @intCast(self.docs.items.len);
        if (n < 2) return self.say(false, "Nur eine Datei offen", "Only one file open", .{});
        const next = @mod(@as(isize, @intCast(self.cur)) + step, n);
        self.switchTo(@intCast(next));
    }

    /// Appends a file as a tab after the current one and brings it to the
    /// front. An empty, untouched tab is replaced instead.
    fn addDoc(self: *App, doc: *Doc) Allocator.Error!void {
        if (self.d.pristine()) {
            const old = self.d;
            self.docs.items[self.cur] = doc;
            old.destroy(self.gpa);
        } else {
            try self.docs.insert(self.gpa, self.cur + 1, doc);
            self.cur += 1;
        }
        self.d = doc;
        self.initSwapPath() catch {};
        self.detectLang();
        self.loadGitBase(doc);
        self.msg_len = 0;
        self.activate();
        if (self.docs.items.len > 1 and doc.title == null) {
            _ = self.upshiftToForge();
        }
    }

    /// Ctrl+N: new, empty tab.
    fn newTab(self: *App) void {
        if (self.d.pristine()) return;
        var ed = Editor.init(self.gpa) catch return self.sayOom();
        self.configureEditor(&ed);
        const doc = Doc.create(self.gpa, ed, .{}, null) catch {
            ed.deinit();
            return self.sayOom();
        };
        self.addDoc(doc) catch {
            doc.destroy(self.gpa);
            return self.sayOom();
        };
        self.focus = .text;
    }

    /// Opens a file in a tab. If it is already open, just switches there. With
    /// `allow_new` the file may not exist yet. If loading fails, everything stays
    /// as it was. From here on `path` belongs to iro.
    fn openPath(self: *App, path: []u8, allow_new: bool) void {
        const gpa = self.gpa;
        for (self.docs.items, 0..) |doc, i| {
            const other = doc.path orelse continue;
            if (std.mem.eql(u8, other, path)) {
                gpa.free(path);
                self.switchTo(i);
                self.focus = .text;
                return;
            }
        }
        const name = std.fs.path.basename(path);
        var is_new = false;
        var meta: fileio.Meta = .{};
        var ed: Editor = undefined;
        if (fileio.load(gpa, self.io, Io.Dir.cwd(), path)) |loaded| {
            ed = Editor.fromBuffer(gpa, loaded.buf);
            meta = loaded.meta;
        } else |err| {
            if (err == error.FileNotFound and allow_new) {
                is_new = true;
                ed = Editor.init(gpa) catch {
                    gpa.free(path);
                    return self.sayOom();
                };
            } else {
                defer gpa.free(path);
                return switch (err) {
                    error.NotUtf8 => self.say(true, "{s} ist keine Textdatei in UTF-8, bleibt zu", "{s} is not a UTF-8 text file, leaving it closed", .{name}),
                    error.FileTooBig => self.say(true, "{s} ist größer als 256 MB", "{s} is larger than 256 MB", .{name}),
                    error.IsDir => self.say(true, "{s} ist ein Ordner", "{s} is a folder", .{name}),
                    error.FileNotFound => self.say(true, "{s} gibt es nicht", "{s} does not exist", .{name}),
                    error.AccessDenied, error.PermissionDenied => self.say(true, "Keine Leserechte für {s}", "No read permission for {s}", .{name}),
                    else => self.say(true, "{s} lässt sich nicht öffnen ({s})", "{s} cannot be opened ({s})", .{ name, @errorName(err) }),
                };
            }
        }
        self.configureEditor(&ed);
        const doc = Doc.create(gpa, ed, meta, path) catch {
            ed.deinit();
            gpa.free(path);
            return self.sayOom();
        };
        self.addDoc(doc) catch {
            doc.destroy(gpa);
            return self.sayOom();
        };
        self.focus = .text;
        if (!is_new) self.rememberRecent(doc.path.?);
        if (is_new and self.prompt == null and self.msg_len == 0) self.say(false, "Neue Datei", "New file", .{});
    }

    /// Ctrl+W: close the tab, asking first if there are unsaved changes.
    fn requestClose(self: *App) void {
        if (self.d.ed.isModified()) return self.openPrompt(.confirm_close, "");
        self.closeCurrent();
    }

    /// Closes the front tab without asking. The last tab becomes an empty,
    /// unnamed file; iro stays open.
    fn closeCurrent(self: *App) void {
        const gpa = self.gpa;
        self.removeSwap(self.d);
        if (self.docs.items.len == 1) {
            var ed = Editor.init(gpa) catch return self.sayOom();
            self.configureEditor(&ed);
            const fresh = Doc.create(gpa, ed, .{}, null) catch {
                ed.deinit();
                return self.sayOom();
            };
            self.d.destroy(gpa);
            self.docs.items[0] = fresh;
        } else {
            const old = self.docs.orderedRemove(self.cur);
            old.destroy(gpa);
            if (self.cur >= self.docs.items.len) self.cur = self.docs.items.len - 1;
        }
        self.split_other_doc = @min(self.split_other_doc, self.docs.items.len - 1);
        self.msg_len = 0;
        self.activate();
    }

    /// Expands "~/…" to the path in the home directory.
    fn expandHome(self: *App, arena: Allocator, input: []const u8) []const u8 {
        if (!std.mem.startsWith(u8, input, "~/")) return input;
        const home = self.env.get("HOME") orelse return input;
        return std.fmt.allocPrint(arena, "{s}{s}", .{ home, input[1..] }) catch input;
    }

    // ───────────── File tree ─────────────

    fn treeFailed(self: *App, err: anyerror) void {
        switch (err) {
            error.AccessDenied, error.PermissionDenied => self.say(true, "Keine Leserechte für diesen Ordner", "No read permission for this folder", .{}),
            error.FileNotFound => self.say(true, "Den Ordner gibt es nicht (mehr)", "This folder does not exist (any more)", .{}),
            else => self.say(true, "Ordner lässt sich nicht lesen ({s})", "Folder cannot be read ({s})", .{@errorName(err)}),
        }
    }

    /// Reads the tree the first time. The root is the folder of the open file,
    /// or without a file, the folder iro was started in.
    fn ensureTree(self: *App) bool {
        if (self.tree != null) return true;
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root: []const u8 = if (self.start_dir) |d|
            d
        else if (self.d.path) |p|
            std.fs.path.dirname(p) orelse "/"
        else blk: {
            const n = Io.Dir.cwd().realPath(self.io, &buf) catch |err| {
                self.treeFailed(err);
                return false;
            };
            break :blk buf[0..n];
        };
        var t = Tree.init(self.gpa, self.io, root) catch |err| {
            self.treeFailed(err);
            return false;
        };
        if (!self.cfg.show_hidden) {
            t.show_hidden = false;
            t.refresh(self.io) catch {};
        }
        self.tree = t;
        return true;
    }

    /// Alt+G: switch to the other gear. Forge brings in the tree (sliding, if
    /// animations are on), Blade clears away everything but the text. The
    /// cursor stays in the text and the keys stay the same.
    fn shiftGear(self: *App, to: config.Gear) void {
        self.gear = to;
        self.minimap_forced = false;
        for (self.docs.items) |doc| {
            if (self.gitWanted() != (doc.git_base != null)) self.loadGitBase(doc);
        }
        switch (to) {
            .forge => {
                if (!self.tree_visible) self.toggleTree();
                self.focus = .text;
            },
            .blade => {
                self.tree_visible = false;
                self.tree_anim_w = 0;
                self.focus = .text;
            },
        }
        self.setMsg(false, "{s}", .{switch (to) {
            .blade => "Blade · Get in. Cut. Get out.",
            .forge => "Forge · Heat up. Hammer. Ship it.",
        }});
    }

    /// Automatic transmission: when a project feature (file tree, second tab,
    /// split view, file search) is used in Blade, iro shifts up to Forge on its
    /// own. It never shifts down automatically.
    fn upshiftToForge(self: *App) bool {
        if (self.gear == .forge or !self.cfg.auto_gear) return false;
        self.gear = .forge;
        self.minimap_forced = false;
        for (self.docs.items) |doc| {
            if (self.gitWanted() != (doc.git_base != null)) self.loadGitBase(doc);
        }
        if (self.msg_len == 0) {
            const k = self.cfg.keyLabel(.gear);
            if (k.len > 0) {
                self.say(false, "Forge — {s} zurück", "Forge — {s} back", .{k});
            } else {
                self.setMsg(false, "Forge · Heat up. Hammer. Ship it.", .{});
            }
        }
        return true;
    }

    /// Ctrl+B: show the tree and jump into it. Already inside: hide the tree.
    fn toggleTree(self: *App) void {
        self.msg_len = 0;
        if (self.tree_visible and self.focus == .tree) {
            self.tree_visible = false;
            self.tree_anim_w = 0;
            self.focus = .text;
            return;
        }
        const existed = self.tree != null;
        if (!self.ensureTree()) return;
        _ = self.upshiftToForge();
        const t = &self.tree.?;
        const opening = !self.tree_visible;
        // Reread when showing it again; something may have changed outside.
        if (existed and !self.tree_visible) t.refresh(self.io) catch {};
        if (!self.tree_visible) {
            if (self.d.path) |p| _ = t.selectPath(p);
        }
        self.tree_visible = true;
        if (opening and self.cfg.animations and self.term_bg != null) {
            self.tree_anim_w = 10;
        }
        self.focus = .tree;
        self.tree_follow = true;
    }

    /// Enter or click on an entry: toggle a folder, open a file.
    fn treeActivate(self: *App, index: usize) void {
        const t = &self.tree.?;
        if (index >= t.entries.items.len) return;
        if (t.entries.items[index].is_dir) {
            t.toggle(self.io, index) catch |err| self.treeFailed(err);
            return;
        }
        const path = t.pathOf(self.gpa, index) catch return self.sayOom();
        self.openPath(path, false);
    }

    fn treeUp(self: *App) void {
        const t = &self.tree.?;
        t.goUp(self.io) catch |err| return self.treeFailed(err);
        self.tree_top = 0;
        self.tree_follow = true;
    }

    // ───────────── Managing files in the tree ─────────────

    /// Is `path` exactly there or anywhere below?
    fn pathUnder(path: []const u8, base: []const u8) bool {
        if (!std.mem.startsWith(u8, path, base)) return false;
        // "/" (or a path ending in a slash) contains everything below it.
        if (base.len > 0 and base[base.len - 1] == '/') return true;
        return path.len == base.len or path[base.len] == '/';
    }

    /// Asks one of the four tree prompts: new file, new folder, rename, move to
    /// trash. Remembers what it is about.
    fn treeAsk(self: *App, kind: PromptKind) void {
        if (!self.ensureTree()) return;
        const gpa = self.gpa;
        const t = &self.tree.?;
        const has_sel = t.selected < t.entries.items.len;

        var target: []u8 = undefined;
        var initial: []const u8 = "";
        switch (kind) {
            .tree_new_file, .tree_new_dir => {
                // New items are created in the selected folder, otherwise next to the
                // selected file.
                const dir_index: ?usize = if (!has_sel)
                    null
                else if (t.entries.items[t.selected].is_dir)
                    t.selected
                else
                    t.parentOf(t.selected);
                target = (if (dir_index) |i| t.pathOf(gpa, i) else gpa.dupe(u8, t.root)) catch return self.sayOom();
            },
            else => {
                if (!has_sel) return self.say(false, "Im Baum ist nichts ausgewählt", "Nothing is selected in the tree", .{});
                target = t.pathOf(gpa, t.selected) catch return self.sayOom();
                if (kind == .tree_rename) initial = t.entries.items[t.selected].name;
            },
        }
        // First the input line (copies the name), then remember the target.
        self.openPrompt(kind, initial);
        if (self.tree_target) |old| gpa.free(old);
        self.tree_target = target;
    }

    /// Validates a typed name and builds the full path in `dir`. `null`: the
    /// name won't do; the message is already shown.
    fn treeNewPath(self: *App, dir: []const u8, typed: []const u8) ?[]u8 {
        const name = std.mem.trim(u8, typed, " ");
        if (name.len == 0) return null;
        if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            self.say(true, "Nur ein Name, kein Pfad", "Just a name, no path", .{});
            return null;
        }
        return std.fs.path.join(self.gpa, &.{ dir, name }) catch {
            self.sayOom();
            return null;
        };
    }

    /// After a change on disk: reread the tree, expand the folder and select
    /// the entry.
    fn treeReveal(self: *App, dir: []const u8, path: []const u8) void {
        const t = &self.tree.?;
        t.refresh(self.io) catch {};
        if (t.selectPath(dir)) t.expand(self.io, t.selected) catch {};
        _ = t.selectPath(path);
        self.tree_follow = true;
    }

    /// Enter in "New file" or "New folder".
    fn treeCreate(self: *App, make_dir: bool, typed: []const u8) void {
        const dir = self.tree_target orelse return;
        const path = self.treeNewPath(dir, typed) orelse return;
        const cwd = Io.Dir.cwd();
        const name = std.fs.path.basename(path);
        if (make_dir) {
            cwd.createDir(self.io, path, .default_dir) catch |err| {
                defer self.gpa.free(path);
                return switch (err) {
                    error.PathAlreadyExists => self.say(true, "{s} gibt es schon", "{s} already exists", .{name}),
                    error.AccessDenied, error.PermissionDenied => self.say(true, "Keine Schreibrechte in diesem Ordner", "No write permission in this folder", .{}),
                    else => self.say(true, "Ordner lässt sich nicht anlegen ({s})", "Folder cannot be created ({s})", .{@errorName(err)}),
                };
            };
        } else {
            // Never overwrite an existing file.
            const file = cwd.createFile(self.io, path, .{ .exclusive = true }) catch |err| {
                defer self.gpa.free(path);
                return switch (err) {
                    error.PathAlreadyExists => self.say(true, "{s} gibt es schon", "{s} already exists", .{name}),
                    error.AccessDenied, error.PermissionDenied => self.say(true, "Keine Schreibrechte in diesem Ordner", "No write permission in this folder", .{}),
                    else => self.say(true, "Datei lässt sich nicht anlegen ({s})", "File cannot be created ({s})", .{@errorName(err)}),
                };
            };
            file.close(self.io);
        }
        self.closePrompt();
        self.treeReveal(dir, path);
        if (make_dir) {
            self.say(false, "Ordner {s} angelegt", "Folder {s} created", .{name});
            self.gpa.free(path);
        } else {
            // The new file goes straight into a tab. From here on `path` belongs to
            // the tab.
            self.openPath(path, false);
        }
    }

    /// Enter in "Rename". Open tabs of the file (or of files in the renamed
    /// folder) move along.
    fn treeRename(self: *App, typed: []const u8) void {
        const gpa = self.gpa;
        const old = self.tree_target orelse return;
        const dir = std.fs.path.dirname(old) orelse "/";
        const new = self.treeNewPath(dir, typed) orelse return;
        defer gpa.free(new);
        if (std.mem.eql(u8, old, new)) return self.closePrompt();

        const cwd = Io.Dir.cwd();
        // Renaming would silently replace an existing target. That must not happen.
        if (cwd.access(self.io, new, .{})) |_| {
            return self.say(true, "{s} gibt es schon", "{s} already exists", .{std.fs.path.basename(new)});
        } else |_| {}
        Io.Dir.rename(cwd, old, cwd, new, self.io) catch |err| {
            return switch (err) {
                error.AccessDenied, error.PermissionDenied => self.say(true, "Keine Schreibrechte in diesem Ordner", "No write permission in this folder", .{}),
                else => self.say(true, "Umbenennen fehlgeschlagen ({s})", "Renaming failed ({s})", .{@errorName(err)}),
            };
        };
        self.closePrompt();

        const current = self.d;
        for (self.docs.items) |doc| {
            const p = doc.path orelse continue;
            if (!pathUnder(p, old)) continue;
            const moved = std.mem.concat(gpa, u8, &.{ new, p[old.len..] }) catch continue;
            // The backup is tied to the path: remove the old one, create a new one
            // under the new name.
            self.removeSwap(doc);
            gpa.free(p);
            doc.path = moved;
            self.d = doc;
            self.initSwapPath() catch {};
            self.detectLang();
            doc.swapped_rev = std.math.maxInt(u64);
        }
        self.d = current;
        self.updateTitle();
        self.treeReveal(dir, new);
        self.say(false, "Umbenannt in {s}", "Renamed to {s}", .{std.fs.path.basename(new)});
    }

    /// [Y]es at the trash prompt. The trash is the system's, the same as in
    /// Dolphin; everything can be restored from there.
    fn treeTrash(self: *App) void {
        const gpa = self.gpa;
        const path = self.tree_target orelse return;
        const name = std.fs.path.basename(path);
        const result = fileio.runHelper(
            gpa,
            self.io,
            &.{ "gio", "trash", "--", path },
            .limited(64 * 1024),
            .limited(64 * 1024),
        ) catch |err| return switch (err) {
            error.Timeout => self.say(true, "Papierkorb antwortet nicht (Zeitüberschreitung)", "Trash is not responding (timed out)", .{}),
            else => self.say(true, "Papierkorb nicht erreichbar: gio fehlt (Paket glib2)", "Trash not available: gio is missing (package glib2)", .{}),
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (!(result.term == .exited and result.term.exited == 0)) {
            // gio knows best what went wrong (e.g. a drive without trash).
            const why = std.mem.trim(u8, std.mem.sliceTo(result.stderr, '\n'), " ");
            return self.say(true, "Nicht im Papierkorb: {s}", "Not moved to trash: {s}", .{if (why.len > 0) why else self.pick("gio trash schlug fehl", "gio trash failed")});
        }

        // Close tabs of the trashed file. Tabs with unsaved changes stay open
        // so nothing is lost.
        const current = self.d;
        var kept: usize = 0;
        var i: usize = 0;
        while (i < self.docs.items.len) {
            const doc = self.docs.items[i];
            const hit = if (doc.path) |p| pathUnder(p, path) else false;
            if (!hit) {
                i += 1;
            } else if (doc.ed.isModified()) {
                kept += 1;
                i += 1;
            } else {
                self.cur = i;
                self.d = doc;
                self.closeCurrent();
                i = 0;
                kept = 0;
            }
        }
        for (self.docs.items, 0..) |doc, idx| {
            if (doc == current) {
                self.cur = idx;
                break;
            }
        }
        self.cur = @min(self.cur, self.docs.items.len - 1);
        self.activate();
        self.tree.?.refresh(self.io) catch {};
        if (kept > 0) {
            self.say(false, "{s} liegt im Papierkorb. Tab mit ungespeicherten Änderungen bleibt offen.", "{s} is in the trash. The tab with unsaved changes stays open.", .{name});
        } else {
            self.say(false, "{s} liegt im Papierkorb", "{s} is in the trash", .{name});
        }
    }

    fn treeKey(self: *App, key: Key) void {
        const t = &self.tree.?;
        const cp = key.codepoint;
        const n = t.entries.items.len;
        const page: isize = @intCast(@max(self.text_h, 3) - 2);
        self.msg_len = 0;
        self.tree_follow = true;

        switch (cp) {
            Key.up => t.moveSelection(-1),
            Key.down => t.moveSelection(1),
            Key.page_up => t.moveSelection(-page),
            Key.page_down => t.moveSelection(page),
            Key.home => t.selected = 0,
            Key.end => t.selected = n -| 1,
            Key.enter => self.treeActivate(t.selected),
            Key.right => if (n > 0) {
                const e = t.entries.items[t.selected];
                if (e.is_dir and !e.expanded) {
                    t.expand(self.io, t.selected) catch |err| self.treeFailed(err);
                } else if (e.is_dir) {
                    // Already open: step into the folder, if it contains
                    // anything.
                    if (t.selected + 1 < n and t.entries.items[t.selected + 1].depth > e.depth) t.selected += 1;
                }
            },
            Key.left => if (n > 0) {
                const e = t.entries.items[t.selected];
                if (e.is_dir and e.expanded) {
                    t.collapse(t.selected);
                } else if (t.parentOf(t.selected)) |parent| {
                    t.selected = parent;
                }
            },
            Key.backspace => self.treeUp(),
            Key.escape => self.focus = .text,
            else => {},
        }
    }

    /// Quit. Every tab with unsaved changes is brought to the front and asked
    /// about individually.
    fn requestQuit(self: *App) void {
        if (!self.d.ed.isModified()) {
            for (self.docs.items, 0..) |doc, i| {
                if (doc.ed.isModified()) {
                    self.switchTo(i);
                    break;
                }
            }
        }
        if (self.d.ed.isModified()) return self.openPrompt(.confirm_quit, "");
        for (self.docs.items) |doc| self.removeSwap(doc);
        self.should_quit = true;
    }

    // ───────────── Clipboard ─────────────

    fn copy(self: *App, cut: bool) void {
        const gpa = self.gpa;
        // Without a selection, the whole line under the cursor is meant.
        const whole_line = self.d.ed.selection() == null;
        const maybe: iro.editor.Error!?[]u8 = if (!whole_line)
            (if (cut) self.d.ed.cut(gpa) else self.d.ed.selectedText(gpa))
        else if (cut)
            self.d.ed.cutLine(gpa)
        else if (self.d.ed.lineText(gpa)) |t| t else |e| e;
        const txt = (maybe catch return self.sayOom()) orelse return;
        defer gpa.free(txt);
        self.clip_is_line = whole_line;
        if (whole_line) {
            self.setMsg(false, "{s}", .{if (cut) self.pick("Zeile ausgeschnitten", "Line cut") else self.pick("Zeile kopiert", "Line copied")});
            if (!cut) self.triggerFlash(self.d.ed.cursor.line);
        }
        self.clipboard.clearRetainingCapacity();
        self.clipboard.appendSlice(gpa, txt) catch {};
        // Also to the system clipboard (via the terminal).
        self.vx.copyToSystemClipboard(self.tty.writer(), txt, gpa) catch {};
    }

    /// Puts the selection into the system's primary selection (paste with
    /// middle click, in iro and any other program). The regular clipboard for
    /// Ctrl+V stays untouched, so selected text can still be replaced by
    /// pasting.
    fn copyPrimary(self: *App) void {
        const gpa = self.gpa;
        const txt = (self.d.ed.selectedText(gpa) catch return) orelse return;
        defer gpa.free(txt);
        if (txt.len > 1024 * 1024) return;
        const enc = std.base64.standard.Encoder;
        const buf = gpa.alloc(u8, enc.calcSize(txt.len)) catch return;
        defer gpa.free(buf);
        self.tty.writer().print("\x1b]52;p;{s}\x1b\\", .{enc.encode(buf, txt)}) catch {};
    }

    fn paste(self: *App, primary: bool) void {
        // Ask the system first (Wayland), otherwise use our own clipboard.
        const argv: []const []const u8 = if (primary)
            &.{ "wl-paste", "--primary", "--no-newline" }
        else
            &.{ "wl-paste", "--no-newline" };
        const result = fileio.runHelper(
            self.gpa,
            self.io,
            argv,
            .limited(64 * 1024 * 1024),
            .limited(64 * 1024),
        ) catch null;
        if (result) |r| {
            defer self.gpa.free(r.stdout);
            defer self.gpa.free(r.stderr);
            if (r.term == .exited and r.term.exited == 0 and r.stdout.len > 0) {
                // If the content comes from our own line cut, it is pasted back
                // as a whole line. Anything else goes to the cursor. The line
                // ending may get lost on the way, so the comparison ignores it,
                // and our own copy is inserted.
                const mine = self.clipboard.items;
                if (!primary and self.clip_is_line and
                    std.mem.eql(u8, std.mem.trimEnd(u8, r.stdout, "\n"), std.mem.trimEnd(u8, mine, "\n")))
                {
                    self.lineStart();
                    return self.insertPasted(mine);
                }
                return self.insertPasted(r.stdout);
            }
        }
        if (!primary and self.clipboard.items.len > 0) {
            self.lineStart();
            self.insertPasted(self.clipboard.items);
        }
    }

    /// Before pasting a whole line: cursor to the start of the line, so the
    /// line lands above instead of splitting the current one.
    fn lineStart(self: *App) void {
        if (!self.clip_is_line or self.d.ed.selection() != null) return;
        self.d.ed.setCursor(.{ .line = self.d.ed.cursor.line, .col = 0 }, false);
    }

    fn insertPasted(self: *App, txt: []const u8) void {
        if (self.locked()) return;
        self.d.ed.insertText(txt) catch |err| switch (err) {
            error.InvalidUtf8 => self.say(true, "Einfügen abgelehnt: Inhalt ist kein gültiger Text", "Paste refused: the content is not valid text", .{}),
            error.OutOfMemory => self.sayOom(),
        };
    }

    // ───────────── Command palette ─────────────

    /// Opens the search box and fills it according to its kind.
    fn openPalette(self: *App, mode: PaletteMode) void {
        self.closePalette();
        self.msg_len = 0;
        var pal: Palette = .{ .mode = mode, .arena = .init(self.gpa) };
        const arena = pal.arena.allocator();
        var list: std.ArrayList(PaletteItem) = .empty;

        switch (mode) {
            .commands => {
                for (config.cmd_specs) |spec| {
                    if (!spec.in_palette) continue;
                    var k = self.cfg.keyLabel(spec.cmd);
                    if (spec.cmd == .open_path and k.len == 0) {
                        const open_k = self.cfg.keyLabel(.open);
                        if (open_k.len > 0) k = std.fmt.allocPrint(arena, "{s}, Tab", .{open_k}) catch "";
                    }
                    list.append(arena, .{ .name = spec.name.in(self.lang), .key = k, .action = .{ .cmd = spec.cmd } }) catch break;
                }
                if (self.docs.items.len > 1) {
                    for (self.docs.items, 0..) |doc, i| {
                        const name = self.pickFmt(arena, "Gehe zu Tab: {s}", "Go to tab: {s}", .{doc.name(self.lang)});
                        const key = if (i < 9) std.fmt.allocPrint(arena, "Alt+{d}", .{i + 1}) catch "" else "";
                        list.append(arena, .{ .name = name, .key = key, .action = .{ .tab = i } }) catch break;
                    }
                }
            },
            .files => {
                if (!self.ensureTree()) return pal.arena.deinit();
                self.fileScopes(&pal, arena) catch return pal.arena.deinit();
                _ = self.upshiftToForge();
                self.palette = pal;
                self.enterScope(0);
                return;
            },
            .dirs => {
                const result = fileio.runHelper(
                    self.gpa,
                    self.io,
                    &.{ "zoxide", "query", "--list" },
                    .limited(4 * 1024 * 1024),
                    .limited(64 * 1024),
                ) catch {
                    pal.arena.deinit();
                    return self.say(true, "zoxide ist nicht installiert oder antwortet nicht", "zoxide is not installed or not responding", .{});
                };
                defer self.gpa.free(result.stdout);
                defer self.gpa.free(result.stderr);
                const home = self.env.get("HOME") orelse "";
                var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
                while (lines.next()) |line| {
                    if (!std.unicode.utf8ValidateSlice(line)) continue;
                    const dir = arena.dupe(u8, line) catch break;
                    // For display, the home directory is shortened to "~".
                    const name = if (home.len > 1 and std.mem.startsWith(u8, dir, home) and (dir.len == home.len or dir[home.len] == '/'))
                        std.fmt.allocPrint(arena, "~{s}", .{dir[home.len..]}) catch dir
                    else
                        dir;
                    list.append(arena, .{ .name = name, .action = .{ .dir = dir } }) catch break;
                }
                if (list.items.len == 0) {
                    pal.arena.deinit();
                    return self.say(false, "zoxide kennt noch keine Ordner", "zoxide does not know any folders yet", .{});
                }
            },
            .versions => if (!self.fillVersions(&list, arena)) return pal.arena.deinit(),
        }
        for (list.items, 0..) |*item, i| item.order = @intCast(i);
        pal.all = list.items;
        self.palette = pal;
    }

    /// Alt+R: earlier versions of the current file, newest first, each with
    /// how long ago it was written and how much differs from the text now.
    fn fillVersions(self: *App, list: *std.ArrayList(PaletteItem), arena: Allocator) bool {
        const path = self.d.path orelse {
            self.say(false, "Erst speichern: ohne Dateinamen gibt es keine Versionen", "Save first: without a file name there are no versions", .{});
            return false;
        };
        var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = self.statePath(&root_buf, "history") orelse return false;
        const versions = iro.history.list(arena, self.io, root, path) catch return false;
        if (versions.len == 0) {
            if (self.cfg.history) {
                self.say(false, "Von {s} gibt es noch keine früheren Versionen", "There are no earlier versions of {s} yet", .{self.d.name(self.lang)});
            } else {
                self.say(false, "Frühere Versionen sind ausgeschaltet (history = false)", "Earlier versions are switched off (history = false)", .{});
            }
            return false;
        }
        const now_text = self.d.ed.buf.toBytes(arena, "\n") catch return false;
        const now_lines = iro.gitdiff.splitLines(arena, now_text) catch return false;
        const now_ns = Io.Timestamp.now(self.io, .real).nanoseconds;
        for (versions) |v| {
            const raw = iro.history.read(arena, self.io, root, path, v) catch continue;
            const old_lines = iro.gitdiff.splitLines(arena, raw) catch continue;
            const marks = arena.alloc(iro.gitdiff.Mark, now_lines.len) catch continue;
            iro.gitdiff.marks(arena, old_lines, now_lines, marks) catch continue;
            var differ: usize = 0;
            for (marks) |m| {
                if (m != .none) differ += 1;
            }
            const ago = self.agoText(arena, now_ns - v.written_ns);
            const name = if (differ == 0)
                self.pickFmt(arena, "{s} · wie jetzt", "{s} · same as now", .{ago})
            else if (differ == 1)
                self.pickFmt(arena, "{s} · 1 Zeile anders", "{s} · 1 line differs", .{ago})
            else
                self.pickFmt(arena, "{s} · {d} Zeilen anders", "{s} · {d} lines differ", .{ ago, differ });
            list.append(arena, .{ .name = name, .action = .{ .version = v } }) catch break;
        }
        return list.items.len > 0;
    }

    /// Replaces the text with an earlier version, as one step that Ctrl+Z
    /// takes back. Nothing reaches the disk until the next save.
    fn restoreVersion(self: *App, v: iro.history.Version) void {
        if (self.locked()) return;
        const gpa = self.gpa;
        const path = self.d.path orelse return;
        var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = self.statePath(&root_buf, "history") orelse return;
        const raw = iro.history.read(gpa, self.io, root, path, v) catch |err| {
            return self.say(true, "Version lässt sich nicht lesen ({s})", "Cannot read that version ({s})", .{@errorName(err)});
        };
        defer gpa.free(raw);
        var loaded = fileio.decode(gpa, raw) catch {
            return self.say(true, "Diese Version ist kein Text in UTF-8", "That version is not UTF-8 text", .{});
        };
        defer loaded.buf.deinit();
        const txt = loaded.buf.toBytes(gpa, "\n") catch return self.sayOom();
        defer gpa.free(txt);

        const line = self.d.ed.cursor.line;
        self.d.ed.replaceText(txt) catch |err| switch (err) {
            error.InvalidUtf8 => return self.say(true, "Diese Version ist kein Text in UTF-8", "That version is not UTF-8 text", .{}),
            error.OutOfMemory => return self.sayOom(),
        };
        self.d.ed.setCursor(.{ .line = @min(line, self.d.ed.buf.lineCount() - 1) }, false);
        self.d.follow = true;
        const ago = self.agoText(self.frame.allocator(), Io.Timestamp.now(self.io, .real).nanoseconds - v.written_ns);
        self.say(false, "Stand von {s} zurückgeholt. {s} behält ihn, {s} nimmt ihn zurück.", "Brought back the state from {s}. {s} keeps it, {s} takes it back.", .{ ago, self.cfg.keyLabel(.save), self.cfg.keyLabel(.undo) });
    }

    // ───────────── Changes from outside ─────────────

    const Outside = enum { none, reloaded, conflict, gone, unreadable };
    const Reload = enum { same, replaced, failed };

    /// Has another program changed or removed `d`'s file? An untouched tab
    /// takes the new content as one undo step. A tab with unsaved work is
    /// left alone and only reported, once per change.
    fn checkOutside(self: *App, d: *Doc) Outside {
        const path = d.path orelse return .none;
        const known = d.meta.disk orelse return .none; // not on disk yet
        const now = fileio.diskState(self.io, Io.Dir.cwd(), path) orelse {
            if (d.gone_noted) return .none;
            d.gone_noted = true;
            return .gone;
        };
        d.gone_noted = false;
        if (std.meta.eql(now, known)) return .none;
        if (d.outside_seen) |seen| if (std.meta.eql(seen, now)) return .none;
        if (d.ed.isModified()) {
            d.outside_seen = now;
            return .conflict;
        }
        return switch (self.reloadDoc(d)) {
            .same => .none,
            .replaced => .reloaded,
            .failed => blk: {
                d.outside_seen = now;
                break :blk .unreadable;
            },
        };
    }

    /// Back in iro: looks at every tab's file once and says what matters most.
    /// Returns whether anything is worth a redraw.
    fn checkAllOutside(self: *App) bool {
        var reloaded: usize = 0;
        var last: ?*Doc = null;
        var alert: ?struct { kind: Outside, doc: *Doc } = null;
        for (self.docs.items) |d| {
            switch (self.checkOutside(d)) {
                .none => {},
                .reloaded => {
                    reloaded += 1;
                    last = d;
                },
                else => |k| if (alert == null or k == .conflict) {
                    alert = .{ .kind = k, .doc = d };
                },
            }
        }
        if (alert) |a| {
            self.sayOutside(a.kind, a.doc);
        } else if (reloaded == 1) {
            self.sayOutside(.reloaded, last.?);
        } else if (reloaded > 1) {
            self.say(false, "{d} Dateien von außen geändert, neu geladen", "{d} files changed outside iro, reloaded", .{reloaded});
        }
        return alert != null or reloaded > 0;
    }

    fn sayOutside(self: *App, kind: Outside, d: *Doc) void {
        const name = d.name(self.lang);
        switch (kind) {
            .none => {},
            .reloaded => if (d == self.d) {
                self.say(false, "{s} von außen geändert, neu geladen · {s} holt den alten Stand", "{s} changed outside iro, reloaded · {s} brings back the old text", .{ name, self.cfg.keyLabel(.undo) });
            } else {
                self.say(false, "{s} von außen geändert, neu geladen", "{s} changed outside iro, reloaded", .{name});
            },
            .conflict => self.say(true, "Achtung: {s} wurde auch von außen geändert. Beim Speichern fragt iro nach.", "Careful: {s} was also changed outside iro. iro asks when you save.", .{name}),
            .gone => self.say(true, "{s} gibt es nicht mehr auf der Platte. {s} legt die Datei neu an.", "{s} is gone from disk. {s} writes it again.", .{ name, self.cfg.keyLabel(.save) }),
            .unreadable => self.say(true, "{s} wurde von außen geändert, lässt sich aber nicht neu laden", "{s} changed outside iro but cannot be reloaded", .{name}),
        }
    }

    /// Replaces the text of `d` with the file on disk, as one undo step: Ctrl+Z
    /// brings back what was there before. Afterwards the tab counts as saved.
    fn reloadDoc(self: *App, d: *Doc) Reload {
        const gpa = self.gpa;
        const path = d.path orelse return .failed;
        var loaded = fileio.load(gpa, self.io, Io.Dir.cwd(), path) catch return .failed;
        defer loaded.buf.deinit();
        const txt = loaded.buf.toBytes(gpa, "\n") catch return .failed;
        defer gpa.free(txt);
        const mine = d.ed.buf.toBytes(gpa, "\n") catch return .failed;
        defer gpa.free(mine);

        d.outside_seen = null;
        if (std.mem.eql(u8, txt, mine)) {
            // Only the time stamp moved (touch, a save without changes).
            d.meta = loaded.meta;
            d.ed.markSaved();
            return .same;
        }
        const at = d.ed.cursor;
        d.ed.replaceText(txt) catch return .failed;
        d.ed.setCursor(at, false);
        d.ed.markSaved();
        d.meta = loaded.meta;
        self.loadGitBase(d);
        return .replaced;
    }

    /// "[L]oad" at the overwrite question: the file on disk wins. The unsaved
    /// text goes into the history first and stays one Ctrl+Z away anyway.
    fn loadOverMine(self: *App) void {
        const gpa = self.gpa;
        const d = self.d;
        const path = d.path orelse return;
        var kept = false;
        if (self.cfg.history) {
            var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            if (self.statePath(&root_buf, "history")) |root| {
                if (fileio.encode(gpa, &d.ed.buf, d.meta)) |bytes| {
                    defer gpa.free(bytes);
                    kept = iro.history.keepBytes(gpa, self.io, root, path, bytes) catch false;
                } else |_| {}
            }
        }
        switch (self.reloadDoc(d)) {
            .failed => self.say(true, "{s} lässt sich nicht laden", "{s} cannot be loaded", .{d.name(self.lang)}),
            .same => self.say(false, "Auf der Platte steht dasselbe wie bei dir", "The disk holds the same text as you", .{}),
            .replaced => if (kept) {
                self.say(false, "Neu geladen. Dein Stand: {s} oder {s}", "Reloaded. Your text: {s} or {s}", .{ self.cfg.keyLabel(.undo), self.cfg.keyLabel(.history) });
            } else {
                self.say(false, "Neu geladen. {s} holt deinen Stand zurück", "Reloaded. {s} brings your text back", .{self.cfg.keyLabel(.undo)});
            },
        }
    }

    // ───────────── File search: index, scopes, recent list ─────────────

    /// Which search scopes exist. First the project (git root), otherwise an
    /// explicitly chosen folder, then always the whole home.
    fn fileScopes(self: *App, pal: *Palette, arena: Allocator) !void {
        const home = self.env.get("HOME") orelse "/";
        const tree_root = self.tree.?.root;
        const file_dir: ?[]const u8 = if (self.d.path) |path| std.fs.path.dirname(path) else null;
        // An explicitly chosen folder (at start, via zoxide) applies as long as
        // the current file isn't elsewhere. Otherwise the folder of the current
        // file counts, or without a file, the tree's. If the file lies below
        // the tree's folder, the broader tree applies.
        const base: []const u8 = if (self.search_dir) |sd|
            (if (file_dir) |fd| (if (pathUnder(fd, sd)) sd else fd) else sd)
        else if (file_dir) |fd|
            (if (pathUnder(fd, tree_root)) tree_root else fd)
        else
            tree_root;
        const explicit = if (self.search_dir) |sd| std.mem.eql(u8, base, sd) else false;
        pal.near = "";
        pal.n_scopes = 0;
        if (iro.index.gitRoot(self.io, base)) |git| {
            pal.scopes[0] = .{ .root = try arena.dupe(u8, git), .kind = .project };
            pal.n_scopes = 1;
        } else if (explicit or !pathUnder(base, home)) {
            pal.scopes[0] = .{ .root = try arena.dupe(u8, base), .kind = .folder };
            pal.n_scopes = 1;
        }
        if (pal.n_scopes == 0 or !std.mem.eql(u8, pal.scopes[0].root, home)) {
            pal.scopes[pal.n_scopes] = .{ .root = try arena.dupe(u8, home), .kind = .home };
            pal.n_scopes += 1;
        }
        // For the proximity bonus: where is the current file?
        pal.here = try arena.dupe(u8, base);
    }

    /// Activate search scope `i`: fetch (or start) the index, convert the
    /// recent list and proximity to it.
    fn enterScope(self: *App, i: usize) void {
        const p = &(self.palette orelse return);
        if (p.n_scopes == 0) return;
        p.scope = i;
        const sc = p.scopes[i];
        const arena = p.arena.allocator();
        const here = p.here;
        const root = sc.root;
        p.idx = self.indexFor(root);
        p.hits_n = std.math.maxInt(usize);
        p.selected = 0;
        p.top = 0;
        p.stale = true;
        // Paths relative to the search scope.
        const prefix_len = std.mem.trimEnd(u8, root, "/").len + 1;
        var rel: std.ArrayList([]const u8) = .empty;
        for (self.recent.items) |r| {
            if (pathUnder(r, root) and r.len > prefix_len) rel.append(arena, r[prefix_len..]) catch break;
        }
        p.recent_rel = rel.items;
        p.near = if (pathUnder(here, root) and here.len > prefix_len) here[prefix_len..] else "";
        // Files are opened relative to the root of the search scope.
        p.base = root;
    }

    /// Fetch the index for `root` from the cache. If it is finished, a refresh
    /// starts in the background; if there is none, one is built.
    fn indexFor(self: *App, root: []const u8) ?*iro.index.Index {
        var found: ?usize = null;
        for (self.indexes, 0..) |slot, k| {
            if (slot) |idx| if (std.mem.eql(u8, idx.root, root)) {
                found = k;
            };
        }
        const notify: ?iro.index.Notify = if (self.loop) |l| .{ .ctx = l, .func = notifyIndex } else null;
        if (found) |k| {
            const idx = self.indexes[k].?;
            // Move to the front.
            var j = k;
            while (j > 0) : (j -= 1) self.indexes[j] = self.indexes[j - 1];
            self.indexes[0] = idx;
            if (idx.finished and self.refresh == null) {
                self.refresh = iro.index.Index.start(self.gpa, self.io, root, .{}, notify) catch null;
            }
            return idx;
        }
        const idx = iro.index.Index.start(self.gpa, self.io, root, .{}, notify) catch {
            self.say(true, "Zu wenig Speicher für die Dateisuche", "Not enough memory for the file search", .{});
            return null;
        };
        if (self.indexes[self.indexes.len - 1]) |old| old.deinit();
        var j: usize = self.indexes.len - 1;
        while (j > 0) : (j -= 1) self.indexes[j] = self.indexes[j - 1];
        self.indexes[0] = idx;
        return idx;
    }

    fn notifyIndex(ctx: *anyopaque) void {
        const loop: *Loop = @ptrCast(@alignCast(ctx));
        // Never block: if the mailbox is full, the next notification will come.
        _ = loop.tryPostEvent(.index_progress) catch {};
    }

    /// The index has reported: collect results, swap in a finished refresh.
    fn onIndexProgress(self: *App) void {
        var changed = false;
        for (self.indexes) |slot| if (slot) |idx| {
            if (idx.poll()) changed = true;
        };
        if (self.refresh) |r| {
            _ = r.poll();
            if (r.finished) {
                self.refresh = null;
                var replaced = false;
                for (&self.indexes) |*slot| if (slot.*) |old| if (std.mem.eql(u8, old.root, r.root)) {
                    if (self.palette) |*p| if (p.idx == old) {
                        p.idx = r;
                        p.hits_n = std.math.maxInt(usize);
                    };
                    old.deinit();
                    slot.* = r;
                    replaced = true;
                    changed = true;
                    break;
                };
                if (!replaced) r.deinit();
            }
        }
        if (changed) if (self.palette) |*p| {
            p.stale = true;
        };
    }

    /// File search matches as entries for the box. Recomputed only when the
    /// query or the index has changed; if the query just grew longer, only the
    /// previous matches qualify.
    fn fileItems(self: *App, p: *Palette) []PaletteItem {
        const idx = p.idx orelse return &.{};
        _ = idx.poll();
        const entries = idx.entries.items;
        const q = p.input.items;
        const same_idx = p.hits_idx == idx;
        const grown = entries.len != p.hits_n;
        const q_same = std.mem.eql(u8, q, p.hits_query.items);
        if (!p.stale and same_idx and !grown and q_same) return p.shown.items;
        // Don't recompute everything for every chunk while indexing.
        if (same_idx and grown and q_same and !idx.finished) {
            if (p.last_rank) |t| if (t.durationTo(Io.Timestamp.now(self.io, .awake)).toMilliseconds() < 120) return p.shown.items;
        }
        const narrow = same_idx and !grown and !p.typo and p.hits_query.items.len > 0 and
            q.len > p.hits_query.items.len and std.mem.startsWith(u8, q, p.hits_query.items);
        var subset: std.ArrayList(u32) = .empty;
        defer subset.deinit(self.gpa);
        if (narrow) {
            subset.ensureTotalCapacity(self.gpa, p.hits.items.len) catch {};
            for (p.hits.items) |h| subset.appendAssumeCapacity(h.index);
        }
        p.typo = iro.search.rank(self.gpa, self.io, entries, .{
            .needle = q,
            .recent = p.recent_rel,
            .near = p.near,
        }, if (narrow) subset.items else null, &p.hits) catch false;
        p.hits_query.clearRetainingCapacity();
        p.hits_query.appendSlice(self.gpa, q) catch {};
        p.hits_n = entries.len;
        p.hits_idx = idx;
        p.last_rank = Io.Timestamp.now(self.io, .awake);
        p.stale = false;

        p.shown.clearRetainingCapacity();
        for (p.hits.items[0..@min(p.hits.items.len, 500)]) |h| {
            const path = entries[h.index].path;
            p.shown.append(self.gpa, .{ .name = path, .score = h.score, .action = .{ .file = path } }) catch break;
        }
        return p.shown.items;
    }

    /// Remembers an opened file (newest first, at most 100) and writes the list
    /// to ~/.local/state/iro/zuletzt.
    fn rememberRecent(self: *App, path: []const u8) void {
        const gpa = self.gpa;
        for (self.recent.items, 0..) |r, i| {
            if (std.mem.eql(u8, r, path)) {
                const keep = self.recent.orderedRemove(i);
                self.recent.insert(gpa, 0, keep) catch gpa.free(keep);
                return self.saveRecent();
            }
        }
        const copy_path = gpa.dupe(u8, path) catch return;
        self.recent.insert(gpa, 0, copy_path) catch return gpa.free(copy_path);
        while (self.recent.items.len > 100) gpa.free(self.recent.pop().?);
        self.saveRecent();
    }

    fn saveRecent(self: *App) void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const file = self.statePath(&buf, "zuletzt") orelse return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        for (self.recent.items) |r| {
            out.appendSlice(self.gpa, r) catch return;
            out.append(self.gpa, '\n') catch return;
        }
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, std.fs.path.dirname(file) orelse return) catch return;
        fileio.writeAtomicMode(self.io, cwd, file, out.items, fileio.private_file) catch {};
    }

    fn loadRecent(self: *App) void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const file = self.statePath(&buf, "zuletzt") orelse return;
        const raw = Io.Dir.cwd().readFileAlloc(self.io, file, self.gpa, .limited(256 * 1024)) catch return;
        defer self.gpa.free(raw);
        var lines = std.mem.tokenizeScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            if (self.recent.items.len >= 100) break;
            if (line.len == 0 or line[0] != '/' or !std.unicode.utf8ValidateSlice(line)) continue;
            const copy_line = self.gpa.dupe(u8, line) catch return;
            self.recent.append(self.gpa, copy_line) catch return self.gpa.free(copy_line);
        }
    }

    fn closePalette(self: *App) void {
        if (self.palette) |*p| {
            p.input.deinit(self.gpa);
            p.shown.deinit(self.gpa);
            p.hits.deinit(self.gpa);
            p.hits_query.deinit(self.gpa);
            p.arena.deinit();
        }
        self.palette = null;
    }

    /// What the box shows for the current query, best first. Without a query
    /// everything appears in its original order. Recomputed only when the query
    /// has changed.
    pub fn paletteItems(self: *App) []PaletteItem {
        const p = &(self.palette orelse return &.{});
        if (p.mode == .files) return self.fileItems(p);
        if (!p.stale) return p.shown.items;
        p.shown.clearRetainingCapacity();
        for (p.all) |item| {
            const maybe = if (p.mode == .commands)
                iro.fuzzy.score(p.input.items, item.name)
            else
                iro.fuzzy.scorePath(p.input.items, item.name);
            const sc = maybe orelse continue;
            var scored = item;
            scored.score = sc;
            p.shown.append(self.gpa, scored) catch break;
        }
        std.mem.sortUnstable(PaletteItem, p.shown.items, {}, struct {
            fn better(_: void, a: PaletteItem, b: PaletteItem) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.order < b.order;
            }
        }.better);
        p.stale = false;
        return p.shown.items;
    }

    /// Enter in the search box: run the selected entry.
    fn runPaletteItem(self: *App, item: PaletteItem) void {
        const gpa = self.gpa;
        switch (item.action) {
            .cmd => |c| {
                self.closePalette();
                self.runCommand(c);
            },
            .tab => |i| {
                self.closePalette();
                self.switchTo(i);
            },
            .file => |rel| {
                // The path lives in the box's memory, so copy it first.
                const path = std.fs.path.join(gpa, &.{ self.palette.?.base, rel }) catch return;
                self.closePalette();
                self.openPath(path, false);
            },
            .dir => |d| {
                const dir = gpa.dupe(u8, d) catch return;
                defer gpa.free(dir);
                self.closePalette();
                if (!self.ensureTree()) return;
                self.tree.?.setRoot(self.io, dir) catch |err| return self.treeFailed(err);
                self.tree_top = 0;
                if (self.search_dir) |old| gpa.free(old);
                self.search_dir = gpa.dupe(u8, dir) catch null;
                // Jumping into a folder usually means wanting a file there.
                self.openPalette(.files);
            },
            .version => |v| {
                const name = gpa.dupe(u8, v.name) catch return self.sayOom();
                defer gpa.free(name);
                self.closePalette();
                self.restoreVersion(.{ .name = name, .written_ns = v.written_ns });
            },
        }
    }

    /// Switch from the search box to the input line to type a path.
    fn paletteToPathPrompt(self: *App, initial: []const u8) void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const start = if (initial.len > 0)
            initial
        else
            std.fmt.bufPrint(&buf, "{s}/", .{std.mem.trimEnd(u8, self.palette.?.base, "/")}) catch "";
        // First open the input line (copies the text), then close the box.
        self.openPrompt(.open, start);
        self.closePalette();
    }

    fn paletteKey(self: *App, key: Key) void {
        const cp = key.codepoint;
        const p = &self.palette.?;
        const items = self.paletteItems();
        const page: usize = @max(self.pal_box.rows, 1);

        if (cp == Key.escape or key.matches('p', .{ .ctrl = true })) return self.closePalette();
        if (cp == Key.enter) {
            if (p.selected >= items.len) return;
            return self.runPaletteItem(items[p.selected]);
        }
        // In file search, Tab leads to the input line for full paths.
        if (cp == Key.tab and p.mode == .files) return self.paletteToPathPrompt("");
        // Ctrl+O again: switch the search scope (project ↔ whole home).
        if (p.mode == .files) if (self.cfg.matchKey(key, false)) |c| if (c == .open) {
            return self.enterScope((p.scope + 1) % @max(p.n_scopes, 1));
        };
        switch (cp) {
            Key.up => p.selected -|= 1,
            Key.down => p.selected += 1,
            Key.page_up => p.selected -|= page,
            Key.page_down => p.selected += page,
            Key.home => p.selected = 0,
            Key.end => p.selected = items.len,
            Key.backspace => {
                if (key.mods.ctrl) {
                    p.input.clearRetainingCapacity();
                } else {
                    p.input.items.len = text.prevBoundary(p.input.items, p.input.items.len);
                }
                p.selected = 0;
                p.stale = true;
            },
            else => {
                if (key.mods.ctrl or key.mods.alt or key.mods.super) return;
                const t = key.text orelse return;
                // Starting with "/" or "~" means typing a path, not searching.
                if (p.mode == .files and p.input.items.len == 0 and (t[0] == '/' or t[0] == '~')) {
                    return self.paletteToPathPrompt(t);
                }
                p.input.appendSlice(self.gpa, t) catch return;
                p.selected = 0;
                p.stale = true;
            },
        }
        // The selection stays within the list, even if it just got shorter.
        p.selected = @min(p.selected, self.paletteItems().len -| 1);
    }

    /// Runs a command, whether by key or from the command palette.
    fn runCommand(self: *App, cmd: Cmd) void {
        const ed = &self.d.ed;
        self.msg_len = 0;
        self.d.follow = true;
        switch (cmd) {
            .save, .save_as, .undo, .redo, .cut, .paste, .replace, .comment, .duplicate_line, .line_up, .line_down => {
                if (self.locked()) return;
            },
            else => {},
        }
        switch (cmd) {
            .palette => self.openPalette(.commands),
            .save => self.save(.{}),
            .save_as => self.openPrompt(.save_as, self.d.path orelse ""),
            .history => self.openPalette(.versions),
            .open => self.openPalette(.files),
            .open_path => self.openOpenPrompt(),
            .jump_dir => self.openPalette(.dirs),
            .new_tab => self.newTab(),
            .close_tab => self.requestClose(),
            .next_tab => self.cycleTab(1),
            .prev_tab => self.cycleTab(-1),
            .search => self.openSearch(),
            .search_next => {
                self.show_hits = true;
                self.runSearch(true, false);
            },
            .goto_line => self.openPrompt(.goto_line, ""),
            .replace => {
                self.search_origin = if (ed.selection()) |sel| sel.start else ed.cursor;
                self.openReplace();
            },
            .comment => {
                const lang = self.d.lang orelse return self.say(false, "Für diese Datei kennt iro kein Kommentarzeichen", "iro knows no comment marker for this file", .{});
                if (lang.line_comments.len == 0) return self.say(false, "{s} hat keine Zeilenkommentare", "{s} has no line comments", .{lang.name});
                ed.toggleComment(lang.line_comments[0]) catch return self.sayOom();
            },
            .duplicate_line => {
                ed.duplicateLine() catch return self.sayOom();
                self.triggerFlash(ed.cursor.line);
            },
            .line_up => if (ed.moveLine(true) catch return self.sayOom()) {
                self.triggerFlash(ed.cursor.line);
            },
            .line_down => if (ed.moveLine(false) catch return self.sayOom()) {
                self.triggerFlash(ed.cursor.line);
            },
            .undo => {
                const did = ed.undo() catch return self.sayOom();
                if (!did) self.say(false, "Nichts rückgängig zu machen", "Nothing to undo", .{});
            },
            .redo => {
                const did = ed.redo() catch return self.sayOom();
                if (!did) self.say(false, "Nichts zu wiederholen", "Nothing to redo", .{});
            },
            .select_all => ed.selectAll(),
            .copy => self.copy(false),
            .cut => self.copy(true),
            .paste => self.paste(false),
            .doc_start => ed.moveDocStart(false),
            .doc_end => ed.moveDocEnd(false),
            .tree => self.toggleTree(),
            .tree_here => {
                const path = self.d.path orelse return self.say(false, "Diese Datei hat noch keinen Ordner", "This file has no folder yet", .{});
                const dir = std.fs.path.dirname(path) orelse "/";
                if (!self.ensureTree()) return;
                _ = self.upshiftToForge();
                const t = &self.tree.?;
                if (!std.mem.eql(u8, t.root, dir)) t.setRoot(self.io, dir) catch |err| return self.treeFailed(err);
                _ = t.selectPath(path);
                self.tree_visible = true;
                self.focus = .tree;
                self.tree_follow = true;
            },
            .tree_hidden => {
                if (!self.ensureTree()) return;
                const t = &self.tree.?;
                t.toggleHidden(self.io) catch |err| return self.treeFailed(err);
                self.setMsg(false, "{s}", .{if (t.show_hidden) self.pick("Punkt-Dateien sichtbar", "Dotfiles shown") else self.pick("Punkt-Dateien ausgeblendet", "Dotfiles hidden")});
            },
            .tree_refresh => {
                if (!self.ensureTree()) return;
                self.tree.?.refresh(self.io) catch |err| return self.treeFailed(err);
                self.say(false, "Dateibaum neu gelesen", "File tree reloaded", .{});
            },
            .tree_new_file, .tree_new_dir, .tree_rename, .tree_trash => {
                // The tree must be visible, otherwise nobody knows what this is
                // about.
                if (!self.ensureTree()) return;
                _ = self.upshiftToForge();
                self.tree_visible = true;
                self.focus = .tree;
                self.treeAsk(switch (cmd) {
                    .tree_new_file => .tree_new_file,
                    .tree_new_dir => .tree_new_dir,
                    .tree_rename => .tree_rename,
                    else => .confirm_trash,
                });
            },
            .minimap => {
                // What is visible gets toggled. In Blade the minimap is off
                // even if the config enables it.
                const shown = self.cfg.minimap and (self.gear == .forge or self.minimap_forced);
                self.cfg.minimap = !shown;
                self.minimap_forced = !shown;
                self.setMsg(false, "{s}", .{if (self.cfg.minimap) self.pick("Minimap eingeblendet", "Minimap shown") else self.pick("Minimap ausgeblendet", "Minimap hidden")});
            },
            .gear => self.shiftGear(if (self.gear == .blade) .forge else .blade),
            .complete => self.startComplete(),
            .wrap => {
                self.cfg.wrap = !self.cfg.wrap;
                self.d.left_col = 0;
                self.setMsg(false, "{s}", .{if (self.cfg.wrap) self.pick("Zeilenumbruch eingeschaltet", "Soft wrap on") else self.pick("Zeilenumbruch ausgeschaltet", "Soft wrap off")});
            },
            .split => self.toggleSplit(),
            .hints => self.toggleHints(),
            .settings => self.openSettings(),
            .open_config => self.openConfigFile(),
            .reload_config => self.loadConfig(true),
            .help => self.openHelp(),
            .menu => self.openMenu(),
            .about => self.openAbout(),
            .quit => self.requestQuit(),
        }
    }

    // ───────────── Main menu and About ─────────────

    /// Is a card (palette, menu, About) currently covering the text?
    pub fn overlayOpen(self: *const App) bool {
        return self.palette != null or self.menu_open or self.about != null or self.settings_open;
    }

    fn openMenu(self: *App) void {
        self.closeComp();
        self.focus = .text;
        self.menu_open = true;
        self.menu_sel = iro.menu.first();
    }

    fn closeMenu(self: *App) void {
        self.menu_open = false;
    }

    /// Close first, then run. That way the command itself can open a card or a
    /// prompt.
    fn runMenuItem(self: *App, index: usize) void {
        if (!iro.menu.isItem(index)) return;
        self.closeMenu();
        self.runCommand(iro.menu.entries[index].cmd.?);
    }

    fn menuKey(self: *App, key: Key) void {
        const cp = key.codepoint;
        const plain = !key.mods.ctrl and !key.mods.alt and !key.mods.super;
        switch (cp) {
            Key.escape, Key.f10 => return self.closeMenu(),
            Key.up => self.menu_sel = iro.menu.move(self.menu_sel, -1),
            Key.down => self.menu_sel = iro.menu.move(self.menu_sel, 1),
            Key.tab => self.menu_sel = iro.menu.move(self.menu_sel, if (key.mods.shift) -1 else 1),
            Key.home, Key.page_up => self.menu_sel = iro.menu.first(),
            Key.end, Key.page_down => self.menu_sel = iro.menu.last(),
            Key.enter, Key.space => if (plain) self.runMenuItem(self.menu_sel),
            else => {
                if (plain) {
                    if (iro.menu.byHotkey(cp, self.lang)) |i| return self.runMenuItem(i);
                }
                // Pressing Ctrl+S with the menu open means saving.
                if (self.cfg.matchKey(key, false)) |cmd| {
                    self.closeMenu();
                    if (cmd != .menu) self.runCommand(cmd);
                }
            },
        }
    }

    // ───────────── Settings page ─────────────

    fn openSettings(self: *App) void {
        self.closeComp();
        self.closeMenu();
        self.focus = .text;
        self.settings_open = true;
        self.set_capture = false;
        if (!iro.settings.selectable(self.set_sel)) self.set_sel = iro.settings.first();
    }

    fn closeSettings(self: *App) void {
        self.settings_open = false;
        self.set_capture = false;
    }

    /// Is the setting in init.lua? Then do nothing, just explain.
    fn settingPinned(self: *App, item: iro.settings.Item) bool {
        const pinned = if (item.cmd) |c| self.cfg.keyPinned(c) else self.cfg.isPinned(item.lua);
        if (pinned) self.say(false, "„{s}“ legt deine init.lua fest, dort ändern oder die Zeile löschen", "\"{s}\" is set in your init.lua, change it there or delete the line", .{item.label.in(self.lang)});
        return pinned;
    }

    /// Write the choices to gewaehlt.lua and reload everything immediately.
    fn commitChosen(self: *App, what: []const u8) void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = self.chosenPath(&buf) orelse return self.say(true, "Kein Config-Ordner gefunden", "No config folder found", .{});
        const txt = self.chosen.render(self.gpa) catch return self.sayOom();
        defer self.gpa.free(txt);
        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(self.io, dir) catch {};
        fileio.writeAtomic(self.io, cwd, path, txt) catch |err| {
            return self.say(true, "gewaehlt.lua nicht geschrieben ({s})", "gewaehlt.lua not written ({s})", .{@errorName(err)});
        };
        self.loadConfig(true);
        if (!self.msg_bad) self.setMsg(false, "{s}", .{what});
    }

    /// An entry was pressed or changed with ←/→.
    fn changeSetting(self: *App, index: usize, dir: isize) void {
        if (!iro.settings.selectable(index)) return;
        const item = iro.settings.items[index];
        const gpa = self.gpa;
        if (item.kind == .open_init) {
            self.closeSettings();
            return self.openConfigFile();
        }
        if (self.settingPinned(item)) return;
        var msg_buf: [160]u8 = undefined;
        switch (item.kind) {
            .toggle => {
                const now = !(self.cfg.boolPtr(item.lua) orelse return).*;
                var defaults: config.Config = .{};
                if (now == (defaults.boolPtr(item.lua) orelse return).*) {
                    self.chosen.unset(gpa, item.lua, false);
                } else self.chosen.set(gpa, item.lua, if (now) "true" else "false") catch return self.sayOom();
                self.commitChosen(self.tr(&msg_buf, "{s}: {s}", "{s}: {s}", .{ item.label.in(self.lang), if (now) (if (self.lang == .en) "on" else "an") else (if (self.lang == .en) "off" else "aus") }));
            },
            .theme => {
                const name = iro.settings.cycleTheme(self.cfg.theme_name, dir);
                if (std.mem.eql(u8, name, "terminal")) {
                    self.chosen.unset(gpa, item.lua, false);
                } else {
                    const lit = std.fmt.bufPrint(&msg_buf, "\"{s}\"", .{name}) catch return;
                    self.chosen.set(gpa, item.lua, lit) catch return self.sayOom();
                }
                self.commitChosen(self.tr(&msg_buf, "Farbsatz: {s}", "Color scheme: {s}", .{name}));
            },
            .tab_width => {
                const cur: isize = @intCast(self.cfg.tab_width);
                const now: usize = @intCast(@mod(cur - 1 + dir, 16) + 1);
                if (now == 4) {
                    self.chosen.unset(gpa, item.lua, false);
                } else {
                    const lit = std.fmt.bufPrint(&msg_buf, "{d}", .{now}) catch return;
                    self.chosen.set(gpa, item.lua, lit) catch return self.sayOom();
                }
                self.commitChosen(self.tr(&msg_buf, "Tab-Breite: {d}", "Tab width: {d}", .{now}));
            },
            .indent => {
                const now = iro.settings.cycleIndent(self.cfg.soft_tabs, dir);
                if (now) |v| {
                    self.chosen.set(gpa, item.lua, if (v) "true" else "false") catch return self.sayOom();
                } else self.chosen.unset(gpa, item.lua, false);
                // "Automatic" only takes effect again for freshly opened files.
                self.commitChosen(self.tr(&msg_buf, "Einrücken mit: {s}", "Indent with: {s}", .{iro.settings.indentName(now, self.lang)}));
            },
            .gear => {
                const now = iro.settings.cycleGear(self.cfg.gear, dir);
                if (now) |g| {
                    self.chosen.set(gpa, item.lua, iro.settings.gearLua(g)) catch return self.sayOom();
                } else self.chosen.unset(gpa, item.lua, false);
                // Applies from the next start; Alt+G switches right now.
                self.commitChosen(self.tr(&msg_buf, "Gear beim Start: {s} (jetzt wechseln: {s})", "Gear at startup: {s} (switch now: {s})", .{ iro.settings.gearName(now, self.lang), self.cfg.keyLabel(.gear) }));
            },
            .language => {
                const now = iro.settings.cycleLanguage(self.cfg.language, dir);
                if (now) |l| {
                    self.chosen.set(gpa, item.lua, iro.settings.languageLua(l)) catch return self.sayOom();
                } else self.chosen.unset(gpa, item.lua, false);
                // The message already in the new language, which applies
                // immediately.
                const will = now orelse self.sys_lang;
                const name = iro.settings.languageName(now, will);
                self.commitChosen(switch (will) {
                    .de => std.fmt.bufPrint(&msg_buf, "Sprache: {s}", .{name}) catch "",
                    .en => std.fmt.bufPrint(&msg_buf, "Language: {s}", .{name}) catch "",
                });
            },
            .key => {
                self.set_capture = true;
                self.say(false, "Drück die neue Taste für „{s}“ (Entf: keine Taste, Esc: abbrechen)", "Press the new key for \"{s}\" (Del: no key, Esc: cancel)", .{item.label.in(self.lang)});
            },
            .header, .open_init => {},
        }
    }

    /// Del: back to the default.
    fn resetSetting(self: *App, index: usize) void {
        if (!iro.settings.selectable(index)) return;
        const item = iro.settings.items[index];
        if (item.kind == .open_init) return;
        if (self.settingPinned(item)) return;
        const is_key = item.kind == .key;
        if (!self.chosen.has(item.lua, is_key)) return self.say(false, "„{s}“ steht schon auf der Vorgabe", "\"{s}\" is already at its default", .{item.label.in(self.lang)});
        self.chosen.unset(self.gpa, item.lua, is_key);
        var msg_buf: [160]u8 = undefined;
        self.commitChosen(self.tr(&msg_buf, "„{s}“ wieder auf der Vorgabe", "\"{s}\" back to its default", .{item.label.in(self.lang)}));
    }

    /// New key for a command. Empty `label`: no key.
    fn assignKey(self: *App, cmd: Cmd, label: []const u8) void {
        const gpa = self.gpa;
        const idx = @intFromEnum(cmd);
        const spec = config.cmd_specs[idx];
        var msg_buf: [200]u8 = undefined;
        const name = spec.name.in(self.lang);
        var msg: []const u8 = self.tr(&msg_buf, "„{s}“: keine Taste", "\"{s}\": no key", .{name});
        if (label.len > 0) {
            const kb = (config.KeyBind.parse(gpa, label) catch null) orelse return self.say(true, "Diese Taste kann iro nicht belegen", "iro can't bind this key", .{});
            defer kb.deinit(gpa);
            const shown = kb.labelIn(self.lang);
            msg = self.tr(&msg_buf, "„{s}“: {s}", "\"{s}\": {s}", .{ name, shown });
            // Who has the key already? A default makes way by itself, a chosen
            // binding is cleared, one from init.lua stays (then this key is not
            // available).
            for (config.cmd_specs, 0..) |other, j| {
                if (j == idx) continue;
                const ob = self.cfg.slots[j].bind orelse continue;
                if (!ob.eqlKey(kb)) continue;
                const a = spec.scope;
                const b = other.scope;
                if (!(a == .global or b == .global or a == b)) continue;
                if (self.cfg.pinned_keys[j]) {
                    return self.say(true, "{s} belegt deine init.lua schon für „{s}“", "Your init.lua already uses {s} for \"{s}\"", .{ shown, other.name.in(self.lang) });
                }
                if (self.chosen.has(other.lua_key, true)) self.chosen.setKey(gpa, other.lua_key, "") catch {};
                msg = self.tr(&msg_buf, "„{s}“: {s} (vorher bei „{s}“)", "\"{s}\": {s} (was on \"{s}\")", .{ name, shown, other.name.in(self.lang) });
            }
        }
        if (std.mem.eql(u8, label, spec.default_key)) {
            self.chosen.unset(gpa, spec.lua_key, true);
        } else self.chosen.setKey(gpa, spec.lua_key, label) catch return self.sayOom();
        self.commitChosen(msg);
    }

    fn settingsKey(self: *App, key: Key) void {
        const cp = key.codepoint;
        const S = iro.settings;
        if (self.set_capture) {
            self.set_capture = false;
            const cmd = S.items[self.set_sel].cmd orelse return;
            if (cp == Key.escape and !key.mods.ctrl and !key.mods.alt) return self.say(false, "Abgebrochen, die Taste bleibt", "Cancelled, the key stays", .{});
            if ((cp == Key.delete or cp == Key.backspace) and !key.mods.ctrl and !key.mods.alt and !key.mods.shift) return self.assignKey(cmd, "");
            const label = (config.labelForKey(self.gpa, key) catch null) orelse
                return self.say(true, "Diese Taste kann iro nicht belegen", "iro can't bind this key", .{});
            defer self.gpa.free(label);
            return self.assignKey(cmd, label);
        }
        switch (cp) {
            Key.escape => return self.closeSettings(),
            Key.up => self.set_sel = S.move(self.set_sel, -1),
            Key.down => self.set_sel = S.move(self.set_sel, 1),
            Key.tab => self.set_sel = S.move(self.set_sel, if (key.mods.shift) -1 else 1),
            Key.page_up => self.set_sel = S.move(self.set_sel, -10),
            Key.page_down => self.set_sel = S.move(self.set_sel, 10),
            Key.home => self.set_sel = S.first(),
            Key.end => self.set_sel = S.last(),
            Key.enter, Key.space => self.changeSetting(self.set_sel, 1),
            Key.right => self.changeSetting(self.set_sel, 1),
            Key.left => self.changeSetting(self.set_sel, -1),
            Key.delete, Key.backspace => self.resetSetting(self.set_sel),
            else => {
                if (self.cfg.matchKey(key, false)) |cmd| switch (cmd) {
                    .quit, .save, .settings, .menu => {
                        self.closeSettings();
                        if (cmd != .settings) self.runCommand(cmd);
                    },
                    else => {},
                };
            },
        }
    }

    fn openAbout(self: *App) void {
        self.closeComp();
        self.closeMenu();
        if (self.about) |*a| a.deinit(self.gpa);
        self.about = null;
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const ls = iro.about.lines(tmp.allocator(), version, self.lang) catch return self.sayOom();
        const now = Io.Timestamp.now(self.io, .awake);
        const seed: u64 = @truncate(@as(u96, @bitCast(@as(i96, now.nanoseconds))));
        self.about = iro.about.Reveal.init(self.gpa, iro.about.charCount(ls), seed, self.cfg.animations) catch
            return self.sayOom();
    }

    fn closeAbout(self: *App) void {
        if (self.about) |*a| a.deinit(self.gpa);
        self.about = null;
    }

    /// The first key during the reveal shows everything at once, the next one
    /// closes. If you just want to watch, wait.
    fn aboutPoke(self: *App) void {
        const a = &(self.about orelse return);
        if (a.done()) self.closeAbout() else a.finish();
    }

    // ───────────── Input line ─────────────

    fn openPrompt(self: *App, kind: PromptKind, initial: []const u8) void {
        self.closePrompt();
        var p: Prompt = .{ .kind = kind };
        p.input.appendSlice(self.gpa, initial) catch {};
        self.prompt = p;
        self.msg_len = 0;
    }

    fn closePrompt(self: *App) void {
        if (self.prompt) |*p| p.input.deinit(self.gpa);
        self.prompt = null;
        if (self.pending_save_as) |p| self.gpa.free(p);
        self.pending_save_as = null;
        if (self.guard_err) |e| self.gpa.free(e);
        self.guard_err = null;
        self.guard_tool = "";
    }

    // ───────────── Find and replace ─────────────

    fn openReplace(self: *App) void {
        var initial: []const u8 = self.last_search.items;
        var owned: ?[]u8 = null;
        defer if (owned) |o| self.gpa.free(o);
        if (self.d.ed.selection()) |s| {
            if (s.start.line == s.end.line) {
                owned = self.d.ed.selectedText(self.gpa) catch null;
                if (owned) |o| initial = o;
            }
        }
        self.openPrompt(.replace_find, initial);
    }

    /// Jumps to the next match from the cursor and asks whether to replace it.
    /// If there are none left, the round is over.
    fn replaceNext(self: *App) void {
        const ed = &self.d.ed;
        const hit = ed.findForward(self.replace_needle.items, ed.cursor) orelse return self.replaceDone();
        ed.selectRange(hit);
        self.d.follow = true;
        self.openPrompt(.confirm_each, "");
    }

    fn replaceDone(self: *App) void {
        self.closePrompt();
        self.d.ed.clearSelection();
        if (self.replace_count == 0) {
            self.say(false, "Nichts ersetzt", "Nothing replaced", .{});
        } else if (self.replace_count == 1) {
            self.say(false, "1 Stelle ersetzt", "1 match replaced", .{});
        } else {
            self.say(false, "{d} Stellen ersetzt", "{d} matches replaced", .{self.replace_count});
        }
    }

    /// Ctrl+O: input line for opening, prefilled with the folder of the current file.
    fn openOpenPrompt(self: *App) void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var initial: []const u8 = "";
        if (self.d.path) |p| {
            if (std.fs.path.dirname(p)) |dir| {
                initial = std.fmt.bufPrint(&buf, "{s}/", .{std.mem.trimEnd(u8, dir, "/")}) catch "";
            }
        }
        self.openPrompt(.open, initial);
    }

    fn openSearch(self: *App) void {
        self.search_origin = if (self.d.ed.selection()) |s| s.start else self.d.ed.cursor;
        var initial: []const u8 = self.last_search.items;
        // If part of a line is selected, it becomes the search term.
        var owned: ?[]u8 = null;
        defer if (owned) |o| self.gpa.free(o);
        if (self.d.ed.selection()) |s| {
            if (s.start.line == s.end.line) {
                owned = self.d.ed.selectedText(self.gpa) catch null;
                if (owned) |o| initial = o;
            }
        }
        self.openPrompt(.search, initial);
    }

    fn runSearch(self: *App, forward: bool, from_origin: bool) void {
        const needle = if (self.prompt) |p| p.input.items else self.last_search.items;
        if (needle.len == 0) return;
        if (from_origin) self.d.ed.setCursor(self.search_origin, false);
        if (self.d.ed.findAndSelect(needle, forward)) {
            self.msg_len = 0;
        } else {
            self.say(true, "Nicht gefunden: {s}", "Not found: {s}", .{needle});
        }
        self.d.follow = true;
    }

    fn rememberSearch(self: *App) void {
        const p = self.prompt orelse return;
        self.show_hits = true;
        self.last_search.clearRetainingCapacity();
        self.last_search.appendSlice(self.gpa, p.input.items) catch {};
    }

    /// Tab in the path input line: completes the typed name as far as it is
    /// unambiguous. With several matches they are shown next to it.
    fn completePrompt(self: *App) void {
        const gpa = self.gpa;
        const p = &self.prompt.?;
        const input = p.input.items;
        const cut = if (std.mem.lastIndexOfScalar(u8, input, '/')) |i| i + 1 else 0;
        const shown_dir = input[0..cut];
        const prefix = input[cut..];
        const real_dir = if (shown_dir.len == 0) "." else self.expandHome(self.frame.allocator(), shown_dir);

        var found = iro.finder.complete(gpa, self.io, real_dir, prefix) catch
            return self.say(true, "Diesen Ordner gibt es nicht", "This folder does not exist", .{});
        defer found.deinit(gpa);
        if (found.names.len == 0) return self.say(true, "Nichts, was so anfängt", "Nothing starts like that", .{});

        // Leave the folder part as typed (including "~").
        const dir_copy = gpa.dupe(u8, shown_dir) catch return;
        defer gpa.free(dir_copy);
        p.input.clearRetainingCapacity();
        p.input.appendSlice(gpa, dir_copy) catch return;
        p.input.appendSlice(gpa, found.common) catch return;
        if (found.names.len == 1) return;

        // Several options: show as many as fit on the line.
        var buf: [200]u8 = undefined;
        var len: usize = 0;
        var listed: usize = 0;
        for (found.names) |n| {
            if (len + n.len + 2 > buf.len) break;
            @memcpy(buf[len..][0..n.len], n);
            len += n.len;
            buf[len] = ' ';
            buf[len + 1] = ' ';
            len += 2;
            listed += 1;
        }
        if (listed < found.names.len) {
            self.say(false, "{s}… ({d} insgesamt)", "{s}… ({d} in total)", .{ buf[0..len], found.names.len });
        } else {
            self.setMsg(false, "{s}", .{buf[0..len]});
        }
    }

    fn promptKey(self: *App, key: Key) void {
        const kind = self.prompt.?.kind;
        const cp = key.codepoint;

        switch (kind) {
            .confirm_quit, .confirm_close => {
                const quit = kind == .confirm_quit;
                if (letter(key, 's') or self.yes(key)) {
                    self.closePrompt();
                    self.after_save = if (quit) .quit else .close;
                    self.save(.{});
                } else if (self.discard(key) or letter(key, 'n')) {
                    self.closePrompt();
                    if (quit and self.docs.items.len == 1) {
                        self.removeSwap(self.d);
                        self.should_quit = true;
                    } else {
                        // Tab gone; when quitting, continue with the next one.
                        self.closeCurrent();
                        if (quit) self.requestQuit();
                    }
                } else if (cp == Key.escape or letter(key, if (self.lang == .en) 'c' else 'a')) {
                    self.closePrompt();
                }
                return;
            },
            .confirm_trash => {
                if (self.yes(key)) {
                    self.closePrompt();
                    self.treeTrash();
                } else if (cp == Key.escape or letter(key, 'n') or letter(key, 'a')) {
                    self.closePrompt();
                }
                return;
            },
            .confirm_overwrite => {
                if (self.yes(key)) {
                    self.closePrompt();
                    // Overwriting is agreed; the Config Guard still has its say.
                    self.save(.{ .overwrite = true });
                } else if (letter(key, 'l')) {
                    self.closePrompt();
                    self.after_save = .stay;
                    self.loadOverMine();
                } else if (cp == Key.escape or letter(key, 'n')) {
                    self.closePrompt();
                    self.after_save = .stay;
                }
                return;
            },
            .confirm_guard => {
                if (self.yes(key)) {
                    const overwrite = self.guard_overwrite;
                    self.closePrompt();
                    self.save(.{ .overwrite = overwrite, .guard_ok = true });
                } else if (cp == Key.escape or letter(key, 'n') or letter(key, 'a')) {
                    self.closePrompt();
                    self.after_save = .stay;
                }
                return;
            },
            .recover => {
                if (letter(key, if (self.lang == .en) 'r' else 'w') or self.yes(key)) {
                    self.closePrompt();
                    if (self.d.recover_text) |t| {
                        self.d.ed.selectAll();
                        self.insertPasted(t);
                        self.d.ed.setCursor(.{}, false);
                        self.gpa.free(t);
                        self.d.recover_text = null;
                        self.say(false, "Wiederhergestellt. Mit {s} übernehmen, mit {s} verwerfen.", "Restored. {s} keeps it, {s} throws it away.", .{ self.cfg.keyLabel(.save), self.cfg.keyLabel(.undo) });
                    }
                } else if (self.discard(key) or letter(key, 'n')) {
                    self.closePrompt();
                    if (self.d.recover_text) |t| self.gpa.free(t);
                    self.d.recover_text = null;
                    self.removeSwap(self.d);
                }
                return;
            },
            .confirm_replace_file => {
                if (self.yes(key)) {
                    const path = self.pending_save_as orelse return self.closePrompt();
                    self.pending_save_as = null;
                    self.closePrompt();
                    self.saveAs(path);
                } else if (cp == Key.escape or letter(key, 'n') or letter(key, 'a')) {
                    self.closePrompt();
                    self.after_save = .stay;
                }
                return;
            },
            .confirm_each => {
                const ed = &self.d.ed;
                if (self.yes(key) or cp == Key.enter) {
                    self.insertPasted(self.replace_with.items);
                    self.replace_count += 1;
                    self.replaceNext();
                } else if (letter(key, 'n')) {
                    if (ed.selection()) |sel| ed.setCursor(sel.end, false);
                    self.replaceNext();
                } else if (letter(key, 'a')) {
                    const from = if (ed.selection()) |sel| sel.start else ed.cursor;
                    ed.clearSelection();
                    const n = ed.replaceFrom(self.replace_needle.items, self.replace_with.items, from) catch 0;
                    self.replace_count += n;
                    self.replaceDone();
                } else if (cp == Key.escape) {
                    self.replaceDone();
                }
                return;
            },
            .search, .save_as, .open, .goto_line, .tree_new_file, .tree_new_dir, .tree_rename, .replace_find, .replace_with => {},
        }

        const p = &self.prompt.?;
        if (cp == Key.escape) {
            if (kind == .search or kind == .replace_find) self.rememberSearch();
            self.after_save = .stay;
            return self.closePrompt();
        }
        if (cp == Key.enter) {
            switch (kind) {
                .search => {
                    self.rememberSearch();
                    self.runSearch(!key.mods.shift, false);
                },
                .tree_new_file => self.treeCreate(false, p.input.items),
                .tree_new_dir => self.treeCreate(true, p.input.items),
                .tree_rename => self.treeRename(p.input.items),
                .open => {
                    if (p.input.items.len == 0) return;
                    const typed = self.expandHome(self.frame.allocator(), p.input.items);
                    const resolved = resolvePath(self.gpa, self.io, typed) catch
                        return self.say(true, "Ungültiger Pfad", "Invalid path", .{});
                    self.closePrompt();
                    self.openPath(resolved, true);
                },
                .save_as => {
                    if (p.input.items.len == 0) return;
                    const typed = self.expandHome(self.frame.allocator(), p.input.items);
                    const resolved = resolvePath(self.gpa, self.io, typed) catch
                        return self.say(true, "Ungültiger Pfad", "Invalid path", .{});
                    for (self.docs.items) |doc| {
                        const other = doc.path orelse continue;
                        if (doc != self.d and std.mem.eql(u8, other, resolved)) {
                            self.gpa.free(resolved);
                            return self.say(true, "Diese Datei ist schon in einem anderen Tab offen", "This file is already open in another tab", .{});
                        }
                    }
                    const same = if (self.d.path) |old| std.mem.eql(u8, old, resolved) else false;
                    if (same) {
                        self.gpa.free(resolved);
                        self.closePrompt();
                        return self.save(.{ .overwrite = true });
                    }
                    // If something is already there, it is never silently
                    // replaced.
                    if (Io.Dir.cwd().access(self.io, resolved, .{})) |_| {
                        self.openPrompt(.confirm_replace_file, "");
                        self.pending_save_as = resolved;
                        return;
                    } else |_| {}
                    self.closePrompt();
                    self.saveAs(resolved);
                },
                .replace_find => {
                    if (p.input.items.len == 0) return;
                    self.replace_needle.clearRetainingCapacity();
                    self.replace_needle.appendSlice(self.gpa, p.input.items) catch return;
                    self.rememberSearch();
                    self.openPrompt(.replace_with, self.replace_with.items);
                },
                .replace_with => {
                    self.replace_with.clearRetainingCapacity();
                    self.replace_with.appendSlice(self.gpa, p.input.items) catch return;
                    self.closePrompt();
                    self.replace_count = 0;
                    // A selected match under the cursor counts too.
                    if (self.d.ed.selection()) |sel| self.d.ed.setCursor(sel.start, false);
                    self.replaceNext();
                },
                .goto_line => {
                    const n = std.fmt.parseInt(usize, std.mem.trim(u8, p.input.items, " "), 10) catch 0;
                    self.closePrompt();
                    if (n > 0) {
                        self.d.ed.setCursor(.{ .line = n - 1, .col = 0 }, false);
                        self.d.follow = true;
                        self.triggerFlash(self.d.ed.cursor.line);
                    }
                },
                else => {},
            }
            return;
        }
        if ((kind == .search or kind == .replace_find) and (cp == Key.down or cp == Key.f3 or cp == Key.up)) {
            self.rememberSearch();
            const forward = cp == Key.down or (cp == Key.f3 and !key.mods.shift);
            return self.runSearch(forward, false);
        }
        // Suggestions from the last completion disappear when you keep typing.
        if (kind != .search) self.msg_len = 0;
        if (cp == Key.tab and (kind == .open or kind == .save_as)) return self.completePrompt();
        if (cp == Key.backspace) {
            if (key.mods.ctrl) {
                p.input.clearRetainingCapacity();
            } else {
                p.input.items.len = text.prevBoundary(p.input.items, p.input.items.len);
            }
        } else if (key.text) |t| {
            if (key.mods.ctrl or key.mods.alt or key.mods.super) return;
            if (kind == .goto_line and !std.ascii.isDigit(t[0])) return;
            p.input.appendSlice(self.gpa, t) catch return;
        } else return;

        // Search updates while typing.
        if (kind == .search or kind == .replace_find) self.runSearch(true, true);
    }

    // ───────────── Completion and split view ─────────────

    pub fn closeComp(self: *App) void {
        self.comp_open = false;
        self.comp_sel = 0;
        self.comp_prefix_len = 0;
    }

    fn compPrefix(self: *const App) []const u8 {
        const ed = &self.d.ed;
        const l = ed.buf.line(ed.cursor.line);
        const allow_dash = if (self.d.lang) |lang| lang.dash_words else false;
        return iro.complete.wordPrefix(l, ed.cursor.col, allow_dash);
    }

    pub fn compItems(self: *App, arena: Allocator) []iro.complete.Candidate {
        const ed = &self.d.ed;
        const allow_dash = if (self.d.lang) |lang| lang.dash_words else false;
        const prefix = self.compPrefix();
        const keywords = if (self.d.lang) |lang| lang.keywords else &.{};
        return iro.complete.collect(arena, &ed.buf, ed.cursor, prefix, keywords, allow_dash, 8) catch &.{};
    }

    fn startComplete(self: *App) void {
        if (self.locked()) return;
        const prefix = self.compPrefix();
        if (prefix.len == 0) return self.say(false, "Tippe erst den Anfang eines Wortes", "Type the start of a word first", .{});
        const items = self.compItems(self.frame.allocator());
        if (items.len == 0) {
            self.closeComp();
            return self.say(false, "Keine passende Ergänzung gefunden", "No matching completion found", .{});
        }
        if (items.len == 1) {
            self.closeComp();
            self.d.ed.typeText(items[0].word[prefix.len..]) catch {};
            return;
        }
        self.comp_open = true;
        self.comp_sel = 0;
        self.comp_prefix_len = prefix.len;
    }

    fn acceptComplete(self: *App) void {
        const items = self.compItems(self.frame.allocator());
        const prefix = self.compPrefix();
        const idx = @min(self.comp_sel, items.len -| 1);
        self.closeComp();
        if (idx < items.len and items[idx].word.len > prefix.len) {
            self.d.ed.typeText(items[idx].word[prefix.len..]) catch {};
        }
    }

    fn refreshComp(self: *App) void {
        const prefix = self.compPrefix();
        if (prefix.len == 0 or self.compItems(self.frame.allocator()).len == 0) {
            self.closeComp();
        } else {
            self.comp_sel = 0;
            self.comp_prefix_len = prefix.len;
        }
    }

    fn toggleSplit(self: *App) void {
        self.split_on = !self.split_on;
        self.split_right_active = false;
        self.split_other_doc = if (self.docs.items.len > 1) (self.cur + 1) % self.docs.items.len else self.cur;
        self.split_other_top = self.docs.items[self.split_other_doc].top_line;
        if (self.split_on and self.upshiftToForge()) {
            const k = self.cfg.keyLabel(.gear);
            if (k.len > 0) {
                self.say(false, "Ansicht geteilt · Forge — {s} zurück", "View split · Forge — {s} back", .{k});
            } else {
                self.say(false, "Ansicht geteilt · Forge", "View split · Forge", .{});
            }
            return;
        }
        self.setMsg(false, "{s}", .{if (self.split_on) self.pick("Ansicht geteilt (Alt+Links/Rechts wechselt die Seite)", "View split (Alt+Left/Right switches sides)") else self.pick("Geteilte Ansicht geschlossen", "Split view closed")});
    }

    pub fn switchSplitSide(self: *App, to_right: bool) void {
        if (!self.split_on or self.split_right_active == to_right) return;
        const old_cur = self.cur;
        const old_top = self.d.top_line;
        const next_doc = @min(self.split_other_doc, self.docs.items.len - 1);
        const next_top = self.split_other_top;
        self.split_other_doc = old_cur;
        self.split_other_top = old_top;
        self.split_right_active = to_right;
        self.cur = next_doc;
        self.activate();
        self.d.top_line = @min(next_top, self.d.ed.buf.lineCount() - 1);
        self.d.follow = false;
        self.focus = .text;
        self.setMsg(false, "{s}", .{if (to_right) self.pick("Rechte Ansicht", "Right view") else self.pick("Linke Ansicht", "Left view")});
    }

    // ───────────── Keys ─────────────

    fn handleKey(self: *App, key: Key) void {
        const cp = key.codepoint;

        if (self.pasting) {
            // Pasted text arrives as a sequence of keys. We collect it and
            // insert it in one piece at the end (one undo step).
            const gpa = self.gpa;
            if (cp == Key.enter or (cp == 'j' and key.mods.ctrl)) {
                self.paste_buf.append(gpa, '\n') catch {};
            } else if (cp == Key.tab) {
                self.paste_buf.append(gpa, '\t') catch {};
            } else if (key.text) |t| {
                self.paste_buf.appendSlice(gpa, t) catch {};
            }
            return;
        }

        if (self.about != null) return self.aboutPoke();
        if (self.settings_open) return self.settingsKey(key);
        if (self.menu_open) return self.menuKey(key);
        if (self.palette != null) return self.paletteKey(key);
        if (self.prompt != null) return self.promptKey(key);

        if (self.comp_open) {
            if (cp == Key.down or (cp == Key.tab and !key.mods.shift) or (cp == 'n' and key.mods.ctrl)) {
                self.comp_sel += 1;
                return;
            }
            if (cp == Key.up or (cp == Key.tab and key.mods.shift) or (cp == 'p' and key.mods.ctrl)) {
                self.comp_sel -|= 1;
                return;
            }
            if (cp == Key.enter) return self.acceptComplete();
            if (cp == Key.escape) return self.closeComp();
        }

        // Some terminals send Ctrl+Space as NUL (0) or Ctrl+@ instead of Key.space+ctrl.
        if (self.focus == .text and (cp == 0 or (cp == '@' and key.mods.ctrl) or (cp == Key.space and (key.mods.ctrl or key.mods.alt)))) {
            return self.runCommand(.complete);
        }

        if (self.split_on and key.mods.alt and !key.mods.ctrl and !key.mods.shift) {
            if (cp == Key.left) return self.switchSplitSide(false);
            if (cp == Key.right) return self.switchSplitSide(true);
        }

        if (self.cfg.matchKey(key, self.focus == .tree)) |cmd| {
            self.closeComp();
            return self.runCommand(cmd);
        }

        if (key.mods.alt and !key.mods.ctrl and key.codepoint >= '1' and key.codepoint <= '9') {
            self.closeComp();
            const index: usize = key.codepoint - '1';
            if (index < self.docs.items.len) self.switchTo(index);
            return;
        }
        if (self.focus == .tree) return self.treeKey(key);

        self.msg_len = 0;
        self.d.follow = true;
        const ed = &self.d.ed;
        const shift = key.mods.shift;
        const ctrl = key.mods.ctrl;
        const page: isize = @intCast(@max(self.text_h, 2) - 1);

        const edits = switch (cp) {
            Key.enter, Key.tab, Key.backspace, Key.delete => true,
            Key.left, Key.right, Key.up, Key.down, Key.page_up, Key.page_down, Key.home, Key.end, Key.escape, Key.f3 => false,
            else => key.text != null and !ctrl and !key.mods.alt and !key.mods.super,
        };
        if (edits and self.locked()) return;

        const result: iro.editor.Error!void = blk: {
            switch (cp) {
                Key.left => {
                    self.closeComp();
                    if (ctrl) ed.moveWordLeft(shift) else ed.moveLeft(shift);
                },
                Key.right => {
                    self.closeComp();
                    if (ctrl) ed.moveWordRight(shift) else ed.moveRight(shift);
                },
                Key.up => ed.moveLines(-1, shift),
                Key.down => ed.moveLines(1, shift),
                Key.page_up => ed.moveLines(-page, shift),
                Key.page_down => ed.moveLines(page, shift),
                Key.home => if (ctrl) ed.moveDocStart(shift) else ed.moveHome(shift),
                Key.end => if (ctrl) ed.moveDocEnd(shift) else ed.moveEnd(shift),
                Key.enter => break :blk ed.newline(),
                // Tab indents several selected lines instead of replacing them.
                // Shift+Tab removes one level of indentation.
                Key.tab => break :blk if (shift) ed.dedentLines() else if (ed.selectionSpansLines()) ed.indentLines() else ed.tab(),
                Key.backspace => break :blk if (ctrl) ed.deleteWordBack() else ed.backspace(),
                Key.delete => break :blk if (ctrl) ed.deleteWordForward() else ed.deleteForward(),
                Key.escape => {
                    // If there is nothing to cancel, the main menu opens.
                    if (self.cfg.esc_menu and ed.selection() == null and !self.show_hits and !self.comp_open) {
                        return self.openMenu();
                    }
                    ed.clearSelection();
                    self.show_hits = false;
                },
                Key.f3 => if (shift) self.runSearch(false, false),
                else => {
                    if (ctrl or key.mods.alt or key.mods.super) return;
                    if (key.text) |t| break :blk ed.typeText(t);
                },
            }
            if (self.comp_open) self.closeComp();
            return;
        };
        result catch |err| switch (err) {
            error.OutOfMemory => self.say(true, "Zu wenig Speicher, Befehl nicht ausgeführt", "Not enough memory, command not run", .{}),
            error.InvalidUtf8 => {},
        };
        if (self.comp_open) self.refreshComp();
    }

    // ───────────── Mouse ─────────────

    /// Converts a screen cell into a text position.
    fn posAt(self: *const App, col: i32, row: i32) Pos {
        const r: usize = @intCast(std.math.clamp(row, 0, @as(i32, @intCast(self.text_h)) - 1));
        const x: usize = @intCast(@max(col - @as(i32, @intCast(self.split_x + self.gutter_w)), 0));
        if (self.cfg.wrap and self.text_w >= 8) {
            var row_acc: usize = 0;
            var line = self.d.top_line;
            const total = self.d.ed.buf.lineCount();
            while (line < total) : (line += 1) {
                const cur_c: ?usize = if (line == self.d.ed.cursor.line) self.d.ed.cursor.col else null;
                const l = self.d.ed.buf.line(line);
                const rows = draw_mod.wrappedLineRows(l, self.d.ed.tab_width, self.text_w, cur_c);
                if (r < row_acc + rows) {
                    const seg = r - row_acc;
                    const target_dcol = seg * self.text_w + if (seg + 1 < rows) @min(x, self.text_w - 1) else x;
                    return .{ .line = line, .col = text.colAtDisplay(l, target_dcol, self.d.ed.tab_width) };
                }
                row_acc += rows;
            }
            const last = total - 1;
            return .{ .line = last, .col = self.d.ed.buf.line(last).len };
        }
        const line = @min(self.d.top_line + r, self.d.ed.buf.lineCount() - 1);
        const l = self.d.ed.buf.line(line);
        return .{ .line = line, .col = text.colAtDisplay(l, x + self.d.left_col, self.d.ed.tab_width) };
    }

    fn handleMouse(self: *App, raw: vaxis.Mouse) void {
        if (self.prompt != null and self.palette == null) return;
        var m = self.vx.translateMouse(raw);
        const ed = &self.d.ed;

        // About: a click acts like a key.
        if (self.about != null) {
            if (m.type == .press and (m.button == .left or m.button == .right)) self.aboutPoke();
            return;
        }

        // Settings page: hover selects, click toggles (right click: backwards),
        // wheel scrolls, clicking outside closes.
        if (self.settings_open) {
            const b = self.set_box;
            const in_card = m.col >= b.x0 and m.col < b.x1 and m.row >= b.y0 and m.row < b.y1;
            const in_list = in_card and m.row >= b.list_y and m.row < b.list_y + b.list_h;
            const idx: usize = if (in_list) self.set_top + @as(usize, @intCast(m.row - @as(i32, b.list_y))) else 0;
            switch (m.button) {
                .wheel_up => self.set_top -|= 3,
                .wheel_down => self.set_top += 3,
                else => {
                    if (m.type == .press and self.set_capture) {
                        self.set_capture = false;
                        return self.say(false, "Abgebrochen, die Taste bleibt", "Cancelled, the key stays", .{});
                    }
                    if (in_list and iro.settings.selectable(idx)) {
                        if (m.type == .motion) self.set_sel = idx;
                        if (m.type == .press and (m.button == .left or m.button == .right)) {
                            self.set_sel = idx;
                            return self.changeSetting(idx, if (m.button == .right) -1 else 1);
                        }
                    }
                    if (m.type == .press and !in_card) self.closeSettings();
                },
            }
            return;
        }

        // Main menu: hover selects, click runs, clicking outside closes.
        if (self.menu_open) {
            const b = self.menu_box;
            const in_card = m.col >= b.x0 and m.col < b.x1 and m.row >= b.y0 and m.row < b.y1;
            const idx: ?usize = if (in_card and m.row >= b.first_row and m.row < b.first_row + iro.menu.entries.len)
                @intCast(m.row - @as(i32, b.first_row))
            else
                null;
            switch (m.button) {
                .wheel_up => self.menu_sel = iro.menu.move(self.menu_sel, -1),
                .wheel_down => self.menu_sel = iro.menu.move(self.menu_sel, 1),
                else => {
                    if (idx) |i| if (iro.menu.isItem(i)) {
                        if (m.type == .motion) self.menu_sel = i;
                        if (m.type == .press and m.button == .left) return self.runMenuItem(i);
                    };
                    if (m.type == .press and !in_card) self.closeMenu();
                },
            }
            return;
        }

        // Open palette: hover selects, clicking an entry runs it, clicking
        // outside the card closes it, the wheel moves the selection.
        if (self.palette) |*p| {
            const box = self.pal_box;
            const in_card = m.col >= box.x0 and m.col < box.x1 and m.row >= box.y0 and m.row < box.y1;
            const in_list = m.col >= box.x and m.col < box.x + box.w and m.row >= box.y and m.row < box.y + box.rows;
            switch (m.button) {
                .wheel_up => p.selected -|= 1,
                .wheel_down => p.selected = @min(p.selected + 1, self.paletteItems().len -| 1),
                else => {
                    if (in_list) {
                        const target = p.top + @as(usize, @intCast(m.row - @as(i32, box.y)));
                        if (m.type == .motion) p.selected = target;
                        if (m.type == .press and m.button == .left) {
                            p.selected = target;
                            return self.paletteKey(.{ .codepoint = Key.enter });
                        }
                    } else if (m.type == .press and !in_card) {
                        self.closePalette();
                    }
                },
            }
            return;
        }

        // Tab bar: left click brings the tab to the front, middle click closes it.
        if (m.row >= 0 and m.row < self.tabs_h) {
            if (m.type != .press or (m.button != .left and m.button != .middle)) return;
            for (self.tab_spans) |span| {
                if (m.col >= span.x0 and m.col < span.x1) {
                    self.switchTo(span.index);
                    if (m.button == .middle) self.requestClose();
                    break;
                }
            }
            return;
        }
        // From here on, rows count below the tab bar.
        m.row -= @intCast(self.tabs_h);
        const in_tree = self.tree_w > 0 and m.col >= 0 and m.col < self.tree_w and m.row >= 0 and m.row < self.text_h;

        if (in_tree) {
            const t = &self.tree.?;
            switch (m.button) {
                .wheel_up => {
                    self.tree_top -|= wheel_lines;
                    self.tree_follow = false;
                    return;
                },
                .wheel_down => {
                    self.tree_top += wheel_lines;
                    self.tree_follow = false;
                    return;
                },
                else => {},
            }
            // Dragging and releasing belong to a selection in the text and
            // continue below. Only a fresh click means the tree.
            if (m.type == .press) {
                if (m.button != .left) return;
                self.dragging = false;
                self.focus = .tree;
                self.msg_len = 0;
                self.tree_follow = true;
                // The top row is the folder name: clicking it goes up one level.
                if (m.row == 0) return self.treeUp();
                const index = self.tree_top + @as(usize, @intCast(m.row)) - 1;
                if (index < t.entries.items.len) {
                    t.selected = index;
                    self.treeActivate(index);
                }
                return;
            }
        }

        switch (m.button) {
            .wheel_up => {
                self.d.top_line -|= wheel_lines;
                self.d.follow = false;
                return;
            },
            .wheel_down => {
                const max_top = ed.buf.lineCount() -| 1;
                self.d.top_line = @min(self.d.top_line + wheel_lines, max_top);
                self.d.follow = false;
                return;
            },
            else => {},
        }

        const in_text = m.row >= 0 and m.row < self.text_h;
        if (m.type == .release) {
            self.scroll_drag = false;
            self.minimap_drag = false;
        }
        if (self.split_div_col > 0 and in_text and m.type == .press and m.button == .left and m.col >= @as(i32, @intCast(self.tree_w))) {
            const div: i32 = @intCast(self.split_div_col);
            if (self.split_right_active and m.col < div) {
                self.switchSplitSide(false);
                return;
            }
            if (!self.split_right_active and m.col > div) {
                self.switchSplitSide(true);
                return;
            }
            if (m.col == div) return;
        }
        // Minimap: click centres the viewport on that spot, dragging scrolls along.
        const map_col: i32 = @intCast(self.split_x + self.gutter_w + self.text_w);
        const map_end: i32 = map_col + @as(i32, @intCast(self.minimap_w));
        const on_map = self.minimap_w > 0 and in_text and m.col >= map_col and m.col < map_end and m.type == .press and m.button == .left;
        if (on_map or (self.minimap_drag and m.type == .drag)) {
            self.minimap_drag = true;
            self.dragging = false;
            self.scroll_drag = false;
            const r: usize = @intCast(std.math.clamp(m.row, 0, @as(i32, @intCast(self.text_h)) - 1));
            self.d.top_line = iro.minimap.targetTopLine(r, self.text_h, ed.buf.lineCount());
            self.d.follow = false;
            return;
        }
        // Scrollbar: click jumps there, dragging scrolls along.
        const bar_col: i32 = map_end;
        const on_bar = self.scroll_w > 0 and in_text and m.col == bar_col and m.type == .press and m.button == .left;
        if (on_bar or (self.scroll_drag and m.type == .drag)) {
            self.scroll_drag = true;
            self.dragging = false;
            const r: usize = @intCast(std.math.clamp(m.row, 0, @as(i32, @intCast(self.text_h)) - 1));
            const n = ed.buf.lineCount();
            self.d.top_line = @min(r * n / @max(self.text_h, 1), n -| 1);
            self.d.follow = false;
            return;
        }
        switch (m.type) {
            .press => {
                if (!in_text) return;
                if (m.button == .middle) {
                    // Middle click pastes the primary selection at the click
                    // position.
                    self.focus = .text;
                    ed.setCursor(self.posAt(m.col, m.row), false);
                    self.paste(true);
                    self.d.follow = true;
                    return;
                }
                if (m.button != .left) return;
                self.focus = .text;
                const p = self.posAt(m.col, m.row);
                const now = Io.Timestamp.now(self.io, .awake);
                var count: u8 = 1;
                if (self.last_click) |lc| {
                    const ms = lc.at.durationTo(now).toMilliseconds();
                    if (ms < 400 and lc.pos.eql(p)) count = if (lc.count >= 3) 1 else lc.count + 1;
                }
                self.last_click = .{ .at = now, .pos = p, .count = count };
                switch (count) {
                    1 => {
                        ed.setCursor(p, m.mods.shift);
                        self.dragging = true;
                    },
                    2 => {
                        ed.selectWordAt(p);
                        self.copyPrimary();
                    },
                    else => {
                        ed.selectLineAt(p);
                        self.copyPrimary();
                    },
                }
                self.msg_len = 0;
                self.d.follow = true;
            },
            .drag => {
                if (!self.dragging) return;
                ed.setCursor(self.posAt(m.col, m.row), true);
                self.d.follow = true;
            },
            .release => {
                // Mouse released: copy the fresh selection right away.
                if (self.dragging) self.copyPrimary();
                self.dragging = false;
            },
            .motion => {},
        }
    }
};

/// Turns a path argument into a full path, even if the file doesn't exist yet.
fn resolvePath(gpa: Allocator, io: Io, arg: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (cwd.realPathFile(io, arg, &buf)) |n| return gpa.dupe(u8, buf[0..n]) else |_| {}
    if (std.fs.path.isAbsolute(arg)) return gpa.dupe(u8, arg);
    const n = try cwd.realPath(io, &buf);
    return std.fs.path.join(gpa, &.{ buf[0..n], arg });
}

fn colorTicker(loop: *Loop, io: Io) void {
    while (true) {
        io.sleep(.fromSeconds(10), .awake) catch return;
        loop.postEvent(.color_tick) catch return;
    }
}

fn swapTimer(loop: *Loop, io: Io) void {
    io.sleep(.fromSeconds(2), .awake) catch return;
    loop.postEvent(.tick) catch {};
}

/// Starts the recovery timer once a tab holds a change its recovery file
/// doesn't know yet. With nothing unsaved, there is nothing to wake up for.
fn armSwapTimer(app: *App, timers: *Io.Group, loop: *Loop, io: Io) void {
    if (app.swap_armed) return;
    for (app.docs.items) |doc| {
        if (!App.swapDue(doc)) continue;
        timers.concurrent(io, swapTimer, .{ loop, io }) catch {
            // No thread to wait with: back up right away instead.
            for (app.docs.items) |d| app.writeSwap(d);
            return;
        };
        app.swap_armed = true;
        return;
    }
}

const usage_de =
    \\iro (色 · Instant · Riced · Operator) – Terminal-Editor von Mausmann
    \\
    \\Aufruf:  iro [DATEI ...] [ORDNER]
    \\
    \\  Strg+S  speichern          Strg+Z  rückgängig
    \\  Strg+Q  beenden            Strg+Y  wiederholen
    \\  Strg+F  suchen (F3 weiter) Strg+G  gehe zu Zeile
    \\  Strg+C/X/V  kopieren, ausschneiden, einfügen
    \\              (ohne Markierung: die ganze Zeile)
    \\  Strg+A  alles markieren    Shift+Pfeile  markieren
    \\  Strg+R  suchen und ersetzen (jede Stelle einzeln oder alle)
    \\  Strg+K  Kommentar ein/aus      Strg+D  Zeile verdoppeln
    \\  Alt+Hoch/Runter  Zeile verschieben
    \\  Tab / Shift+Tab  markierte Zeilen ein- und ausrücken
    \\  F12     speichern unter neuem Namen
    \\  Strg+B  Dateibaum holen, nochmal: Baum weg (Esc: zurück zum Text)
    \\          im Baum: N neue Datei, O neuer Ordner, F2 umbenennen,
    \\          Entf legt in den Papierkorb (derselbe wie in Dolphin)
    \\
    \\  Strg+P  Befehlspalette: alle Befehle zum Suchen und Auswählen
    \\  Alt+H   Hilfe: alle Tasten und Zeichen kurz erklärt
    \\  Esc/F10 Hauptmenü (Esc nur, wenn nichts aufzuheben ist)
    \\  F9      Über iro
    \\  F1      Hinweisleiste aus/ein (die Wahl wird gemerkt)
    \\  Alt+G   Gear wechseln: Blade (nur Text) ⇄ Forge (Baum, Minimap, Git)
    \\  Alt+M   Minimap rechts aus/ein
    \\  Alt+W   Zeilenumbruch (Soft-Wrap) ein/aus
    \\  Alt+V   Ansicht teilen (Alt+Links/Rechts wechselt die Seite)
    \\  Strg+Leer / Alt+Leer  Wort vervollständigen
    \\
    \\  Strg+O  Datei suchen und öffnen (Tab oder "/": Pfad eintippen,
    \\          dort ergänzt Tab den angefangenen Namen)
    \\  Alt+Z   in einen Ordner aus zoxide springen
    \\
    \\  Tabs:   Strg+N neu     Strg+W schließen
    \\          Strg+Bild auf/ab wechseln        Alt+1…9 direkt
    \\
    \\  --blade    in Blade starten (sonst: Datei → Blade, Ordner → Forge)
    \\  --forge    in Forge starten
    \\  --version  Version anzeigen
    \\  --help     diese Hilfe
    \\
    \\Copyright (C) 2026 Mausmann · Lizenz: GNU GPL v3+ (siehe LICENSE)
    \\
;

const usage_en =
    \\iro (色 · Instant · Riced · Operator) – terminal editor by Mausmann
    \\
    \\Usage:  iro [FILE ...] [FOLDER]
    \\
    \\  Ctrl+S  save               Ctrl+Z  undo
    \\  Ctrl+Q  quit               Ctrl+Y  redo
    \\  Ctrl+F  find (F3 next)     Ctrl+G  go to line
    \\  Ctrl+C/X/V  copy, cut, paste
    \\              (without a selection: the whole line)
    \\  Ctrl+A  select all         Shift+Arrows  select
    \\  Ctrl+R  find and replace (one by one or all at once)
    \\  Ctrl+K  toggle comment         Ctrl+D  duplicate line
    \\  Alt+Up/Down  move line
    \\  Tab / Shift+Tab  indent / outdent selected lines
    \\  F12     save under a new name
    \\  Ctrl+B  show the file tree, again: hide it (Esc: back to the text)
    \\          in the tree: N new file, O new folder, F2 rename,
    \\          Del moves to the trash (the same one Dolphin uses)
    \\
    \\  Ctrl+P  command palette: every command, searchable
    \\  Alt+H   help: every key and mark explained
    \\  Esc/F10 main menu (Esc only when there's nothing to cancel)
    \\  F9      about iro
    \\  F1      hint bar on/off (remembered)
    \\  Alt+G   switch gear: Blade (just text) ⇄ Forge (tree, minimap, git)
    \\  Alt+M   minimap on/off
    \\  Alt+W   soft wrap on/off
    \\  Alt+V   split view (Alt+Left/Right switches sides)
    \\  Ctrl+Space / Alt+Space  complete word
    \\
    \\  Ctrl+O  find and open a file (Tab or "/": type a path,
    \\          where Tab completes the name)
    \\  Alt+Z   jump to a folder from zoxide
    \\
    \\  Tabs:   Ctrl+N new     Ctrl+W close
    \\          Ctrl+PgUp/PgDn switch          Alt+1…9 direct
    \\
    \\  --blade    start in Blade (otherwise: file → Blade, folder → Forge)
    \\  --forge    start in Forge
    \\  --version  show the version
    \\  --help     this help
    \\
    \\Copyright (C) 2026 Mausmann · License: GNU GPL v3+ (see LICENSE)
    \\
;

/// Which gear at start if neither the command line nor the config says: opening
/// a single file means a quick edit (Blade). Several files, a folder or nothing
/// at all mean a project (Forge).
fn autoGear(file_count: usize, has_dir: bool) config.Gear {
    return if (file_count == 1 and !has_dir) .blade else .forge;
}

test "gear at start" {
    try std.testing.expectEqual(config.Gear.blade, autoGear(1, false));
    try std.testing.expectEqual(config.Gear.forge, autoGear(2, false));
    try std.testing.expectEqual(config.Gear.forge, autoGear(1, true));
    try std.testing.expectEqual(config.Gear.forge, autoGear(0, false));
}

/// `iro --search-probe FOLDER [WORD]`: indexes FOLDER like the file search and
/// reports how long it takes, how many files there are and what would rank
/// first for WORD. For measuring whether the search is fast enough.
fn searchProbe(gpa: Allocator, io: Io, args: []const [:0]const u8) !void {
    const dir_arg = if (args.len > 2) args[2] else ".";
    const root = try resolvePath(gpa, io, dir_arg);
    defer gpa.free(root);
    const idx = try iro.index.Index.start(gpa, io, root, .{}, null);
    defer idx.deinit();
    idx.wait();
    std.debug.print("{d} files indexed in {d} ms{s} ({s})\n", .{ idx.entries.items.len, idx.took_ms, if (idx.truncated) ", TRUNCATED" else "", root });
    if (args.len < 4) return;
    const needle = args[3];
    var hits: std.ArrayList(SearchHit) = .empty;
    defer hits.deinit(gpa);
    const t0 = Io.Timestamp.now(io, .awake);
    const typo = try iro.search.rank(gpa, io, idx.entries.items, .{ .needle = needle }, null, &hits);
    const ms = t0.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    std.debug.print("\"{s}\": {d} matches in {d} ms{s}\n", .{ needle, hits.items.len, ms, if (typo) " (approximate, typo forgiven)" else "" });
    for (hits.items[0..@min(hits.items.len, 12)]) |h| {
        std.debug.print("  {d:>5}  {s}\n", .{ h.score, idx.entries.items[h.index].path });
    }
}

const SearchHit = iro.search.Hit;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("iro: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Errors before start, in the system language (init.lua has not been read
/// yet).
fn failL(l: Lang, comptime de: []const u8, comptime en: []const u8, args: anytype) noreturn {
    if (l == .en) fail(en, args) else fail(de, args);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const env = init.environ_map;
    const sys_lang = iro.lang.fromLocale(env.get("LC_ALL"), env.get("LC_MESSAGES"), env.get("LANG"));
    var file_args: std.ArrayList([]const u8) = .empty;
    defer file_args.deinit(gpa);
    var cli_gear: ?config.Gear = null;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("iro {s} (色 · Instant · Riced · Operator) — {s} Mausmann (GPL-3.0-or-later)\n", .{ version, if (sys_lang == .en) "by" else "von" });
            return;
        } else if (std.mem.eql(u8, a, "--search-probe")) {
            return searchProbe(gpa, io, args);
        } else if (std.mem.eql(u8, a, "--blade")) {
            cli_gear = .blade;
        } else if (std.mem.eql(u8, a, "--forge")) {
            cli_gear = .forge;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{if (sys_lang == .en) usage_en else usage_de});
            return;
        } else try file_args.append(gpa, a);
    }

    // Load files before switching the terminal over, so error messages land
    // readably in the shell. Every file becomes a tab.
    var docs: std.ArrayList(*Doc) = .empty;
    var first_is_new = false;
    var start_dir: ?[]u8 = null;
    for (file_args.items) |arg| {
        const path = try resolvePath(gpa, io, arg);
        var twice = false;
        for (docs.items) |doc| {
            if (std.mem.eql(u8, doc.path.?, path)) twice = true;
        }
        if (twice) {
            gpa.free(path);
            continue;
        }
        if (fileio.load(gpa, io, Io.Dir.cwd(), path)) |loaded| {
            try docs.append(gpa, try Doc.create(gpa, Editor.fromBuffer(gpa, loaded.buf), loaded.meta, path));
        } else |err| switch (err) {
            error.FileNotFound => {
                if (docs.items.len == 0) first_is_new = true;
                try docs.append(gpa, try Doc.create(gpa, try Editor.init(gpa), .{}, path));
            },
            error.NotUtf8 => failL(sys_lang, "{s} ist keine Textdatei in UTF-8. iro öffnet sie nicht, um nichts zu beschädigen.", "{s} is not a UTF-8 text file. iro won't open it so nothing gets damaged.", .{arg}),
            error.FileTooBig => failL(sys_lang, "{s} ist größer als 256 MB.", "{s} is larger than 256 MB.", .{arg}),
            // A folder becomes the root of the file tree.
            error.IsDir => {
                if (start_dir) |old| gpa.free(old);
                start_dir = path;
            },
            error.AccessDenied, error.PermissionDenied => failL(sys_lang, "keine Leserechte für {s}.", "no read permission for {s}.", .{arg}),
            else => failL(sys_lang, "{s} lässt sich nicht öffnen ({s}).", "{s} cannot be opened ({s}).", .{ arg, @errorName(err) }),
        }
    }
    if (docs.items.len == 0) try docs.append(gpa, try Doc.create(gpa, try Editor.init(gpa), .{}, null));

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, writer);

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .env = init.environ_map,
        .vx = &vx,
        .tty = &tty,
        .docs = docs,
        .d = docs.items[0],
        .start_dir = start_dir,
        .frame = .init(gpa),
    };
    defer app.deinit();
    app.loadHintsChoice();
    app.sys_lang = sys_lang;
    app.applyConfig(); // in case there is no init.lua at all
    app.loadConfig(false);
    // Command line beats config, config beats "auto". Auto: single file → Blade.
    app.gear = cli_gear orelse app.cfg.gear orelse autoGear(file_args.items.len, start_dir != null);
    for (app.docs.items) |doc| {
        app.d = doc;
        app.initSwapPath() catch {};
        app.detectLang();
        app.loadGitBase(doc);
    }
    // The recovery question comes as soon as a tab is brought to the front. For
    // the first one, that's now.
    app.d = app.docs.items[0];
    // Unnamed files from a crashed session come back as tabs of their own.
    const had_named = app.d.path != null;
    const restored = app.recoverScratch();
    if (had_named or restored == 0) {
        app.cur = 0;
        app.activate(); // also asks about a backup of the first file
    }
    if (restored == 1 and app.prompt == null) {
        app.say(false, "Ungespeicherter Text aus der letzten Sitzung ist wieder da", "Unsaved text from your last session is back", .{});
    } else if (restored > 1 and app.prompt == null) {
        app.say(false, "{d} ungespeicherte Texte aus der letzten Sitzung sind wieder da", "{d} unsaved texts from your last session are back", .{restored});
    }
    if (first_is_new and app.prompt == null and app.msg_len == 0) app.say(false, "Neue Datei", "New file", .{});
    if (start_dir != null) {
        app.toggleTree();
    } else if (app.cfg.tree_on_start and app.gear == .forge) {
        app.toggleTree();
        app.focus = .text;
    }

    var loop: Loop = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    // Terminals that report size changes themselves (kitty, foot, ghostty)
    // need no signal; for all others SIGWINCH is the only way to notice a
    // resize. Once the terminal reports in-band, vaxis ignores the signal.
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();
    app.loop = &loop;
    if (app.start_dir) |d| app.search_dir = gpa.dupe(u8, d) catch null;
    app.loadRecent();
    for (app.docs.items) |doc| if (doc.path) |path| {
        if (doc.meta.disk != null) app.rememberRecent(path);
    };

    try vx.enterAltScreen(writer);
    // Tell kitty that an editor is running here. kitty.conf can use this to
    // release keys that kitty would otherwise grab (map --when-focus-on
    // var:in_editor ...). Other terminals ignore it.
    try writer.writeAll("\x1b]1337;SetUserVar=in_editor=MQ==\x07");
    defer {
        writer.writeAll("\x1b]1337;SetUserVar=in_editor\x07") catch {};
        writer.flush() catch {};
    }
    try vx.setMouseMode(writer, true);
    try vx.setBracketedPaste(writer, true);
    try writer.flush();
    try vx.queryTerminal(writer, .fromSeconds(1));
    app.queryColors();
    if (vx.caps.kitty_graphics) {
        app.logo_img = vx.loadImage(gpa, writer, .{ .mem = logo_png }) catch null;
    }
    defer if (app.logo_img) |img| {
        vx.freeImage(writer, img.id);
        writer.flush() catch {};
    };
    app.updateTitle();

    var color_task = try io.concurrent(colorTicker, .{ &loop, io });
    defer color_task.cancel(io);
    var swap_timers: Io.Group = .init;
    defer swap_timers.cancel(io);

    while (!app.should_quit) {
        armSwapTimer(&app, &swap_timers, &loop, io);
        const event = if (app.isAnimating()) blk: {
            if (try loop.tryEvent()) |ev| break :blk ev;
            io.sleep(.fromMilliseconds(16), .awake) catch {};
            app.stepAnimation();
            draw_mod.draw(&app);
            try vx.render(writer);
            try writer.flush();
            continue;
        } else try loop.nextEvent();
        switch (event) {
            .key_press => |key| app.handleKey(key),
            .mouse => |m| app.handleMouse(m),
            .winsize => |ws| try vx.resize(gpa, writer, ws),
            .color_report => |r| {
                if (!app.onColorReport(r)) continue;
            },
            .paste_start => {
                app.pasting = true;
                app.paste_buf.clearRetainingCapacity();
            },
            .paste_end => {
                app.pasting = false;
                if (app.palette) |*p| {
                    p.input.appendSlice(gpa, std.mem.sliceTo(app.paste_buf.items, '\n')) catch {};
                    p.selected = 0;
                    p.stale = true;
                } else if (app.prompt) |*p| {
                    // In the input line, take only the first line.
                    const first = std.mem.sliceTo(app.paste_buf.items, '\n');
                    p.input.appendSlice(gpa, first) catch {};
                    if (p.kind == .search or p.kind == .replace_find) app.runSearch(true, true);
                } else if (app.paste_buf.items.len > 0) {
                    app.insertPasted(app.paste_buf.items);
                    app.d.follow = true;
                }
            },
            .index_progress => {
                app.onIndexProgress();
                // Only redraw if the file search is currently open.
                if (app.palette == null) continue;
            },
            .tick => {
                app.swap_armed = false;
                for (app.docs.items) |doc| app.writeSwap(doc);
                continue; // nothing changes on screen
            },
            .color_tick => {
                app.queryColors();
                continue;
            },
            .focus_in => if (!app.checkAllOutside()) continue,
        }
        draw_mod.draw(&app);
        try vx.render(writer);
        try writer.flush();
    }
}
