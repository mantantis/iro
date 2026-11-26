// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Draws iro's entire UI: start screen, tabs, file tree, text with
//! syntax/git/brackets/search matches, Braille minimap, scrollbar, hint bar,
//! status line and command palette.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const iro = @import("iro");

const Pos = iro.Pos;
const text = iro.text;
const syntax = iro.syntax;
const config = iro.config;
const Cmd = config.Cmd;

const main = @import("main.zig");
const App = main.App;
const TabSpan = main.TabSpan;

/// One hint bar entry: a key and what it currently does. `key_en`: in case the
/// key itself is named differently in English ("Taste" → "Key").
const Hint = struct { key: []const u8, key_en: ?[]const u8 = null, label: Text };
const Text = iro.lang.Text;

/// Text in the UI language. Both versions are given inline.
fn ui(self: *const App, de: []const u8, en: []const u8) []const u8 {
    return if (self.lang == .en) en else de;
}

/// Like `ui`, with placeholders. The compiler checks both formats.
fn fmtL(self: *const App, arena: Allocator, comptime de: []const u8, comptime en: []const u8, args: anytype) []const u8 {
    // The arguments are often names or text from outside (files, folders,
    // checker output); nothing in them may hide or reverse characters.
    const out = (if (self.lang == .en) std.fmt.allocPrint(arena, en, args) else std.fmt.allocPrint(arena, de, args)) catch return "";
    return text.cleanName(arena, out);
}
const CursorXY = struct { x: u16, y: u16 };

fn inRange(r: iro.Range, p: Pos) bool {
    return !p.lessThan(r.start) and p.lessThan(r.end);
}

pub fn wrappedLineRows(line_bytes: []const u8, tab_width: usize, w: usize, cursor_col: ?usize) usize {
    if (w == 0) return 1;
    const cd: ?usize = if (cursor_col) |cc| text.displayCol(line_bytes, cc, tab_width) else null;
    return text.wrapRowCount(line_bytes, tab_width, w, cd);
}

/// Screen rows of a line of the current tab. The cursor line can need one
/// more (cursor after a full last row).
pub fn docRows(self: *const App, line: usize) usize {
    const ed = &self.d.ed;
    const cur_c: ?usize = if (line == ed.cursor.line) ed.cursor.col else null;
    return wrappedLineRows(ed.buf.line(line), ed.tab_width, self.text_w, cur_c);
}

/// Keeps `top_seg` inside the top line; without soft wrap it is always 0.
pub fn clampTopSeg(self: *App) void {
    if (!(self.cfg.wrap and self.text_w >= 8)) {
        self.d.top_seg = 0;
        return;
    }
    self.d.top_seg = @min(self.d.top_seg, docRows(self, self.d.top_line) - 1);
}

/// Scrolls by screen rows (soft wrap) instead of lines, so the mouse wheel
/// also moves through a line taller than the screen.
pub fn scrollRows(self: *App, delta: isize) void {
    const count = self.d.ed.buf.lineCount();
    var n: usize = @abs(delta);
    while (n > 0) : (n -= 1) {
        if (delta > 0) {
            if (self.d.top_seg + 1 < docRows(self, self.d.top_line)) {
                self.d.top_seg += 1;
            } else if (self.d.top_line + 1 < count) {
                self.d.top_line += 1;
                self.d.top_seg = 0;
            } else break;
        } else {
            if (self.d.top_seg > 0) {
                self.d.top_seg -= 1;
            } else if (self.d.top_line > 0) {
                self.d.top_line -= 1;
                self.d.top_seg = docRows(self, self.d.top_line) - 1;
            } else break;
        }
    }
}

fn scrollToCursor(self: *App) void {
    const cur = self.d.ed.cursor;
    const h = self.text_h;
    const w = self.text_w;
    if (self.cfg.wrap and w >= 8) {
        self.d.left_col = 0;
        if (cur.line < self.d.top_line) {
            self.d.top_line = cur.line;
            self.d.top_seg = 0;
        }
        clampTopSeg(self);
        const cur_l = self.d.ed.buf.line(cur.line);
        const cur_dcol = text.displayCol(cur_l, cur.col, self.d.ed.tab_width);
        const cur_seg = text.wrapRowOf(cur_l, self.d.ed.tab_width, w, cur_dcol);
        if (cur.line == self.d.top_line and cur_seg < self.d.top_seg) self.d.top_seg = cur_seg;

        // Rows from the top of the view down to and including the cursor row.
        var used: usize = cur_seg + 1;
        if (cur.line == self.d.top_line) {
            used -= self.d.top_seg;
        } else {
            used += docRows(self, self.d.top_line) - self.d.top_seg;
            var l = self.d.top_line + 1;
            while (l < cur.line) : (l += 1) used += docRows(self, l);
        }
        while (used > h and self.d.top_line < cur.line) {
            used -|= docRows(self, self.d.top_line) - self.d.top_seg;
            self.d.top_line += 1;
            self.d.top_seg = 0;
        }
        // The cursor line alone is taller than the screen: scroll within it.
        if (used > h) self.d.top_seg += used - h;
        return;
    }
    self.d.top_seg = 0;

    const margin = @min(main.scroll_margin, (h -| 1) / 2);
    if (cur.line < self.d.top_line + margin) self.d.top_line = cur.line -| margin;
    if (cur.line + margin + 1 > self.d.top_line + h) self.d.top_line = cur.line + margin + 1 - h;

    const dcol = text.displayCol(self.d.ed.buf.line(cur.line), cur.col, self.d.ed.tab_width);
    const side = @min(5, (w -| 1) / 2);
    if (dcol < self.d.left_col + side) self.d.left_col = dcol -| side;
    if (dcol + side + 1 > self.d.left_col + w) self.d.left_col = dcol + side + 1 - w;
}

fn showStartScreen(self: *const App, avail_w: usize) bool {
    return self.cfg.start_screen and
        self.docs.items.len == 1 and
        self.d.pristine() and
        self.text_h >= 10 and
        avail_w >= 36;
}

fn centerText(win: vaxis.Window, row: u16, msg: []const u8, style: vaxis.Style) void {
    const w = win.gwidth(msg);
    const col = (win.width -| w) / 2;
    _ = win.printSegment(.{ .text = msg, .style = style }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
}

/// Start screen for empty sessions: logo via the kitty graphics protocol (if
/// supported and there is room), otherwise a plain text header. Returns `true`
/// if a pixel image was just drawn.
fn drawStartScreen(self: *App, tw: vaxis.Window, arena: Allocator) bool {
    const Shortcut = struct { key: []const u8, desc: []const u8 };
    const shortcuts = [_]Shortcut{
        .{ .key = self.cfg.keyLabel(.help), .desc = ui(self, "Hilfe: alles kurz erklärt", "Help: everything explained") },
        .{ .key = if (self.cfg.esc_menu) "Esc" else self.cfg.keyLabel(.menu), .desc = ui(self, "Hauptmenü", "Main menu") },
        .{ .key = self.cfg.keyLabel(.open), .desc = ui(self, "Datei suchen & öffnen", "Find & open a file") },
        .{ .key = self.cfg.keyLabel(.palette), .desc = ui(self, "Befehlspalette", "Command palette") },
        .{ .key = self.cfg.keyLabel(.tree), .desc = ui(self, "Dateibaum ein/aus", "File tree on/off") },
        .{ .key = self.cfg.keyLabel(.jump_dir), .desc = ui(self, "Ordner wechseln (zoxide)", "Switch folder (zoxide)") },
        .{ .key = self.cfg.keyLabel(.quit), .desc = ui(self, "Beenden", "Quit") },
    };

    var max_key_w: u16 = 8;
    var max_desc_w: u16 = 0;
    for (shortcuts) |sc| {
        const k = if (sc.key.len > 0) sc.key else "—";
        max_key_w = @max(max_key_w, tw.gwidth(k));
        max_desc_w = @max(max_desc_w, tw.gwidth(sc.desc));
    }
    const block_w = max_key_w + 2 + max_desc_w;
    const block_x = (tw.width -| block_w) / 2;

    const drawFooterAndShortcuts = struct {
        fn f(
            app: *const App,
            w: vaxis.Window,
            list: []const Shortcut,
            bx: u16,
            kw: u16,
            start_row: u16,
        ) void {
            for (list, 0..) |sc, idx| {
                const row: u16 = start_row + @as(u16, @intCast(idx));
                if (row >= w.height) break;
                const k_txt = if (sc.key.len > 0) sc.key else "—";
                const k_w = w.gwidth(k_txt);
                const k_x = bx + (kw -| k_w);
                const k_style: vaxis.Style = if (sc.key.len > 0) .{ .fg = app.pinkColor(), .bold = true } else .{ .dim = true };
                _ = w.printSegment(.{ .text = k_txt, .style = k_style }, .{ .row_offset = row, .col_offset = k_x, .wrap = .none });
                _ = w.printSegment(.{ .text = sc.desc, .style = .{ .dim = true } }, .{ .row_offset = row, .col_offset = bx + kw + 2, .wrap = .none });
            }
            const foot_row: u16 = start_row + @as(u16, @intCast(list.len));
            if (foot_row < w.height) {
                centerText(w, foot_row, if (app.lang == .en) "Just start typing for a new file" else "Tippe einfach los für eine neue Datei", .{ .dim = true });
            }
        }
    }.f;

    const th: u16 = @intCast(self.text_h);
    const long_sub = ui(self, "色  Instant · Riced · Operator  ·  Zig + Lua  ·  von Mausmann", "色  Instant · Riced · Operator  ·  Zig + Lua  ·  by Mausmann");
    // The author's name stays on screen however narrow it gets (NOTICE.md,
    // section 3a): rather drop the rest of the line than cut off the name.
    const subtitle = if (tw.width >= tw.gwidth(long_sub)) long_sub else ui(self, "色  von Mausmann", "色  by Mausmann");

    // Case A: real logo via the kitty graphics protocol (at least 6 rows of room).
    const text_rows_a: u16 = 9;
    const avail_rows: u16 = th -| (text_rows_a + 1);
    if (self.logo_img != null and !self.overlayOpen() and avail_rows >= 6 and tw.width >= 38) {
        const logo_rows: u16 = @min(std.math.clamp(avail_rows, 6, 18), (tw.width -| 4) / 2);
        const logo_cols: u16 = logo_rows * 2;
        const total_h = logo_rows + 1 + text_rows_a;
        const top_y: u16 = (th -| total_h) / 2;
        const logo_x: u16 = (tw.width -| logo_cols) / 2;

        const logo_win = tw.child(.{
            .x_off = logo_x,
            .y_off = top_y,
            .width = logo_cols,
            .height = logo_rows,
        });
        self.logo_img.?.draw(logo_win, .{
            .scale = .none,
            .size = .{ .rows = logo_rows, .cols = logo_cols },
            .z_index = -1,
        }) catch {};

        const sub_y = top_y + logo_rows + 1;
        centerText(tw, sub_y, subtitle, .{ .dim = true });
        drawFooterAndShortcuts(self, tw, &shortcuts, block_x, max_key_w, sub_y + 2);
        return true;
    }

    // Case B: plain text fallback (tmux, terminals without graphics protocol, palette open).
    const total_h_b: u16 = 9;
    const top_y_b: u16 = (th -| total_h_b) / 2;
    const long_head_w = tw.gwidth(">_ IRO  —  ") + tw.gwidth(subtitle);
    if (tw.width >= long_head_w) {
        var hx: u16 = (tw.width -| long_head_w) / 2;
        const r1 = tw.printSegment(.{ .text = ">_ ", .style = .{ .fg = self.pinkColor(), .bold = true } }, .{ .row_offset = top_y_b, .col_offset = hx, .wrap = .none });
        hx = r1.col;
        const r2 = tw.printSegment(.{ .text = "IRO", .style = .{ .fg = self.accentColor(), .bold = true } }, .{ .row_offset = top_y_b, .col_offset = hx, .wrap = .none });
        _ = tw.printSegment(.{ .text = std.fmt.allocPrint(arena, "  —  {s}", .{subtitle}) catch subtitle, .style = .{ .dim = true } }, .{ .row_offset = top_y_b, .col_offset = r2.col, .wrap = .none });
    } else {
        const short_w = tw.gwidth(">_ IRO");
        const hx: u16 = (tw.width -| short_w) / 2;
        const r1 = tw.printSegment(.{ .text = ">_ ", .style = .{ .fg = self.pinkColor(), .bold = true } }, .{ .row_offset = top_y_b, .col_offset = hx, .wrap = .none });
        _ = tw.printSegment(.{ .text = "IRO", .style = .{ .fg = self.accentColor(), .bold = true } }, .{ .row_offset = top_y_b, .col_offset = r1.col, .wrap = .none });
        // The row between header and shortcuts is free.
        centerText(tw, top_y_b + 1, subtitle, .{ .dim = true });
    }
    drawFooterAndShortcuts(self, tw, &shortcuts, block_x, max_key_w, top_y_b + 2);
    return false;
}

pub fn draw(self: *App) void {
    _ = self.frame.reset(.retain_capacity);
    const arena = self.frame.allocator();
    const win = self.vx.window();
    win.clear();
    win.hideCursor();
    self.tab_spans = &.{};
    self.tabs_h = 0;
    if (win.height < 2 or win.width < 12) return;
    // The tab bar only appears from the second open file on.
    if (self.docs.items.len > 1 and win.height >= 4) self.tabs_h = 1;
    // The hint bar gives way when the window gets too short.
    self.hints_h = if (self.hints_on and win.height >= 6) 1 else 0;

    const ed = &self.d.ed;
    const line_count = ed.buf.lineCount();
    var digits: usize = 1;
    var n = line_count;
    while (n >= 10) : (n /= 10) digits += 1;
    self.gutter_w = @max(digits, 2) + 2;
    self.text_h = win.height - 1 - self.tabs_h - self.hints_h;
    // The tree needs room. In a narrow window it stays hidden so some text
    // remains visible.
    self.tree_w = 0;
    if (self.tree_visible and self.tree != null and win.width >= 50) {
        const target_w = std.math.clamp(win.width / 4, 22, 34);
        if (self.cfg.animations and self.term_bg != null and self.tree_anim_w > 0) {
            self.tree_w = @min(self.tree_anim_w, target_w);
        } else {
            self.tree_w = target_w;
        }
    } else if (self.focus == .tree) {
        self.focus = .text;
    }
    self.split_div_col = 0;
    self.split_x = self.tree_w;
    const full = win;
    if (self.tabs_h > 0) drawTabs(self, full, arena);
    // Everything between tab bar and status line: tree on the left, text on the right (optionally
    // split).
    const area = full.child(.{ .y_off = @intCast(self.tabs_h), .height = @intCast(self.text_h) });
    if (self.tree_w > 0) drawTree(self, area, arena);
    const full_tw = area.child(.{ .x_off = @intCast(self.tree_w) });
    const start_mode = showStartScreen(self, full_tw.width);
    const show_split = self.split_on and !start_mode and full_tw.width >= 56;
    var tw = full_tw;
    if (show_split) {
        const half_w: u16 = full_tw.width / 2;
        const left_pane = full_tw.child(.{ .width = half_w });
        const right_pane = full_tw.child(.{ .x_off = half_w + 1, .width = full_tw.width - half_w - 1 });
        self.split_div_col = self.tree_w + half_w;
        var y_div: u16 = 0;
        while (y_div < @as(u16, @intCast(self.text_h))) : (y_div += 1) {
            full_tw.writeCell(half_w, y_div, .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = self.faintStyle(),
            });
        }
        if (self.split_right_active) {
            tw = right_pane;
            self.split_x = self.tree_w + half_w + 1;
            drawInactivePane(self, left_pane, arena);
        } else {
            tw = left_pane;
            self.split_x = self.tree_w;
            drawInactivePane(self, right_pane, arena);
        }
    }
    self.scroll_w = if (self.cfg.scrollbar and line_count > self.text_h and tw.width >= 24) 1 else 0;
    // In Blade only if explicitly requested (Alt+M).
    const map_auto = line_count > self.text_h and self.gear == .forge;
    self.minimap_w = if (self.cfg.minimap and tw.width >= 68 and (map_auto or self.minimap_forced))
        iro.minimap.width
    else
        0;
    self.text_w = @max(@as(usize, 1), tw.width -| self.gutter_w -| self.minimap_w -| self.scroll_w);

    if (self.d.follow) scrollToCursor(self);
    self.d.top_line = @min(self.d.top_line, line_count - 1);
    clampTopSeg(self);

    self.syncSyntax(self.d.top_line + self.text_h, arena);
    const sel = ed.selection();
    var cursor_xy: ?CursorXY = null;
    var now_logo = false;

    if (start_mode) {
        self.minimap_w = 0;
        now_logo = drawStartScreen(self, tw, arena);
    } else {
        const accent = self.accentColor();
        const warn = self.warnColor();
        const bad = self.badColor();
        const theme = self.cfg.theme;
        const cl_bg = self.cursorLineBg();
        const sel_bg = self.selectionBg();
        const faint = self.faintStyle();
        const needle = self.activeNeedle();
        const left = self.d.left_col;
        const pair: ?[2]Pos = if (self.cfg.brackets and sel == null) ed.bracketPair(2000) else null;
        self.syncGit(arena);
        const marks = self.d.git_marks.items;
        const is_markdown = if (self.d.lang) |lang| std.mem.eql(u8, lang.name, "Markdown") else false;
        const h1_bg: ?vaxis.Color = if (is_markdown) blk: {
            const bg = self.term_bg orelse break :blk null;
            const ac = self.accentRgb() orelse break :blk null;
            break :blk App.mix(bg, ac, 12);
        } else null;

        const wrapping = self.cfg.wrap and self.text_w >= 8;
        var row: usize = 0;
        var line: usize = self.d.top_line;
        while (row < self.text_h and line < line_count) : (line += 1) {
            const is_cur = line == ed.cursor.line;
            const l = ed.buf.line(line);

            var line_kinds: ?[]syntax.Kind = null;
            if (self.d.lang) |lang| {
                if (arena.alloc(syntax.Kind, l.len)) |k| {
                    _ = syntax.highlightLine(lang, l, self.d.syn_states.items[line], k);
                    line_kinds = k;
                } else |_| {}
            }

            const line_selected = if (sel) |r| r.start.line <= line and line <= r.end.line else false;
            const is_h1 = h1_bg != null and std.mem.startsWith(u8, l, "# ") and
                if (line_kinds) |k| (k.len > 0 and k[0] == .heading) else false;

            // Line pulse > cursor line > Markdown top-level heading.
            const row_bg: ?vaxis.Color = blk: {
                if (self.cfg.animations and self.flash_frames > 0 and self.flash_line == line) {
                    if (self.term_bg) |bg| {
                        if (self.accentRgb()) |ac| {
                            break :blk App.mix(bg, ac, 18 + @as(u32, self.flash_frames) * 6);
                        }
                    }
                    break :blk cl_bg;
                }
                if (is_cur and sel == null) break :blk cl_bg;
                if (is_h1 and !line_selected) break :blk h1_bg;
                break :blk null;
            };

            const indent_len = text.indentLen(l);
            const content_end = std.mem.trimEnd(u8, l, " \t").len;
            // All matches of the current search in this line.
            var hits: ?[]bool = null;
            if (needle.len > 0 and l.len >= needle.len) {
                if (arena.alloc(bool, l.len)) |h| {
                    @memset(h, false);
                    var from: usize = 0;
                    while (iro.editor.findInLine(l, needle, from)) |at| {
                        @memset(h[at..][0..needle.len], true);
                        from = at + needle.len;
                        hits = h;
                    }
                } else |_| {}
            }

            const cur_dcol: ?usize = if (is_cur) text.displayCol(l, ed.cursor.col, ed.tab_width) else null;
            const segs: usize = if (wrapping) text.wrapRowCount(l, ed.tab_width, self.text_w, cur_dcol) else 1;
            // One pass over the characters for all rows of the line.
            var rows = text.wrapRows(l, ed.tab_width, self.text_w);
            var it = text.iterate(l, ed.tab_width);
            var pending: ?text.Cluster = null;
            var line_w: usize = 0;
            var seg: usize = 0;
            // The top line can start further down (a line taller than the screen).
            if (line == self.d.top_line) {
                while (seg < self.d.top_seg) : (seg += 1) {
                    if (rows.next()) |r| line_w = r.end;
                }
            }
            while (seg < segs and row < self.text_h) : ({
                seg += 1;
                row += 1;
            }) {
                const y: u16 = @intCast(row);
                // Display columns shown in this row: [span.start, span.end).
                const span: text.Row = if (!wrapping)
                    .{ .start = left, .end = left + self.text_w }
                else if (rows.next()) |r| blk: {
                    line_w = r.end;
                    break :blk r;
                } else .{ .start = line_w, .end = line_w }; // extra row for the cursor
                const seg_left = span.start;

                if (row_bg) |bg| {
                    tw.child(.{ .y_off = y, .height = 1, .width = @intCast(self.gutter_w + self.text_w) }).fill(.{ .style = .{ .bg = bg } });
                }

                if (seg == 0) {
                    const num = std.fmt.allocPrint(arena, "{d}", .{line + 1}) catch "";
                    var num_style: vaxis.Style = if (is_cur) .{ .fg = accent, .bold = true } else .{ .dim = true };
                    if (row_bg) |bg| num_style.bg = bg;
                    _ = tw.printSegment(.{ .text = num, .style = num_style }, .{ .row_offset = y, .col_offset = @intCast(self.gutter_w - 1 - num.len), .wrap = .none });

                    // Git gutter: a thin bar directly before the text.
                    if (line < marks.len and marks[line] != .none) {
                        const mark = marks[line];
                        var mark_style: vaxis.Style = .{ .fg = main.toVaxisColor(switch (mark) {
                            .added => theme.git_neu,
                            .changed => theme.git_geaendert,
                            else => theme.git_weg,
                        }) };
                        if (row_bg) |bg| mark_style.bg = bg;
                        tw.writeCell(@intCast(self.gutter_w - 1), y, .{
                            .char = .{ .grapheme = switch (mark) {
                                .deleted_above => "▔",
                                .deleted_below => "▁",
                                else => "▎",
                            }, .width = 1 },
                            .style = mark_style,
                        });
                    }
                } else {
                    var cont_style: vaxis.Style = faint;
                    if (row_bg) |bg| cont_style.bg = bg;
                    tw.writeCell(@intCast(self.gutter_w - 2), y, .{
                        .char = .{ .grapheme = "↪", .width = 1 },
                        .style = cont_style,
                    });
                }

                while (pending orelse it.next()) |c| {
                    pending = null;
                    if (c.dcol + c.width <= seg_left) continue;
                    if (c.dcol >= span.end) {
                        pending = c;
                        break;
                    }
                    const selected = if (sel) |r| inRange(r, .{ .line = line, .col = c.start }) else false;
                    const bytes = l[c.start..c.end()];
                    const hidden = text.hiddenKind(bytes);
                    const blank = bytes[0] == '\t' or (bytes.len == 1 and bytes[0] == ' ');
                    const clipped = c.dcol < seg_left or c.dcol + c.width > seg_left + self.text_w;

                    var base: vaxis.Style = .{ .fg = self.textColor() };
                    if (selected) {
                        if (sel_bg) |bg| base.bg = bg else base.reverse = true;
                    } else if (row_bg) |bg| base.bg = bg;
                    if (hits) |h| {
                        if (h[c.start]) {
                            base.ul_style = .curly;
                            base.ul = warn;
                        }
                    }

                    if ((hidden != .none and hidden != .joined) or blank or clipped) {
                        const in_indent = blank and c.start < indent_len and content_end > 0;
                        const trailing = blank and self.cfg.show_trailing and c.start >= content_end and !is_cur;
                        var k: usize = 0;
                        while (k < c.width) : (k += 1) {
                            const d = c.dcol + k;
                            if (d < seg_left or d >= seg_left + self.text_w) continue;
                            var st = base;
                            var glyph: []const u8 = " ";
                            if (hidden == .sneaky and k == 0) {
                                glyph = "▪";
                                st.fg = bad;
                                st.bold = true;
                            } else if (hidden == .control and k == 0) {
                                glyph = "·";
                                st.dim = true;
                            } else if (trailing and k == 0) {
                                glyph = "·";
                                st.fg = warn;
                                st.dim = true;
                            } else if (in_indent and self.cfg.indent_guides and d > 0 and d % ed.tab_width == 0) {
                                glyph = "▏";
                                st.fg = faint.fg;
                                st.dim = faint.dim;
                            }
                            tw.writeCell(@intCast(self.gutter_w + d - seg_left), y, .{
                                .char = .{ .grapheme = glyph, .width = 1 },
                                .style = st,
                            });
                        }
                    } else {
                        var style = base;
                        if (line_kinds) |k| {
                            const ks = self.kindStyle(k[c.start]);
                            style.fg = ks.fg;
                            style.italic = ks.italic;
                            style.bold = ks.bold;
                        }
                        if (pair) |p| {
                            const here: Pos = .{ .line = line, .col = c.start };
                            if (here.eql(p[0]) or here.eql(p[1])) {
                                style.fg = accent;
                                style.bold = true;
                                style.ul_style = .single;
                                style.ul = accent;
                            }
                        }
                        // An invisible joiner glued to this character: show the
                        // character alone, marked like the other hidden ones.
                        const shown = if (hidden == .joined) text.baseChar(bytes) else bytes;
                        if (hidden == .joined) {
                            style.fg = bad;
                            style.bold = true;
                            style.ul_style = .curly;
                            style.ul = bad;
                        }
                        tw.writeCell(@intCast(self.gutter_w + c.dcol - seg_left), y, .{
                            .char = .{ .grapheme = shown, .width = @intCast(c.width) },
                            .style = style,
                        });
                    }
                }
                if (seg + 1 == segs) {
                    if (sel) |r| {
                        const eol: Pos = .{ .line = line, .col = l.len };
                        if (inRange(r, eol)) {
                            const eol_dcol = if (wrapping) span.end else text.lineWidth(l, ed.tab_width);
                            if (eol_dcol >= seg_left and eol_dcol < seg_left + self.text_w) {
                                tw.writeCell(@intCast(self.gutter_w + eol_dcol - seg_left), y, .{
                                    .style = if (sel_bg) |bg| .{ .bg = bg } else .{ .reverse = true },
                                });
                            }
                        }
                    }
                }

                if (cur_dcol) |dcol| {
                    // At the end of the line, the cursor sits right after the
                    // last character of the last row.
                    const last_seg = seg + 1 == segs;
                    if (dcol >= seg_left and (dcol < span.end or (last_seg and dcol < seg_left + self.text_w))) {
                        cursor_xy = .{ .x = @intCast(self.gutter_w + dcol - seg_left), .y = y };
                    }
                }
            }
        }

        // Braille minimap to the right of the text, before the scrollbar.
        if (self.minimap_w > 0) {
            drawMinimap(self, tw, arena, marks, needle, cl_bg, faint, accent, warn);
        }

        // Scrollbar: shows which part of the file is visible.
        if (self.scroll_w > 0) {
            const h = self.text_h;
            const thumb = std.math.clamp(h * h / line_count, 1, h);
            const max_top = line_count - 1;
            const top = @min((h - thumb) * self.d.top_line / @max(max_top, 1), h - thumb);
            var r: usize = 0;
            while (r < h) : (r += 1) {
                const on = r >= top and r < top + thumb;
                tw.writeCell(@intCast(self.gutter_w + self.text_w + self.minimap_w), @intCast(r), .{
                    .char = .{ .grapheme = if (on) "▐" else " ", .width = 1 },
                    .style = faint,
                });
            }
        }
    }
    if (self.showing_logo and !now_logo) {
        self.vx.refresh = true;
    }
    self.showing_logo = now_logo;

    if (self.hints_h > 0) drawHints(self, full, arena);
    drawStatus(self, full, arena);
    if (self.palette != null) {
        drawPalette(self, full, arena);
    } else if (self.settings_open) {
        drawSettings(self, full, arena);
    } else if (self.menu_open) {
        drawMenu(self, full, arena);
    } else if (self.about != null) {
        drawAbout(self, full, arena);
    } else if (self.prompt == null and self.focus == .text) {
        if (self.comp_open) {
            if (cursor_xy) |c| drawCompletion(self, tw, arena, c);
        }
        if (cursor_xy) |c| {
            tw.setCursorShape(.beam);
            tw.showCursor(c.x, c.y);
        }
    }
}

fn drawCompletion(self: *App, tw: vaxis.Window, arena: Allocator, cur: CursorXY) void {
    const items = self.compItems(arena);
    if (items.len == 0) {
        self.closeComp();
        return;
    }
    self.comp_sel = @min(self.comp_sel, items.len - 1);

    var max_w: u16 = 12;
    for (items) |it| max_w = @max(max_w, tw.gwidth(it.word));
    const w: u16 = @min(max_w +| 6, tw.width);
    const max_rows: u16 = @min(@as(u16, @intCast(items.len)), tw.height -| 2);
    if (max_rows == 0 or w < 8) return;
    const h: u16 = max_rows + 2;
    const y: u16 = if (cur.y + 1 + h <= tw.height) cur.y + 1 else cur.y -| h;
    const pref_x: u16 = cur.x -| @as(u16, @intCast(@min(self.comp_prefix_len, cur.x)));
    const x: u16 = @min(pref_x, tw.width - w);
    const accent = self.accentColor();
    const pink = self.pinkColor();
    const bg: vaxis.Color = cardBg(self) orelse .default;
    const sel_bg = cardSelBg(self);

    const box = tw.child(.{ .x_off = x, .y_off = y, .width = w, .height = h, .border = .{
        .where = .all,
        .style = .{ .fg = accent, .bg = bg },
    } });
    box.fill(.{ .style = .{ .bg = bg } });

    var r: u16 = 0;
    while (r < max_rows) : (r += 1) {
        const it = items[r];
        const row_win = box.child(.{ .y_off = r, .height = 1 });
        const sel_row = r == self.comp_sel;
        const row_bg: vaxis.Color = if (sel_row) (sel_bg orelse bg) else bg;
        const reverse = sel_row and sel_bg == null;
        const st: vaxis.Style = .{ .bg = row_bg, .bold = sel_row, .reverse = reverse };
        if (sel_row) {
            row_win.fill(.{ .style = st });
            row_win.writeCell(0, 0, .{ .char = .{ .grapheme = "▌", .width = 1 }, .style = .{ .fg = accent, .bg = row_bg } });
        }
        _ = row_win.printSegment(.{ .text = text.cleanName(arena, it.word), .style = st }, .{ .col_offset = 2, .wrap = .none });
        if (it.is_keyword and w >= 12) {
            const tag = "kw";
            const tx: u16 = row_win.width -| 3;
            _ = row_win.printSegment(.{ .text = tag, .style = .{ .fg = pink, .bg = row_bg, .dim = !sel_row, .reverse = reverse } }, .{ .col_offset = tx, .wrap = .none });
        }
    }
}

fn drawInactivePane(self: *App, pane: vaxis.Window, arena: Allocator) void {
    const idx = self.splitOtherIndex();
    const doc = self.docs.items[idx];
    const ed = &doc.ed;
    const line_count = ed.buf.lineCount();

    var digits: usize = 1;
    var n = line_count;
    while (n >= 10) : (n /= 10) digits += 1;
    const gw = @max(digits, 2) + 2;
    const tw_w = @max(@as(usize, 1), pane.width -| gw);
    const top_line = @min(self.split_other_top, line_count - 1);

    if (doc.lang != null) {
        const keep = self.d;
        self.d = doc;
        self.syncSyntax(top_line + self.text_h, arena);
        self.d = keep;
    }

    const wrapping = self.cfg.wrap and tw_w >= 8;
    const faint = self.faintStyle();
    var row: usize = 0;
    var line: usize = top_line;
    while (row < self.text_h and line < line_count) : (line += 1) {
        const l = ed.buf.line(line);
        var line_kinds: ?[]syntax.Kind = null;
        if (doc.lang) |lang| {
            if (arena.alloc(syntax.Kind, l.len)) |k| {
                _ = syntax.highlightLine(lang, l, doc.syn_states.items[line], k);
                line_kinds = k;
            } else |_| {}
        }
        const segs: usize = if (wrapping) text.wrapRowCount(l, ed.tab_width, tw_w, null) else 1;
        var rows = text.wrapRows(l, ed.tab_width, tw_w);
        var it = text.iterate(l, ed.tab_width);
        var pending: ?text.Cluster = null;
        var seg: usize = 0;
        if (wrapping and line == top_line) {
            const skip = @min(self.split_other_seg, segs - 1);
            while (seg < skip) : (seg += 1) _ = rows.next();
        }
        while (seg < segs and row < self.text_h) : ({
            seg += 1;
            row += 1;
        }) {
            const y: u16 = @intCast(row);
            const span: text.Row = if (wrapping) (rows.next() orelse break) else .{ .start = 0, .end = tw_w };
            const seg_left = span.start;
            if (seg == 0) {
                const num = std.fmt.allocPrint(arena, "{d}", .{line + 1}) catch "";
                _ = pane.printSegment(.{ .text = num, .style = .{ .dim = true } }, .{ .row_offset = y, .col_offset = @intCast(gw - 1 - num.len), .wrap = .none });
            } else {
                pane.writeCell(@intCast(gw - 2), y, .{ .char = .{ .grapheme = "↪", .width = 1 }, .style = faint });
            }
            while (pending orelse it.next()) |c| {
                pending = null;
                if (c.dcol + c.width <= seg_left) continue;
                if (c.dcol >= span.end) {
                    pending = c;
                    break;
                }
                const bytes = l[c.start..c.end()];
                const hidden = text.hiddenKind(bytes);
                const blank = bytes[0] == '\t' or (bytes.len == 1 and bytes[0] == ' ');
                const clipped = c.dcol < seg_left or c.dcol + c.width > seg_left + tw_w;
                if ((hidden != .none and hidden != .joined) or blank or clipped) continue;
                var style: vaxis.Style = .{ .dim = true, .fg = self.textColor() };
                if (line_kinds) |k| {
                    const ks = self.kindStyle(k[c.start]);
                    style.fg = ks.fg;
                    style.italic = ks.italic;
                    style.bold = ks.bold;
                }
                pane.writeCell(@intCast(gw + c.dcol - seg_left), y, .{
                    .char = .{ .grapheme = bytes, .width = @intCast(c.width) },
                    .style = style,
                });
            }
        }
    }
}

fn drawMinimap(
    self: *const App,
    tw: vaxis.Window,
    arena: Allocator,
    marks: []const iro.gitdiff.Mark,
    needle: []const u8,
    cl_bg: ?vaxis.Color,
    faint: vaxis.Style,
    accent: vaxis.Color,
    warn: vaxis.Color,
) void {
    const rows = iro.minimap.compute(
        arena,
        &self.d.ed.buf,
        self.d.ed.tab_width,
        self.d.top_line,
        self.text_h,
        self.d.ed.cursor.line,
        marks,
        needle,
    ) catch return;

    const theme = self.cfg.theme;
    const x0 = self.gutter_w + self.text_w;
    for (rows, 0..) |*row, r| {
        var style: vaxis.Style = switch (row.kind) {
            .normal => if (row.in_view and cl_bg == null) .{} else faint,
            .cursor => .{ .fg = accent, .bold = true },
            .search_hit => .{ .fg = warn, .bold = true },
            .git_added => .{ .fg = main.toVaxisColor(theme.git_neu) },
            .git_changed => .{ .fg = main.toVaxisColor(theme.git_geaendert) },
            .git_deleted => .{ .fg = main.toVaxisColor(theme.git_weg) },
        };
        if (row.in_view) {
            if (cl_bg) |bg| style.bg = bg;
        }
        for (0..iro.minimap.width) |c| {
            tw.writeCell(@intCast(x0 + c), @intCast(r), .{
                .char = .{ .grapheme = &row.cells[c], .width = 1 },
                .style = style,
            });
        }
    }
}

/// The command palette: a card at the top centre, input on the first row,
/// matches below with their key at the right edge.
fn drawPalette(self: *App, win: vaxis.Window, arena: Allocator) void {
    const p = &self.palette.?;
    const items = self.paletteItems();
    // Paths need more room than command names.
    const w: u16 = @min(@as(u16, if (p.mode == .commands) 66 else 96), win.width);
    const sep: u16 = if (win.height >= 7) 1 else 0;
    const max_rows: u16 = @min(12, win.height -| (5 + sep));
    const rows: u16 = @intCast(@min(items.len, max_rows));
    // Top and bottom border, the input line, optional divider, at least one row below.
    const h: u16 = @min(@max(rows, 1) + 3 + sep, win.height);
    const x: u16 = (win.width - w) / 2;
    const y: u16 = if (win.height > h + 1) 1 else 0;
    const accent = self.accentColor();
    const pink = self.pinkColor();
    const bg: vaxis.Color = cardBg(self) orelse .default;
    const sel_bg = cardSelBg(self);
    const box = win.child(.{ .x_off = x, .y_off = y, .width = w, .height = h, .border = .{
        .where = .all,
        .style = .{ .fg = accent, .bg = bg },
    } });
    box.fill(.{ .style = .{ .bg = bg } });

    const title: []const u8 = switch (p.mode) {
        .commands => ui(self, "Befehlspalette", "Command Palette"),
        .files => ui(self, "Dateisuche", "Find File"),
        .dirs => ui(self, "Ordner (zoxide)", "Folders (zoxide)"),
        .versions => ui(self, "Frühere Versionen", "Earlier Versions"),
    };
    const tw = win.gwidth(title) + 2;
    if (tw + 4 <= w) {
        const tx = x + (w - tw) / 2;
        _ = win.printSegment(.{ .text = " ", .style = .{ .bg = bg } }, .{ .row_offset = y, .col_offset = tx, .wrap = .none });
        _ = win.printSegment(.{ .text = title, .style = .{ .fg = accent, .bg = bg, .bold = true } }, .{ .row_offset = y, .col_offset = tx + 1, .wrap = .none });
        _ = win.printSegment(.{ .text = " ", .style = .{ .bg = bg } }, .{ .row_offset = y, .col_offset = tx + tw - 1, .wrap = .none });
    }

    // Input line
    const lead = box.printSegment(.{ .text = " › ", .style = .{ .fg = accent, .bg = bg, .bold = true } }, .{ .wrap = .none });
    if (p.input.items.len == 0) {
        const ask = switch (p.mode) {
            .commands => ui(self, "Befehl suchen …", "Search commands …"),
            .files => fileAsk(self, p, arena),
            .dirs => ui(self, "Ordner suchen (zoxide) …", "Search folders (zoxide) …"),
            .versions => fmtL(self, arena, "Frühere Versionen von {s} …", "Earlier versions of {s} …", .{self.d.name(self.lang)}),
        };
        _ = box.printSegment(.{ .text = ask, .style = .{ .bg = bg, .dim = true } }, .{ .col_offset = lead.col, .wrap = .none });
        box.showCursor(lead.col, 0);
    } else {
        const r = box.printSegment(.{ .text = text.cleanName(arena, p.input.items), .style = .{ .bg = bg } }, .{ .col_offset = lead.col, .wrap = .none });
        box.showCursor(@min(r.col, box.width -| 1), 0);
    }
    box.setCursorShape(.beam);
    // Top right: how many entries match, and whether the list is truncated.
    if (p.mode == .files) {
        const idx = p.idx;
        const total = if (idx) |i| i.entries.items.len else 0;
        const busy = if (idx) |i| !i.finished else false;
        const cut = if (idx) |i| i.truncated else false;
        const count = fmtL(self, arena, "{s}{s} von {s}{s}{s} ", "{s}{s} of {s}{s}{s} ", .{
            if (p.typo) "≈ " else "",
            groupDigits(arena, p.hits.items.len),
            groupDigits(arena, total),
            if (cut) "+" else "",
            if (busy) ui(self, " · liest ein …", " · indexing …") else "",
        });
        const cw = win.gwidth(count);
        if (cw + 26 < box.width) {
            _ = box.printSegment(.{ .text = count, .style = .{ .bg = bg, .dim = !p.typo, .fg = if (p.typo) self.warnColor() else .default } }, .{ .col_offset = box.width - cw, .wrap = .none });
        }
    } else if (p.mode != .commands) {
        const count = fmtL(self, arena, "{d} von {d}{s} ", "{d} of {d}{s} ", .{ items.len, p.all.len, if (p.truncated) "+" else "" });
        const cw = win.gwidth(count);
        if (cw + 30 < box.width) {
            _ = box.printSegment(.{ .text = count, .style = .{ .bg = bg, .dim = true } }, .{ .col_offset = box.width - cw, .wrap = .none });
        }
    }

    if (sep == 1 and box.height > 1) {
        var c: u16 = 1;
        while (c + 1 < box.width) : (c += 1) {
            box.writeCell(c, 1, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = .{ .fg = accent, .bg = bg, .dim = true } });
        }
    }

    self.pal_box = .{
        .x0 = x,
        .x1 = x + w,
        .y0 = y,
        .y1 = y + h,
        .x = x + 1,
        .y = y + 2 + sep,
        .w = box.width,
        .rows = rows,
    };
    if (items.len == 0) {
        _ = box.printSegment(.{ .text = ui(self, "   Nichts gefunden", "   Nothing found"), .style = .{ .bg = bg, .dim = true } }, .{ .row_offset = 1 + sep, .wrap = .none });
        return;
    }
    p.selected = @min(p.selected, items.len - 1);
    if (p.selected < p.top) p.top = p.selected;
    if (rows > 0 and p.selected >= p.top + rows) p.top = p.selected + 1 - rows;
    p.top = @min(p.top, items.len - rows);

    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        const item = items[p.top + r];
        const selected = p.top + r == p.selected;
        const row = r + 1 + sep;
        const line = box.child(.{ .y_off = row, .height = 1 });
        const row_bg: vaxis.Color = if (selected) (sel_bg orelse bg) else bg;
        const reverse = selected and sel_bg == null;
        if (selected) {
            line.fill(.{ .style = .{ .bg = row_bg, .reverse = reverse } });
            line.writeCell(0, 0, .{ .char = .{ .grapheme = "▌", .width = 1 }, .style = .{ .fg = accent, .bg = row_bg } });
        }
        const name_style: vaxis.Style = .{ .bg = row_bg, .bold = selected, .reverse = reverse };
        const clean = text.cleanName(arena, item.name);
        _ = line.printSegment(.{ .text = clean, .style = name_style }, .{ .col_offset = 3, .wrap = .none });
        // The key goes on the right if the name leaves room for it.
        const kw = win.gwidth(item.key);
        if (kw > 0 and 3 + win.gwidth(clean) + kw + 3 <= line.width) {
            const key_style: vaxis.Style = .{ .fg = pink, .bg = row_bg, .dim = !selected, .reverse = reverse };
            _ = line.printSegment(.{ .text = item.key, .style = key_style }, .{ .col_offset = line.width - kw - 2, .wrap = .none });
        }
    }
}

// ───────────── Cards: main menu and About ─────────────

/// Card background: a touch lighter than the terminal, like panels in windowed
/// applications. If iro doesn't know the terminal colours, the background stays
/// as it is.
fn cardBg(self: *const App) ?vaxis.Color {
    return App.mix(self.term_bg orelse return null, self.term_fg orelse return null, 8);
}

/// Background of the selected entry: accent, heavily blended with the card.
fn cardSelBg(self: *const App) ?vaxis.Color {
    const bg = self.term_bg orelse return null;
    const fg = self.term_fg orelse return null;
    const card = App.mix(bg, fg, 8).rgb;
    return App.mix(card, self.accentRgb() orelse return null, 30);
}

/// A card centred in `win`: rounded border in the accent colour, title at the
/// top, footer in the bottom border. Returns the inner area.
fn drawCard(self: *App, win: vaxis.Window, w: u16, h: u16, title: []const u8, footer: []const vaxis.Segment) struct { inner: vaxis.Window, x: u16, y: u16, w: u16, h: u16 } {
    const cw = @min(w, win.width);
    const ch = @min(h, win.height);
    const x = (win.width - cw) / 2;
    const y = (win.height - ch) / 2;
    const bg: vaxis.Color = cardBg(self) orelse .default;
    const accent = self.accentColor();
    const inner = win.child(.{ .x_off = x, .y_off = y, .width = cw, .height = ch, .border = .{
        .where = .all,
        .style = .{ .fg = accent, .bg = bg },
    } });
    inner.fill(.{ .style = .{ .bg = bg } });

    if (title.len > 0) {
        const tw = win.gwidth(title) + 2;
        if (tw + 4 <= cw) {
            const tx = x + (cw - tw) / 2;
            _ = win.printSegment(.{ .text = " ", .style = .{ .bg = bg } }, .{ .row_offset = y, .col_offset = tx, .wrap = .none });
            _ = win.printSegment(.{ .text = title, .style = .{ .fg = accent, .bg = bg, .bold = true } }, .{ .row_offset = y, .col_offset = tx + 1, .wrap = .none });
            _ = win.printSegment(.{ .text = " ", .style = .{ .bg = bg } }, .{ .row_offset = y, .col_offset = tx + tw - 1, .wrap = .none });
        }
    }
    if (footer.len > 0 and ch >= 2) {
        var fw: u16 = 2;
        for (footer) |seg| fw += win.gwidth(seg.text);
        if (fw + 4 <= cw) {
            var col = x + (cw - fw) / 2;
            const row = y + ch - 1;
            _ = win.printSegment(.{ .text = " ", .style = .{ .bg = bg } }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
            col += 1;
            for (footer) |seg| {
                var st = seg.style;
                st.bg = bg;
                const r = win.printSegment(.{ .text = seg.text, .style = st, .link = seg.link }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
                col = r.col;
            }
            _ = win.printSegment(.{ .text = " ", .style = .{ .bg = bg } }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
        }
    }
    return .{ .inner = inner, .x = x, .y = y, .w = cw, .h = ch };
}

/// The main menu: icon, name with underlined letter, key on the right.
fn drawMenu(self: *App, win: vaxis.Window, arena: Allocator) void {
    const menu = iro.menu;
    const pink = self.pinkColor();
    const accent = self.accentColor();
    const bg: vaxis.Color = cardBg(self) orelse .default;
    const sel_bg = cardSelBg(self);
    const sig = [_]vaxis.Segment{
        .{ .text = "♥", .style = .{ .fg = pink } },
        .{ .text = " Mausmann", .style = .{ .dim = true } },
    };
    // One blank row above and below, plus the border. When space runs short,
    // the padding goes first.
    const want_h: u16 = menu.entries.len + 4;
    const pad: u16 = if (win.height >= want_h + 2) 1 else 0;
    const h: u16 = @intCast(menu.entries.len + 2 + 2 * @as(usize, pad));
    const title = std.fmt.allocPrint(arena, "色 IRO {s}", .{main.version}) catch "色 IRO";
    const card = drawCard(self, win, 44, h, title, &sig);
    const inner = card.inner;
    self.menu_box = .{
        .x0 = card.x,
        .x1 = card.x + card.w,
        .y0 = card.y,
        .y1 = card.y + card.h,
        .first_row = card.y + 1 + pad,
    };

    for (menu.entries, 0..) |e, i| {
        const row: u16 = @intCast(i + pad);
        if (row >= inner.height) break;
        const line = inner.child(.{ .y_off = row, .height = 1 });
        const cmd = e.cmd orelse {
            // Separator with a little distance from the border.
            var c: u16 = 2;
            while (c + 2 < line.width) : (c += 1) {
                line.writeCell(c, 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = .{ .fg = accent, .bg = bg, .dim = true } });
            }
            continue;
        };
        const selected = i == self.menu_sel;
        const row_bg: vaxis.Color = if (selected) (sel_bg orelse bg) else bg;
        const reverse = selected and sel_bg == null;
        if (selected) {
            line.fill(.{ .style = .{ .bg = row_bg, .reverse = reverse } });
            line.writeCell(0, 0, .{ .char = .{ .grapheme = "▌", .width = 1 }, .style = .{ .fg = accent, .bg = row_bg } });
        }
        var col: u16 = 2;
        if (self.cfg.symbols) {
            // Nerd Font icons are exactly one cell wide, whatever the width
            // table thinks about the private use area.
            line.writeCell(col, 0, .{ .char = .{ .grapheme = e.icon, .width = 1 }, .style = .{ .fg = if (selected) accent else pink, .bg = row_bg, .reverse = reverse } });
            col += 3;
        }
        const base: vaxis.Style = .{ .bg = row_bg, .bold = selected, .reverse = reverse };
        const label = e.label.in(self.lang);
        if (menu.hotSpan(e, self.lang)) |hs| {
            const before = label[0..hs.start];
            const hot = label[hs.start..][0..hs.len];
            const after = label[hs.start + hs.len ..];
            var hot_style = base;
            hot_style.ul_style = .single;
            hot_style.fg = accent;
            col = line.printSegment(.{ .text = before, .style = base }, .{ .col_offset = col, .wrap = .none }).col;
            col = line.printSegment(.{ .text = hot, .style = hot_style }, .{ .col_offset = col, .wrap = .none }).col;
            _ = line.printSegment(.{ .text = after, .style = base }, .{ .col_offset = col, .wrap = .none });
        } else {
            _ = line.printSegment(.{ .text = label, .style = base }, .{ .col_offset = col, .wrap = .none });
        }
        const key = self.cfg.keyLabel(cmd);
        if (key.len > 0) {
            const kw = win.gwidth(key);
            if (kw + 24 < line.width) {
                _ = line.printSegment(.{ .text = key, .style = .{ .fg = pink, .bg = row_bg, .dim = !selected, .reverse = reverse } }, .{ .col_offset = line.width - kw - 2, .wrap = .none });
            }
        }
    }
}

/// The settings page: a long list with headings, values on the right, one
/// sentence of explanation for the selected entry at the bottom.
fn drawSettings(self: *App, win: vaxis.Window, arena: Allocator) void {
    const S = iro.settings;
    const accent = self.accentColor();
    const pink = self.pinkColor();
    const bg: vaxis.Color = cardBg(self) orelse .default;
    const sel_bg = cardSelBg(self);
    const foot = [_]vaxis.Segment{
        .{ .text = "gewaehlt.lua", .style = .{ .fg = accent } },
        .{ .text = ui(self, " · init.lua hat das letzte Wort", " · init.lua has the final say"), .style = .{ .dim = true } },
    };
    const w: u16 = @min(80, win.width -| 2);
    const h: u16 = if (win.height >= 10) win.height - 2 else win.height;
    const card = drawCard(self, win, w, h, ui(self, "Einstellungen", "Settings"), &foot);
    const inner = card.inner;
    if (inner.height < 3 or inner.width < 30) return;

    const desc_h: u16 = if (inner.height >= 12) 3 else 0;
    const list_h: u16 = inner.height - desc_h;
    // Keep the selected entry visible, and its heading too if possible.
    self.set_top = S.keepVisible(self.set_sel, self.set_top, list_h);
    self.set_box = .{
        .x0 = card.x,
        .x1 = card.x + card.w,
        .y0 = card.y,
        .y1 = card.y + card.h,
        .list_y = card.y + 1,
        .list_h = list_h,
    };

    var r: u16 = 0;
    while (r < list_h) : (r += 1) {
        const i = self.set_top + r;
        if (i >= S.items.len) break;
        const item = S.items[i];
        const line = inner.child(.{ .y_off = r, .height = 1 });
        if (item.kind == .header) {
            const end = line.printSegment(.{ .text = item.label.in(self.lang), .style = .{ .fg = accent, .bg = bg, .bold = true } }, .{ .col_offset = 2, .wrap = .none }).col;
            var c: u16 = end + 1;
            while (c + 2 < line.width) : (c += 1) {
                line.writeCell(c, 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = .{ .fg = accent, .bg = bg, .dim = true } });
            }
            continue;
        }
        const selected = i == self.set_sel;
        const row_bg: vaxis.Color = if (selected) (sel_bg orelse bg) else bg;
        const reverse = selected and sel_bg == null;
        if (selected) {
            line.fill(.{ .style = .{ .bg = row_bg, .reverse = reverse } });
            line.writeCell(0, 0, .{ .char = .{ .grapheme = "▌", .width = 1 }, .style = .{ .fg = accent, .bg = row_bg } });
        }
        const pinned = settingPinned(self, item);
        // • = changed on this page (stored in gewaehlt.lua).
        if (item.lua.len > 0 and self.chosen.has(item.lua, item.kind == .key) and !pinned) {
            line.writeCell(2, 0, .{ .char = .{ .grapheme = "•", .width = 1 }, .style = .{ .fg = pink, .bg = row_bg, .reverse = reverse } });
        }
        _ = line.printSegment(.{ .text = item.label.in(self.lang), .style = .{ .bg = row_bg, .bold = selected, .reverse = reverse } }, .{ .col_offset = 4, .wrap = .none });

        // Right: the value.
        var val: []const u8 = "";
        var val_style: vaxis.Style = .{ .bg = row_bg, .reverse = reverse };
        switch (item.kind) {
            .toggle => {
                const on = if (self.cfg.boolPtr(item.lua)) |ptr| ptr.* else false;
                val = if (on) ui(self, "● an ", "● on ") else ui(self, "○ aus", "○ off");
                if (on) val_style.fg = accent else val_style.dim = true;
            },
            .theme => {
                val = std.fmt.allocPrint(arena, "‹ {s} ›", .{self.cfg.theme_name}) catch "";
                val_style.fg = accent;
            },
            .tab_width => {
                val = std.fmt.allocPrint(arena, "‹ {d} ›", .{self.cfg.tab_width}) catch "";
                val_style.fg = accent;
            },
            .indent => {
                val = std.fmt.allocPrint(arena, "‹ {s} ›", .{S.indentName(self.cfg.soft_tabs, self.lang)}) catch "";
                val_style.fg = accent;
            },
            .gear => {
                val = std.fmt.allocPrint(arena, "‹ {s} ›", .{S.gearName(self.cfg.gear, self.lang)}) catch "";
                val_style.fg = accent;
            },
            .language => {
                val = std.fmt.allocPrint(arena, "‹ {s} ›", .{S.languageName(self.cfg.language, self.lang)}) catch "";
                val_style.fg = accent;
            },
            .key => {
                if (selected and self.set_capture) {
                    val = ui(self, "drück eine Taste …", "press a key …");
                    val_style.fg = accent;
                    val_style.bold = true;
                } else {
                    const k = self.cfg.keyLabel(item.cmd.?);
                    val = if (k.len > 0) k else "—";
                    if (k.len > 0) val_style.fg = pink else val_style.dim = true;
                }
            },
            .open_init => {
                val = "↵";
                val_style.dim = true;
            },
            .header => {},
        }
        if (pinned) {
            val_style.dim = true;
            val = std.fmt.allocPrint(arena, "{s}init.lua  {s}", .{ if (self.cfg.symbols) "\u{f023} " else "", val }) catch val;
        }
        const vw = win.gwidth(val);
        if (vw + 30 <= line.width) {
            _ = line.printSegment(.{ .text = val, .style = val_style }, .{ .col_offset = line.width - vw - 2, .wrap = .none });
        }
    }
    // Arrows when there is more above or below.
    const faint: vaxis.Style = .{ .fg = accent, .bg = bg, .dim = true };
    if (self.set_top > 0) inner.writeCell(inner.width - 1, 0, .{ .char = .{ .grapheme = "▲", .width = 1 }, .style = faint });
    if (self.set_top + list_h < S.items.len) inner.writeCell(inner.width - 1, list_h - 1, .{ .char = .{ .grapheme = "▼", .width = 1 }, .style = faint });

    if (desc_h > 0 and S.selectable(self.set_sel)) {
        var c: u16 = 2;
        while (c + 2 < inner.width) : (c += 1) {
            inner.writeCell(c, list_h, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = faint });
        }
        const item = S.items[self.set_sel];
        const say = if (settingPinned(self, item))
            fmtL(self, arena, "Steht in deiner init.lua und gilt von dort, ändern geht nur dort. {s}", "Set in your init.lua and applied from there, change it there. {s}", .{item.say.in(self.lang)})
        else
            item.say.in(self.lang);
        const box = inner.child(.{ .x_off = 2, .y_off = list_h + 1, .width = inner.width -| 4, .height = 2 });
        _ = box.printSegment(.{ .text = say, .style = .{ .bg = bg, .dim = true } }, .{ .wrap = .word });
    }
}

fn settingPinned(self: *const App, item: iro.settings.Item) bool {
    if (item.cmd) |c| return self.cfg.keyPinned(c);
    return item.lua.len > 0 and self.cfg.isPinned(item.lua);
}

/// About: line by line, character by character, as if just decrypted.
fn drawAbout(self: *App, win: vaxis.Window, arena: Allocator) void {
    const rev = &(self.about orelse return);
    const ls = iro.about.lines(arena, main.version, self.lang) catch return;
    var max_w: u16 = 0;
    for (ls) |l| max_w = @max(max_w, win.gwidth(l.text));
    const h: u16 = @intCast(ls.len + 4);
    const foot = [_]vaxis.Segment{.{ .text = ui(self, "Taste drücken", "Press any key"), .style = .{ .dim = true } }};
    const card = drawCard(self, win, max_w + 10, h, ui(self, "Über iro", "About iro"), &foot);
    const inner = card.inner;

    const accent = self.accentColor();
    const pink = self.pinkColor();
    const bg: vaxis.Color = cardBg(self) orelse .default;
    const known = self.term_bg != null and self.term_fg != null and self.accentRgb() != null;
    // Scramble: dimmed accent. Afterglow: brightened accent.
    const noise_style: vaxis.Style = if (known)
        .{ .fg = App.mix(self.term_bg.?, self.accentRgb().?, 55), .bg = bg }
    else
        .{ .fg = accent, .bg = bg, .dim = true };
    const glow_style: vaxis.Style = if (known)
        .{ .fg = App.mix(self.accentRgb().?, self.term_fg.?, 55), .bg = bg, .bold = true }
    else
        .{ .fg = accent, .bg = bg, .bold = true };

    var idx: usize = 0;
    for (ls, 0..) |l, li| {
        const row: u16 = @intCast(li + 1);
        const lw = win.gwidth(l.text);
        var col: u16 = (inner.width -| lw) / 2;
        const link: vaxis.Cell.Hyperlink = if (l.kind == .coffee and iro.about.kofi_url.len > 0) .{ .uri = iro.about.kofi_url } else .{};
        var it = std.unicode.Utf8View.initUnchecked(l.text).iterator();
        var first = true;
        while (it.nextCodepointSlice()) |g| : (idx += 1) {
            const gw: u16 = @max(win.gwidth(g), 1);
            defer col += gw;
            defer first = false;
            if (row >= inner.height or col + gw > inner.width) continue;
            const final: vaxis.Style = switch (l.kind) {
                .title => if (std.mem.eql(u8, g, "色")) .{ .fg = pink, .bg = bg, .bold = true } else .{ .fg = accent, .bg = bg, .bold = true },
                .subtitle, .dim, .legal => .{ .bg = bg, .dim = true },
                .heart, .coffee => if (first) .{ .fg = pink, .bg = bg } else .{ .bg = bg },
                .normal, .blank => .{ .bg = bg },
            };
            switch (rev.phase(idx)) {
                .hidden => {},
                .noise => {
                    var sub: u16 = 0;
                    while (sub < gw) : (sub += 1) {
                        inner.writeCell(col + sub, row, .{ .char = .{ .grapheme = rev.noise(idx, sub), .width = 1 }, .style = noise_style });
                    }
                },
                .glow => inner.writeCell(col, row, .{ .char = .{ .grapheme = g, .width = @intCast(gw) }, .style = glow_style, .link = link }),
                .shown => inner.writeCell(col, row, .{ .char = .{ .grapheme = g, .width = @intCast(gw) }, .style = final, .link = link }),
            }
        }
    }
}

/// What the empty search box shows: where the search looks.
fn fileAsk(self: *const App, p: *const main.Palette, arena: Allocator) []const u8 {
    if (p.n_scopes == 0) return ui(self, "Datei suchen …", "Find file …");
    const sc = p.scopes[p.scope];
    const home = self.env.get("HOME") orelse "";
    const where = switch (sc.kind) {
        .home => ui(self, "deinem ganzen Home", "your whole home"),
        .project => fmtL(self, arena, "Projekt {s}", "project {s}", .{std.fs.path.basename(sc.root)}),
        .folder => if (home.len > 1 and std.mem.startsWith(u8, sc.root, home))
            std.fmt.allocPrint(arena, "~{s}", .{sc.root[home.len..]}) catch sc.root
        else
            sc.root,
    };
    const other = if (p.n_scopes > 1) (if (sc.kind == .home) ui(self, " (Strg+O: zurück)", " (Ctrl+O: back)") else ui(self, " (Strg+O: ganzes Home)", " (Ctrl+O: whole home)")) else "";
    return fmtL(self, arena, "Datei suchen in {s} …{s}", "Find file in {s} …{s}", .{ where, other });
}

/// 348003 → "348 003", grouped for readability.
fn groupDigits(arena: Allocator, n: usize) []const u8 {
    var raw: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&raw, "{d}", .{n}) catch return "";
    var out: std.ArrayList(u8) = .empty;
    for (digits, 0..) |c, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) out.append(arena, ' ') catch return digits;
        out.append(arena, c) catch return digits;
    }
    return out.items;
}

fn drawTabs(self: *App, win: vaxis.Window, arena: Allocator) void {
    const accent = self.accentColor();
    const docs = self.docs.items;
    const labels = arena.alloc([]const u8, docs.len) catch return;
    const widths = arena.alloc(u16, docs.len) catch return;
    const spans = arena.alloc(TabSpan, docs.len) catch return;
    for (docs, 0..) |doc, i| {
        labels[i] = std.fmt.allocPrint(arena, " {s}{s}{s} ", .{
            if (doc.path != null) iro.icons.forEntry(self.cfg.symbols, doc.name(self.lang), false, false) else "",
            text.cleanName(arena, doc.name(self.lang)),
            if (doc.ed.isModified()) " ●" else "",
        }) catch " ? ";
        widths[i] = win.gwidth(labels[i]);
    }
    // If not all tabs fit on the line, the bar scrolls left far enough to show
    // the active tab completely.
    var first: usize = 0;
    while (first < self.cur) : (first += 1) {
        var sum: usize = 0;
        for (widths[first .. self.cur + 1]) |w| sum += w;
        if (sum <= win.width) break;
    }
    var x: u16 = 0;
    var count: usize = 0;
    var i = first;
    while (i < docs.len and x < win.width) : (i += 1) {
        const style: vaxis.Style = if (i == self.cur)
            .{ .fg = accent, .reverse = true, .bold = true }
        else
            .{ .dim = true };
        const r = win.printSegment(.{ .text = labels[i], .style = style }, .{ .col_offset = x, .wrap = .none });
        const end: u16 = @min(x + widths[i], win.width);
        spans[count] = .{ .x0 = x, .x1 = end, .index = i };
        count += 1;
        _ = r;
        x = end;
    }
    self.tab_spans = spans[0..count];
}

fn drawTree(self: *App, win: vaxis.Window, arena: Allocator) void {
    const accent = self.accentColor();
    const t = &self.tree.?;
    const w: u16 = @intCast(self.tree_w - 1);
    const h: u16 = @intCast(self.text_h);
    const focused = self.focus == .tree;
    const panel = win.child(.{ .width = w, .height = h });

    // Separator to the text. Lit while keys go to the tree.
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        win.writeCell(w, y, .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = if (focused) .{ .fg = accent } else .{ .dim = true },
        });
    }

    // Header: the current folder. Clicking it goes up one level.
    const base = std.fs.path.basename(t.root);
    const head = std.fmt.allocPrint(arena, " ↑ {s}", .{if (base.len > 0) base else "/"}) catch "";
    _ = panel.printSegment(.{ .text = text.cleanName(arena, head), .style = .{ .fg = accent, .bold = true } }, .{ .wrap = .none });

    const rows = self.text_h -| 1;
    const n = t.entries.items.len;
    if (n == 0) {
        _ = panel.printSegment(.{ .text = ui(self, "   (leer)", "   (empty)"), .style = .{ .dim = true } }, .{ .row_offset = 1, .wrap = .none });
        return;
    }
    if (self.tree_follow and rows > 0) {
        if (t.selected < self.tree_top) self.tree_top = t.selected;
        if (t.selected >= self.tree_top + rows) self.tree_top = t.selected + 1 - rows;
    }
    self.tree_top = @min(self.tree_top, n -| rows);

    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const i = self.tree_top + r;
        if (i >= n) break;
        const e = t.entries.items[i];
        const row: u16 = @intCast(r + 1);
        const selected = focused and i == t.selected;

        // The file currently open in the editor is shown in bold.
        var is_open = false;
        if (!e.is_dir) {
            if (self.d.path) |cur| {
                if (t.pathOf(arena, i)) |p| is_open = std.mem.eql(u8, p, cur) else |_| {}
            }
        }
        const indent = arena.alloc(u8, @as(usize, @min(e.depth, 12)) * 2) catch "";
        @memset(@constCast(indent), ' ');
        const mark: []const u8 = if (!e.is_dir) " " else if (e.expanded) "▾" else "▸";
        const sym = iro.icons.forEntry(self.cfg.symbols, e.name, e.is_dir, e.expanded);
        const line = std.fmt.allocPrint(arena, " {s}{s} {s}{s}", .{ indent, mark, sym, text.cleanName(arena, e.name) }) catch continue;

        var style: vaxis.Style = .{ .reverse = selected, .bold = is_open };
        if (e.is_dir) style.fg = accent;
        if (selected) panel.child(.{ .y_off = row, .height = 1 }).fill(.{ .style = style });
        _ = panel.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row, .wrap = .none });
    }
}

/// Which keys are useful right now? Depends on where you are: in the text, in a
/// selection, in the tree or in an input line. The most important come first,
/// since the end gets cut off.
fn addHint(list: *std.ArrayList(Hint), arena: Allocator, key: []const u8, label: Text) void {
    if (key.len == 0) return;
    list.append(arena, .{ .key = key, .label = label }) catch {};
}

fn addCmdHint(self: *const App, list: *std.ArrayList(Hint), arena: Allocator, cmd: Cmd, label: Text) void {
    addHint(list, arena, self.cfg.shortKey(arena, cmd), label);
}

fn addTabCycleHint(self: *const App, list: *std.ArrayList(Hint), arena: Allocator) void {
    const next_k = self.cfg.shortKey(arena, .next_tab);
    const prev_k = self.cfg.shortKey(arena, .prev_tab);
    const pg = (std.mem.eql(u8, next_k, "^Bild ab") and std.mem.eql(u8, prev_k, "^Bild auf")) or
        (std.mem.eql(u8, next_k, "^PgDn") and std.mem.eql(u8, prev_k, "^PgUp"));
    if (pg) {
        addHint(list, arena, ui(self, "^Bild↕", "^Pg↕"), .{ .de = "Tab wechseln", .en = "Switch tab" });
    } else if (next_k.len > 0 and prev_k.len > 0) {
        const combo = std.fmt.allocPrint(arena, "{s}/{s}", .{ next_k, prev_k }) catch next_k;
        addHint(list, arena, combo, .{ .de = "Tab wechseln", .en = "Switch tab" });
    } else if (next_k.len > 0) {
        addHint(list, arena, next_k, .{ .de = "Nächster Tab", .en = "Next tab" });
    } else if (prev_k.len > 0) {
        addHint(list, arena, prev_k, .{ .de = "Vorheriger Tab", .en = "Previous tab" });
    }
}

fn currentHints(self: *App, arena: Allocator) []const Hint {
    var list: std.ArrayList(Hint) = .empty;
    const many = self.docs.items.len > 1;
    if (self.about != null) return &.{
        .{ .key = "Taste", .key_en = "Key", .label = .{ .de = "Schließen", .en = "Close" } },
    };
    if (self.settings_open and self.set_capture) return &.{
        .{ .key = "Taste", .key_en = "Key", .label = .{ .de = "Neu belegen", .en = "Rebind" } },
        .{ .key = "Entf", .key_en = "Del", .label = .{ .de = "Keine Taste", .en = "No key" } },
        .{ .key = "Esc", .label = .{ .de = "Abbrechen", .en = "Cancel" } },
    };
    if (self.settings_open) return &.{
        .{ .key = "↑↓", .label = .{ .de = "Wählen", .en = "Select" } },
        .{ .key = "Enter", .label = .{ .de = "Ändern", .en = "Change" } },
        .{ .key = "←→", .label = .{ .de = "Durchschalten", .en = "Cycle" } },
        .{ .key = "Entf", .key_en = "Del", .label = .{ .de = "Vorgabe", .en = "Default" } },
        .{ .key = "Esc", .label = .{ .de = "Schließen", .en = "Close" } },
    };
    if (self.menu_open) return &.{
        .{ .key = "↑↓", .label = .{ .de = "Wählen", .en = "Select" } },
        .{ .key = "Enter", .label = .{ .de = "Ausführen", .en = "Run" } },
        .{ .key = "Buchstabe", .key_en = "Letter", .label = .{ .de = "Direkt wählen", .en = "Pick directly" } },
        .{ .key = "Esc", .label = .{ .de = "Schließen", .en = "Close" } },
    };
    if (self.palette) |pal| {
        return switch (pal.mode) {
            .commands => &.{
                .{ .key = "↑↓", .label = .{ .de = "Wählen", .en = "Select" } },
                .{ .key = "Enter", .label = .{ .de = "Ausführen", .en = "Run" } },
                .{ .key = "Esc", .label = .{ .de = "Schließen", .en = "Close" } },
                .{ .key = "^⌫", .label = .{ .de = "Eingabe leeren", .en = "Clear input" } },
            },
            // One label here depends on state, so build the list in the frame
            // arena: an `&.{ … }` with runtime values would live on the stack
            // and be garbage after returning.
            .files => blk: {
                addHint(&list, arena, "↑↓", .{ .de = "Wählen", .en = "Select" });
                addHint(&list, arena, "Enter", .{ .de = "Öffnen", .en = "Open" });
                if (pal.n_scopes > 1) {
                    addHint(&list, arena, "^O", if (pal.scopes[pal.scope].kind == .home) .{ .de = "Zurück ins Projekt", .en = "Back to project" } else .{ .de = "Ganzes Home", .en = "Whole home" });
                }
                addHint(&list, arena, "Tab", .{ .de = "Pfad tippen", .en = "Type a path" });
                addHint(&list, arena, "Esc", .{ .de = "Schließen", .en = "Close" });
                break :blk list.items;
            },
            .dirs => &.{
                .{ .key = "↑↓", .label = .{ .de = "Wählen", .en = "Select" } },
                .{ .key = "Enter", .label = .{ .de = "Dorthin, dann Datei suchen", .en = "Go there, then find file" } },
                .{ .key = "Esc", .label = .{ .de = "Schließen", .en = "Close" } },
            },
            .versions => &.{
                .{ .key = "↑↓", .label = .{ .de = "Wählen", .en = "Select" } },
                .{ .key = "Enter", .label = .{ .de = "Zurückholen (nur in den Text)", .en = "Bring back (into the text only)" } },
                .{ .key = "Esc", .label = .{ .de = "Schließen", .en = "Close" } },
            },
        };
    }
    if (self.prompt) |p| {
        return switch (p.kind) {
            .search => &.{
                .{ .key = "Enter", .label = .{ .de = "Weiter", .en = "Next" } },
                .{ .key = "↑", .label = .{ .de = "Zurück", .en = "Back" } },
                .{ .key = "Esc", .label = .{ .de = "Schließen", .en = "Close" } },
                .{ .key = "^⌫", .label = .{ .de = "Eingabe leeren", .en = "Clear input" } },
            },
            .save_as, .open => &.{
                .{ .key = "Enter", .label = .{ .de = "Bestätigen", .en = "Confirm" } },
                .{ .key = "Tab", .label = .{ .de = "Vervollständigen", .en = "Complete" } },
                .{ .key = "Esc", .label = .{ .de = "Abbrechen", .en = "Cancel" } },
                .{ .key = "^⌫", .label = .{ .de = "Eingabe leeren", .en = "Clear input" } },
            },
            .replace_find => &.{
                .{ .key = "Enter", .label = .{ .de = "Weiter zum Ersatz", .en = "On to replacement" } },
                .{ .key = "↓↑", .label = .{ .de = "Treffer ansehen", .en = "Browse matches" } },
                .{ .key = "Esc", .label = .{ .de = "Abbrechen", .en = "Cancel" } },
            },
            .goto_line, .tree_new_file, .tree_new_dir, .tree_rename, .replace_with => &.{
                .{ .key = "Enter", .label = .{ .de = "Bestätigen", .en = "Confirm" } },
                .{ .key = "Esc", .label = .{ .de = "Abbrechen", .en = "Cancel" } },
                .{ .key = "^⌫", .label = .{ .de = "Eingabe leeren", .en = "Clear input" } },
            },
            // Prompts name their own keys.
            else => &.{},
        };
    }
    if (self.focus == .text and self.d.ed.selection() != null) {
        addCmdHint(self, &list, arena, .copy, .{ .de = "Kopieren", .en = "Copy" });
        addCmdHint(self, &list, arena, .cut, .{ .de = "Ausschneiden", .en = "Cut" });
        addCmdHint(self, &list, arena, .paste, .{ .de = "Ersetzen", .en = "Replace" });
        addCmdHint(self, &list, arena, .search, .{ .de = "Danach suchen", .en = "Search for it" });
        addHint(&list, arena, "Tab", .{ .de = "Einrücken", .en = "Indent" });
        addHint(&list, arena, "⇧Tab", .{ .de = "Ausrücken", .en = "Outdent" });
        addCmdHint(self, &list, arena, .comment, .{ .de = "Kommentar", .en = "Comment" });
        addHint(&list, arena, "Esc", .{ .de = "Aufheben", .en = "Deselect" });
        return list.items;
    }

    var base: std.ArrayList(Hint) = .empty;
    if (self.focus == .tree) {
        addHint(&base, arena, "Enter", .{ .de = "Öffnen", .en = "Open" });
        addHint(&base, arena, "←→", .{ .de = "Auf/Zu", .en = "Expand" });
        addCmdHint(self, &base, arena, .tree_new_file, .{ .de = "Neue Datei", .en = "New file" });
        addCmdHint(self, &base, arena, .tree_new_dir, .{ .de = "Neuer Ordner", .en = "New folder" });
        addCmdHint(self, &base, arena, .tree_rename, .{ .de = "Umbenennen", .en = "Rename" });
        addCmdHint(self, &base, arena, .tree_trash, .{ .de = "Papierkorb", .en = "Trash" });
        addHint(&base, arena, "⌫", .{ .de = "Ebene hoch", .en = "Up a level" });
        addCmdHint(self, &base, arena, .tree_hidden, .{ .de = "Versteckte", .en = "Hidden" });
        addHint(&base, arena, "Esc", .{ .de = "Zum Text", .en = "To text" });
        addCmdHint(self, &base, arena, .tree, .{ .de = "Baum weg", .en = "Hide tree" });
        addCmdHint(self, &base, arena, .tree_refresh, .{ .de = "Neu lesen", .en = "Reload" });
    } else {
        addCmdHint(self, &base, arena, .save, .{ .de = "Speichern", .en = "Save" });
        addCmdHint(self, &base, arena, .quit, .{ .de = "Beenden", .en = "Quit" });
        addCmdHint(self, &base, arena, .palette, .{ .de = "Befehle", .en = "Commands" });
        addCmdHint(self, &base, arena, .help, .{ .de = "Hilfe", .en = "Help" });
        addCmdHint(self, &base, arena, .search, .{ .de = "Suchen", .en = "Find" });
        addCmdHint(self, &base, arena, .undo, .{ .de = "Rückgängig", .en = "Undo" });
        addCmdHint(self, &base, arena, .tree, if (self.tree_w > 0) .{ .de = "Zum Baum", .en = "To tree" } else .{ .de = "Baum", .en = "Tree" });
        addCmdHint(self, &base, arena, .open, .{ .de = "Öffnen", .en = "Open" });
    }

    // Tab keys work in the text and in the tree. With several tabs open they
    // move to the front so they fit even in a narrow window.
    const head = @min(base.items.len, if (self.focus == .text) @as(usize, 3) else 2);
    list.appendSlice(arena, base.items[0..head]) catch return &.{};
    if (many) {
        addTabCycleHint(self, &list, arena);
        addCmdHint(self, &list, arena, .close_tab, .{ .de = "Tab zu", .en = "Close tab" });
    }
    list.appendSlice(arena, base.items[head..]) catch {};
    if (!many) addCmdHint(self, &list, arena, .new_tab, .{ .de = "Neuer Tab", .en = "New tab" });
    if (self.focus == .text) {
        addCmdHint(self, &list, arena, .replace, .{ .de = "Ersetzen", .en = "Replace" });
        addCmdHint(self, &list, arena, .cut, .{ .de = "Zeile ausschneiden", .en = "Cut line" });
        addCmdHint(self, &list, arena, .comment, .{ .de = "Kommentar", .en = "Comment" });
        addCmdHint(self, &list, arena, .goto_line, .{ .de = "Gehe zu Zeile", .en = "Go to line" });
    }
    return list.items;
}

/// The hint bar: keys as small badges, dimmed text next to them saying what
/// they do. At the far right: how to hide it.
fn drawHints(self: *App, win: vaxis.Window, arena: Allocator) void {
    const y: u16 = win.height - 2;
    const key_style: vaxis.Style = .{ .fg = self.pinkColor(), .reverse = true, .bold = true };
    const label_style: vaxis.Style = .{ .dim = true };

    const hints_key = self.cfg.shortKey(arena, .hints);
    const off_badge = if (hints_key.len > 0) std.fmt.allocPrint(arena, " {s} ", .{hints_key}) catch " F1 " else "";
    const off_label = ui(self, " Hinweise aus ", " Hints off ");
    const off_w: u16 = if (off_badge.len > 0) win.gwidth(off_badge) + win.gwidth(off_label) else 0;
    var limit: u16 = win.width;
    if (off_w > 0 and win.width > off_w + 30) {
        limit = win.width - off_w - 1;
        const r = win.printSegment(.{ .text = off_badge, .style = key_style }, .{ .row_offset = y, .col_offset = limit + 1, .wrap = .none });
        _ = win.printSegment(.{ .text = off_label, .style = label_style }, .{ .row_offset = y, .col_offset = r.col, .wrap = .none });
    }

    var x: u16 = 1;
    for (currentHints(self, arena)) |h| {
        const k = if (self.lang == .en) (h.key_en orelse h.key) else h.key;
        const key = std.fmt.allocPrint(arena, " {s} ", .{k}) catch return;
        const label = std.fmt.allocPrint(arena, " {s}", .{h.label.in(self.lang)}) catch return;
        const w = win.gwidth(key) + win.gwidth(label);
        if (x + w > limit) break;
        _ = win.printSegment(.{ .text = key, .style = key_style }, .{ .row_offset = y, .col_offset = x, .wrap = .none });
        _ = win.printSegment(.{ .text = label, .style = label_style }, .{ .row_offset = y, .col_offset = x + win.gwidth(key), .wrap = .none });
        x += w + 2;
    }
}

fn drawStatus(self: *App, win: vaxis.Window, arena: Allocator) void {
    const y: u16 = win.height - 1;
    const ed = &self.d.ed;
    var x: u16 = 0;
    const put = struct {
        fn f(w: vaxis.Window, col: *u16, row: u16, s: []const u8, style: vaxis.Style) void {
            if (col.* >= w.width) return;
            const r = w.printSegment(.{ .text = s, .style = style }, .{ .row_offset = row, .col_offset = col.*, .wrap = .none });
            col.* = r.col;
        }
    }.f;

    if (self.prompt) |p| {
        const target = std.fs.path.basename(self.tree_target orelse "");
        const label: []const u8 = switch (p.kind) {
            .search => ui(self, " Suchen: ", " Find: "),
            .save_as => ui(self, " Speichern als: ", " Save as: "),
            .goto_line => ui(self, " Gehe zu Zeile: ", " Go to line: "),
            .open => ui(self, " Öffnen: ", " Open: "),
            .tree_new_file => fmtL(self, arena, " Neue Datei in {s}/: ", " New file in {s}/: ", .{target}),
            .tree_new_dir => fmtL(self, arena, " Neuer Ordner in {s}/: ", " New folder in {s}/: ", .{target}),
            .tree_rename => ui(self, " Umbenennen in: ", " Rename to: "),
            .confirm_trash => fmtL(self, arena, " {s} in den Papierkorb legen?  [J]a  [N]ein ", " Move {s} to the trash?  [Y]es  [N]o ", .{target}),
            .confirm_quit, .confirm_close => fmtL(self, arena, " Ungespeicherte Änderungen in {s}.  [S]peichern  [V]erwerfen  [A]bbrechen ", " Unsaved changes in {s}.  [S]ave  [D]iscard  [C]ancel ", .{self.fileName()}),
            .confirm_overwrite => ui(self, " Die Datei wurde außerhalb von iro geändert. Trotzdem überschreiben?  [J]a  [N]ein  [L]aden ", " The file was changed outside of iro. Overwrite anyway?  [Y]es  [N]o  [L]oad "),
            .confirm_guard => fmtL(self, arena, " Config Guard ({s}): [J]a, trotzdem  [N]ein — {s} ", " Config Guard ({s}): [Y]es, save anyway  [N]o — {s} ", .{ self.guard_tool, self.guard_err orelse "" }),
            .recover => ui(self, " Sicherung nach Absturz gefunden.  [W]iederherstellen  [V]erwerfen ", " Backup found after a crash.  [R]estore  [D]iscard "),
            .confirm_replace_file => fmtL(self, arena, " {s} gibt es schon. Ersetzen?  [J]a  [N]ein ", " {s} already exists. Replace it?  [Y]es  [N]o ", .{text.cleanName(arena, std.fs.path.basename(self.pending_save_as orelse ""))}),
            .replace_find => ui(self, " Ersetzen – suche: ", " Replace – find: "),
            .replace_with => fmtL(self, arena, " „{s}“ ersetzen durch: ", " Replace \"{s}\" with: ", .{self.replace_needle.items}),
            .confirm_each => ui(self, " Diese Stelle ersetzen?  [J]a  [N]ein  [A]lle  Esc: aufhören ", " Replace this one?  [Y]es  [N]o  [A]ll  Esc: stop "),
        };
        const is_question = switch (p.kind) {
            .search, .save_as, .open, .goto_line, .tree_new_file, .tree_new_dir, .tree_rename, .replace_find, .replace_with => false,
            else => true,
        };
        put(win, &x, y, label, .{ .fg = if (is_question) self.warnColor() else self.accentColor(), .bold = true });
        if (!is_question) {
            put(win, &x, y, p.input.items, .{});
            win.setCursorShape(.beam);
            win.showCursor(@min(x, win.width - 1), y);
            if (p.kind == .search and self.hints_h == 0) {
                put(win, &x, y, ui(self, "   Enter/↓ weiter · ↑ zurück · Esc schließen", "   Enter/↓ next · ↑ back · Esc close"), .{ .dim = true });
            }
            if (self.msg_len > 0) {
                put(win, &x, y, "   ", .{});
                put(win, &x, y, self.msg_buf[0..self.msg_len], if (self.msg_bad) .{ .fg = self.badColor() } else .{ .dim = true });
            }
        }
        return;
    }

    // The editor's name as a small pill. The rounded ends need a Nerd Font;
    // without `icons` it stays a plain box.
    if (self.cfg.symbols) put(win, &x, y, "\u{e0b6}", .{ .fg = self.accentColor(), .bold = true });
    put(win, &x, y, " iro ", .{ .fg = self.accentColor(), .reverse = true, .bold = true });
    if (self.cfg.symbols) put(win, &x, y, "\u{e0b4}", .{ .fg = self.accentColor(), .bold = true });
    // Next to it the gear: scissors for Blade, anvil for Forge.
    const gear_label: []const u8 = switch (self.gear) {
        .blade => if (self.cfg.symbols) " \u{f0c4} BLADE" else " BLADE",
        .forge => if (self.cfg.symbols) " \u{f089b} FORGE" else " FORGE",
    };
    put(win, &x, y, gear_label, .{ .fg = self.accentColor(), .bold = true });
    put(win, &x, y, "  ", .{});
    put(win, &x, y, text.cleanName(arena, self.fileName()), .{ .bold = true });
    if (ed.isModified()) put(win, &x, y, " ●", .{ .fg = self.warnColor() });
    if (self.msg_len > 0) {
        put(win, &x, y, "   ", .{});
        put(win, &x, y, self.msg_buf[0..self.msg_len], .{ .fg = if (self.msg_bad) self.badColor() else .default, .dim = !self.msg_bad });
    }

    const dcol = text.displayCol(ed.buf.line(ed.cursor.line), ed.cursor.col, ed.tab_width);
    const right = if (self.focus == .tree and self.hints_h == 0)
        ui(self, "Enter öffnen · ←→ auf/zu · Rücktaste hoch · . Versteckte · Esc zum Text ", "Enter open · ←→ expand · Backspace up · . hidden · Esc to text ")
    else
        fmtL(self, arena, "Zeile {d}, Spalte {d}  ·  {s}  ·  {s}  ·  {s} ", "Ln {d}, Col {d}  ·  {s}  ·  {s}  ·  {s} ", .{
            ed.cursor.line + 1,
            dcol + 1,
            if (self.d.lang) |lang| lang.name else "Text",
            if (ed.soft_tabs) ui(self, "Leerzeichen", "Spaces") else "Tabs",
            if (self.d.meta.eol == .crlf) "CRLF" else "LF",
        });
    const rw = win.gwidth(right);
    if (x + rw + 2 < win.width) {
        var rx: u16 = win.width - rw;
        put(win, &rx, y, right, .{ .dim = true });
    }
}
