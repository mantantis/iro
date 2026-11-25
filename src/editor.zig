// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Editor logic: cursor, selection, typing, deleting, undo, search.
//!
//! This file knows nothing about the terminal. It receives commands ("type
//! this", "cursor left") and changes text and cursor. That way every behaviour
//! can be tested automatically without any window open.
//!
//! Every text change goes through exactly two places (`applyInsert`,
//! `applyDelete`). They record what happened, and undo is built from that.

const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer = @import("buffer.zig");
const text = @import("text.zig");

pub const Buffer = buffer.Buffer;
pub const Pos = buffer.Pos;

pub const Range = struct {
    start: Pos,
    end: Pos,
};

const Change = struct {
    /// Sequence number, used to detect "changed since saving".
    id: u64,
    /// Changes with the same group are undone together.
    group: u64,
    kind: enum { insert, delete },
    start: Pos,
    end: Pos,
    /// The inserted or deleted text. Owned by the change.
    text: []u8,
    cursor_before: Pos,
    anchor_before: ?Pos,
};

/// What was done last. Steps of the same kind in a row end up in one undo group,
/// so Ctrl+Z doesn't go letter by letter.
const Merge = enum { none, typing_word, typing_space, backspace, delete_forward };

pub const Error = Allocator.Error || error{InvalidUtf8};

pub const Editor = struct {
    gpa: Allocator,
    buf: Buffer,

    cursor: Pos = .{},
    /// Start of the selection. `null` means nothing is selected.
    anchor: ?Pos = null,
    /// Desired screen column for arrow up/down.
    goal: ?usize = null,

    tab_width: usize = 4,
    /// true: the Tab key inserts spaces. false: a real tab character.
    soft_tabs: bool = true,

    undo_stack: std.ArrayList(Change) = .empty,
    redo_stack: std.ArrayList(Change) = .empty,
    next_id: u64 = 1,
    saved_id: u64 = 0,
    group_counter: u64 = 0,
    merge: Merge = .none,
    /// Lowest line changed since the last query. The UI reads it to recompute
    /// syntax colours from there on.
    dirty_from: usize = std.math.maxInt(usize),

    pub fn init(gpa: Allocator) Allocator.Error!Editor {
        return .{ .gpa = gpa, .buf = try Buffer.init(gpa) };
    }

    /// Takes over a ready-made text buffer.
    pub fn fromBuffer(gpa: Allocator, buf: Buffer) Editor {
        var self: Editor = .{ .gpa = gpa, .buf = buf };
        self.detectIndent();
        return self;
    }

    pub fn deinit(self: *Editor) void {
        freeChanges(self.gpa, &self.undo_stack);
        freeChanges(self.gpa, &self.redo_stack);
        self.buf.deinit();
        self.* = undefined;
    }

    fn freeChanges(gpa: Allocator, list: *std.ArrayList(Change)) void {
        for (list.items) |c| gpa.free(c.text);
        list.deinit(gpa);
    }

    /// Does the file indent with tabs? Then the Tab key does too.
    fn detectIndent(self: *Editor) void {
        var i: usize = 0;
        const n = @min(self.buf.lineCount(), 2000);
        while (i < n) : (i += 1) {
            const l = self.buf.line(i);
            if (l.len == 0) continue;
            if (l[0] == '\t') {
                self.soft_tabs = false;
                return;
            }
            if (l[0] == ' ') return;
        }
    }

    // ───────────── Querying state ─────────────

    pub fn isModified(self: *const Editor) bool {
        return self.topId() != self.saved_id;
    }

    pub fn markSaved(self: *Editor) void {
        self.saved_id = self.topId();
        self.merge = .none;
    }

    /// Identifier of the current text state. Changes with every edit.
    pub fn revision(self: *const Editor) u64 {
        return self.topId();
    }

    fn topId(self: *const Editor) u64 {
        const items = self.undo_stack.items;
        return if (items.len == 0) 0 else items[items.len - 1].id;
    }

    /// The selected range, ordered. `null` if nothing is selected.
    pub fn selection(self: *const Editor) ?Range {
        const a = self.anchor orelse return null;
        if (a.eql(self.cursor)) return null;
        return .{ .start = Pos.min(a, self.cursor), .end = Pos.max(a, self.cursor) };
    }

    /// Copy of the selected text. Caller owns the result.
    pub fn selectedText(self: *const Editor, gpa: Allocator) Allocator.Error!?[]u8 {
        const sel = self.selection() orelse return null;
        return try self.buf.copyRange(gpa, sel.start, sel.end);
    }

    fn curLine(self: *const Editor) []const u8 {
        return self.buf.line(self.cursor.line);
    }

    // ───────────── The two places of change ─────────────

    fn applyInsert(self: *Editor, group: u64, pos: Pos, txt: []const u8) Allocator.Error!Pos {
        if (txt.len == 0) return pos;
        const copy = try self.gpa.dupe(u8, txt);
        errdefer self.gpa.free(copy);
        try self.undo_stack.ensureUnusedCapacity(self.gpa, 1);
        const end = try self.buf.insert(pos, txt);
        self.dirty_from = @min(self.dirty_from, pos.line);
        self.pushChange(.{
            .id = 0,
            .group = group,
            .kind = .insert,
            .start = pos,
            .end = end,
            .text = copy,
            .cursor_before = self.cursor,
            .anchor_before = self.anchor,
        });
        return end;
    }

    fn applyDelete(self: *Editor, group: u64, start: Pos, end: Pos) Allocator.Error!void {
        if (start.eql(end)) return;
        const copy = try self.buf.copyRange(self.gpa, start, end);
        errdefer self.gpa.free(copy);
        try self.undo_stack.ensureUnusedCapacity(self.gpa, 1);
        try self.buf.delete(start, end);
        self.dirty_from = @min(self.dirty_from, start.line);
        self.pushChange(.{
            .id = 0,
            .group = group,
            .kind = .delete,
            .start = start,
            .end = end,
            .text = copy,
            .cursor_before = self.cursor,
            .anchor_before = self.anchor,
        });
    }

    fn pushChange(self: *Editor, change: Change) void {
        var c = change;
        c.id = self.next_id;
        self.next_id += 1;
        self.undo_stack.appendAssumeCapacity(c);
        // Doing something new after an undo discards the redo branch.
        for (self.redo_stack.items) |r| self.gpa.free(r.text);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Takes back every change after the first `mark` on the undo stack, for
    /// an edit of several parts that failed halfway (out of memory). The text,
    /// cursor and selection are then as before the edit. If even that fails,
    /// the changes stay on the undo stack (Ctrl+Z can still bring the text
    /// back) and the cursor is at least moved back into the text.
    fn rollbackTo(self: *Editor, mark: usize) void {
        while (self.undo_stack.items.len > mark) {
            const c = self.undo_stack.items[self.undo_stack.items.len - 1];
            switch (c.kind) {
                .insert => self.buf.delete(c.start, c.end) catch break,
                .delete => _ = self.buf.insert(c.start, c.text) catch break,
            }
            self.dirty_from = @min(self.dirty_from, c.start.line);
            self.undo_stack.items.len -= 1;
            self.gpa.free(c.text);
            self.cursor = c.cursor_before;
            self.anchor = c.anchor_before;
        }
        self.cursor = self.snapPos(self.cursor);
        if (self.anchor) |a| self.anchor = self.snapPos(a);
    }

    /// `p` moved into the text and onto a character boundary.
    fn snapPos(self: *const Editor, p: Pos) Pos {
        var c = self.buf.clamp(p);
        c.col = text.snap(self.buf.line(c.line), c.col);
        return c;
    }

    fn newGroup(self: *Editor, kind: Merge) u64 {
        if (kind == .none or kind != self.merge) self.group_counter += 1;
        self.merge = kind;
        return self.group_counter;
    }

    /// Deletes the selection (if any) within group `group`.
    fn deleteSelection(self: *Editor, group: u64) Allocator.Error!bool {
        const sel = self.selection() orelse {
            self.anchor = null;
            return false;
        };
        try self.applyDelete(group, sel.start, sel.end);
        self.cursor = sel.start;
        self.anchor = null;
        return true;
    }

    /// Replaces the whole text in one undo step (an earlier version of the
    /// file, for instance). Undo brings the old text back with the cursor where
    /// it was and nothing selected, so the next key can't wipe it all.
    pub fn replaceText(self: *Editor, txt: []const u8) Error!void {
        if (!std.unicode.utf8ValidateSlice(txt)) return error.InvalidUtf8;
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;
        self.anchor = null;
        try self.applyDelete(group, .{}, self.buf.endPos());
        self.cursor = .{};
        self.cursor = try self.applyInsert(group, .{}, txt);
    }

    // ───────────── Entering text ─────────────

    /// Inserts arbitrary text (e.g. from the clipboard), replacing the
    /// selection. Windows line endings are converted.
    pub fn insertText(self: *Editor, txt: []const u8) Error!void {
        if (!std.unicode.utf8ValidateSlice(txt)) return error.InvalidUtf8;
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;

        if (std.mem.indexOfScalar(u8, txt, '\r') == null) {
            _ = try self.deleteSelection(group);
            self.cursor = try self.applyInsert(group, self.cursor, txt);
            return;
        }

        // "\r\n" and a lone "\r" become "\n".
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.gpa);
        try clean.ensureTotalCapacity(self.gpa, txt.len);
        var i: usize = 0;
        while (i < txt.len) : (i += 1) {
            if (txt[i] == '\r') {
                clean.appendAssumeCapacity('\n');
                if (i + 1 < txt.len and txt[i + 1] == '\n') i += 1;
            } else {
                clean.appendAssumeCapacity(txt[i]);
            }
        }
        _ = try self.deleteSelection(group);
        self.cursor = try self.applyInsert(group, self.cursor, clean.items);
    }

    /// Text typed on the keyboard. Consecutive letters of a word form one undo
    /// step.
    pub fn typeText(self: *Editor, txt: []const u8) Error!void {
        if (txt.len == 0) return;
        if (!std.unicode.utf8ValidateSlice(txt)) return error.InvalidUtf8;
        if (std.mem.indexOfAny(u8, txt, "\r\n") != null) return self.insertText(txt);

        const kind: Merge = if (text.classOf(txt) == .space) .typing_space else .typing_word;
        const had_selection = self.selection() != null;
        const group = self.newGroup(if (had_selection) .none else kind);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;
        _ = try self.deleteSelection(group);
        self.cursor = try self.applyInsert(group, self.cursor, txt);
        if (had_selection) self.merge = kind;
    }

    /// Enter: new line with the indentation of the current line.
    pub fn newline(self: *Editor) Error!void {
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;
        _ = try self.deleteSelection(group);

        const l = self.curLine();
        const indent = @min(text.indentLen(l), self.cursor.col);
        var stack_buf: [256]u8 = undefined;
        if (indent + 1 <= stack_buf.len) {
            stack_buf[0] = '\n';
            @memcpy(stack_buf[1..][0..indent], l[0..indent]);
            self.cursor = try self.applyInsert(group, self.cursor, stack_buf[0 .. indent + 1]);
        } else {
            const tmp = try self.gpa.alloc(u8, indent + 1);
            defer self.gpa.free(tmp);
            tmp[0] = '\n';
            @memcpy(tmp[1..], l[0..indent]);
            self.cursor = try self.applyInsert(group, self.cursor, tmp);
        }
    }

    /// Tab key: indent to the next tab stop.
    pub fn tab(self: *Editor) Error!void {
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;
        _ = try self.deleteSelection(group);
        if (!self.soft_tabs) {
            self.cursor = try self.applyInsert(group, self.cursor, "\t");
            return;
        }
        const dcol = text.displayCol(self.curLine(), self.cursor.col, self.tab_width);
        const n = self.tab_width - (dcol % self.tab_width);
        const spaces = "                ";
        self.cursor = try self.applyInsert(group, self.cursor, spaces[0..@min(n, spaces.len)]);
    }

    // ───────────── Editing whole lines ─────────────

    const LineSpan = struct { first: usize, last: usize };

    /// The lines touched by the selection; without a selection, the line under
    /// the cursor. If the selection ends at the very start of a line, that line
    /// no longer counts.
    fn lineSpan(self: *const Editor) LineSpan {
        const sel = self.selection() orelse return .{ .first = self.cursor.line, .last = self.cursor.line };
        var last = sel.end.line;
        if (sel.end.col == 0 and last > sel.start.line) last -= 1;
        return .{ .first = sel.start.line, .last = last };
    }

    /// Does the selection span more than one line?
    pub fn selectionSpansLines(self: *const Editor) bool {
        const sel = self.selection() orelse return false;
        return sel.start.line != sel.end.line;
    }

    /// Shifts cursor and selection start when something was inserted (`delta` >
    /// 0) or removed (`delta` < 0) in their line at `col`. `inclusive`: a
    /// position exactly at that spot moves too.
    fn shiftCols(self: *Editor, line: usize, col: usize, delta: isize, inclusive: bool) void {
        const Fix = struct {
            fn one(p: *Pos, l: usize, c: usize, d: isize, incl: bool) void {
                if (p.line != l) return;
                if (d > 0) {
                    if (p.col > c or (incl and p.col == c)) p.col += @intCast(d);
                } else {
                    const n: usize = @intCast(-d);
                    if (p.col >= c + n) p.col -= n else if (p.col > c) p.col = c;
                }
            }
        };
        Fix.one(&self.cursor, line, col, delta, inclusive);
        if (self.anchor) |*a| Fix.one(a, line, col, delta, inclusive);
    }

    fn indentUnit(self: *const Editor) []const u8 {
        const spaces = "                ";
        return if (self.soft_tabs) spaces[0..@min(self.tab_width, spaces.len)] else "\t";
    }

    /// Indents all selected lines by one level. The selection stays.
    pub fn indentLines(self: *Editor) Error!void {
        const span = self.lineSpan();
        const unit = self.indentUnit();
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;
        var line = span.first;
        while (line <= span.last) : (line += 1) {
            if (self.buf.line(line).len == 0) continue;
            _ = try self.applyInsert(group, .{ .line = line, .col = 0 }, unit);
            self.shiftCols(line, 0, @intCast(unit.len), false);
        }
    }

    /// Removes one level of indentation from all selected lines (or the current
    /// one): a tab or up to `tab_width` spaces.
    pub fn dedentLines(self: *Editor) Error!void {
        const span = self.lineSpan();
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;
        var line = span.first;
        while (line <= span.last) : (line += 1) {
            const l = self.buf.line(line);
            var n: usize = 0;
            if (l.len > 0 and l[0] == '\t') {
                n = 1;
            } else {
                while (n < l.len and n < self.tab_width and l[n] == ' ') n += 1;
            }
            if (n == 0) continue;
            try self.applyDelete(group, .{ .line = line, .col = 0 }, .{ .line = line, .col = n });
            self.shiftCols(line, 0, -@as(isize, @intCast(n)), false);
        }
    }

    /// Comments out the selected lines (or the current one). If all are already
    /// commented, the comment is removed again. `token` is the language's
    /// comment marker, such as "#" or "//".
    pub fn toggleComment(self: *Editor, token: []const u8) Error!void {
        if (token.len == 0) return;
        const span = self.lineSpan();
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;

        // Look first: are all non-empty lines already comments? And how far is
        // the least indented line indented?
        var all_commented = true;
        var any = false;
        var min_indent: usize = std.math.maxInt(usize);
        var line = span.first;
        while (line <= span.last) : (line += 1) {
            const l = self.buf.line(line);
            const ind = text.indentLen(l);
            if (ind == l.len) continue;
            any = true;
            min_indent = @min(min_indent, ind);
            if (!std.mem.startsWith(u8, l[ind..], token)) all_commented = false;
        }
        if (!any) return;

        line = span.first;
        while (line <= span.last) : (line += 1) {
            const l = self.buf.line(line);
            const ind = text.indentLen(l);
            if (ind == l.len) continue;
            if (all_commented) {
                var n = token.len;
                if (ind + n < l.len and l[ind + n] == ' ') n += 1;
                try self.applyDelete(group, .{ .line = line, .col = ind }, .{ .line = line, .col = ind + n });
                self.shiftCols(line, ind, -@as(isize, @intCast(n)), false);
            } else {
                var buf: [18]u8 = undefined;
                const n = @min(token.len, 16);
                @memcpy(buf[0..n], token[0..n]);
                buf[n] = ' ';
                _ = try self.applyInsert(group, .{ .line = line, .col = min_indent }, buf[0 .. n + 1]);
                self.shiftCols(line, min_indent, @intCast(n + 1), true);
            }
        }
    }

    /// Duplicates the line under the cursor. The cursor moves into the copy.
    pub fn duplicateLine(self: *Editor) Error!void {
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;
        const line = self.cursor.line;
        const copy = try std.mem.concat(self.gpa, u8, &.{ "\n", self.buf.line(line) });
        defer self.gpa.free(copy);
        const col = self.cursor.col;
        self.anchor = null;
        _ = try self.applyInsert(group, .{ .line = line, .col = self.buf.line(line).len }, copy);
        self.cursor = .{ .line = line + 1, .col = col };
    }

    /// Moves the line under the cursor one line up (`up`) or down. Nothing happens at
    /// the edge of the file. Returns whether it moved.
    pub fn moveLine(self: *Editor, up: bool) Error!bool {
        const line = self.cursor.line;
        if (up and line == 0) return false;
        if (!up and line + 1 >= self.buf.lineCount()) return false;
        const upper = if (up) line - 1 else line;
        const a = self.buf.line(upper);
        const b = self.buf.line(upper + 1);
        const swapped = try std.mem.concat(self.gpa, u8, &.{ b, "\n", a });
        defer self.gpa.free(swapped);

        const group = self.newGroup(.none);

        const mark = self.undo_stack.items.len;

        errdefer self.rollbackTo(mark);
        self.goal = null;
        const col = self.cursor.col;
        self.anchor = null;
        const start: Pos = .{ .line = upper, .col = 0 };
        try self.applyDelete(group, start, .{ .line = upper + 1, .col = b.len });
        _ = try self.applyInsert(group, start, swapped);
        self.cursor = .{ .line = if (up) line - 1 else line + 1, .col = col };
        return true;
    }

    // ───────────── Deleting ─────────────

    /// Backspace.
    pub fn backspace(self: *Editor) Error!void {
        self.goal = null;
        if (self.selection() != null) {
            _ = try self.deleteSelection(self.newGroup(.none));
            return;
        }
        self.anchor = null;
        const start = self.posLeft(self.cursor);
        if (start.eql(self.cursor)) return;
        const group = self.newGroup(.backspace);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        try self.applyDelete(group, start, self.cursor);
        self.cursor = start;
    }

    /// Delete key.
    pub fn deleteForward(self: *Editor) Error!void {
        self.goal = null;
        if (self.selection() != null) {
            _ = try self.deleteSelection(self.newGroup(.none));
            return;
        }
        self.anchor = null;
        const end = self.posRight(self.cursor);
        if (end.eql(self.cursor)) return;
        const group = self.newGroup(.delete_forward);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        try self.applyDelete(group, self.cursor, end);
    }

    /// Ctrl+Backspace: delete the word left of the cursor.
    pub fn deleteWordBack(self: *Editor) Error!void {
        self.goal = null;
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        if (try self.deleteSelection(group)) return;
        const start = self.posWordLeft(self.cursor);
        try self.applyDelete(group, start, self.cursor);
        self.cursor = start;
    }

    /// Ctrl+Delete: delete the word right of the cursor.
    pub fn deleteWordForward(self: *Editor) Error!void {
        self.goal = null;
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        if (try self.deleteSelection(group)) return;
        try self.applyDelete(group, self.cursor, self.posWordRight(self.cursor));
    }

    /// Cuts the selection and returns it. Caller owns the result.
    pub fn cut(self: *Editor, gpa: Allocator) Error!?[]u8 {
        const txt = try self.selectedText(gpa) orelse return null;
        errdefer gpa.free(txt);
        self.goal = null;
        _ = try self.deleteSelection(self.newGroup(.none));
        return txt;
    }

    /// The line under the cursor including its line ending. Caller owns the
    /// result.
    pub fn lineText(self: *const Editor, gpa: Allocator) Allocator.Error![]u8 {
        return std.mem.concat(gpa, u8, &.{ self.curLine(), "\n" });
    }

    /// Cuts the whole line under the cursor (Ctrl+X without a selection). The
    /// line disappears completely; no empty line remains. `null`: the file is
    /// empty, there is nothing to take.
    pub fn cutLine(self: *Editor, gpa: Allocator) Error!?[]u8 {
        const line = self.cursor.line;
        const len = self.curLine().len;
        const count = self.buf.lineCount();
        if (count == 1 and len == 0) return null;
        const txt = try self.lineText(gpa);
        errdefer gpa.free(txt);

        // Deleted directly, without selecting the line first: undo brings
        // back the cursor where it was, with nothing selected.
        const start: Pos, const end: Pos = if (line + 1 < count)
            .{ .{ .line = line, .col = 0 }, .{ .line = line + 1, .col = 0 } }
        else if (line > 0)
            // Last line: the newline before it has to go too.
            .{ .{ .line = line - 1, .col = self.buf.line(line - 1).len }, .{ .line = line, .col = len } }
        else
            .{ .{ .line = 0, .col = 0 }, .{ .line = 0, .col = len } };
        self.goal = null;
        try self.applyDelete(self.newGroup(.none), start, end);
        self.setCursor(.{ .line = start.line, .col = 0 }, false);
        return txt;
    }

    // ───────────── Undo and redo ─────────────

    pub fn undo(self: *Editor) Allocator.Error!bool {
        self.merge = .none;
        self.goal = null;
        const items = self.undo_stack.items;
        if (items.len == 0) return false;
        const group = items[items.len - 1].group;

        while (self.undo_stack.items.len > 0) {
            const c = self.undo_stack.items[self.undo_stack.items.len - 1];
            if (c.group != group) break;
            try self.redo_stack.ensureUnusedCapacity(self.gpa, 1);
            switch (c.kind) {
                .insert => try self.buf.delete(c.start, c.end),
                .delete => _ = try self.buf.insert(c.start, c.text),
            }
            self.dirty_from = @min(self.dirty_from, c.start.line);
            self.undo_stack.items.len -= 1;
            self.redo_stack.appendAssumeCapacity(c);
            self.cursor = c.cursor_before;
            self.anchor = c.anchor_before;
        }
        return true;
    }

    pub fn redo(self: *Editor) Allocator.Error!bool {
        self.merge = .none;
        self.goal = null;
        const items = self.redo_stack.items;
        if (items.len == 0) return false;
        const group = items[items.len - 1].group;

        while (self.redo_stack.items.len > 0) {
            const c = self.redo_stack.items[self.redo_stack.items.len - 1];
            if (c.group != group) break;
            try self.undo_stack.ensureUnusedCapacity(self.gpa, 1);
            switch (c.kind) {
                .insert => {
                    _ = try self.buf.insert(c.start, c.text);
                    self.cursor = c.end;
                },
                .delete => {
                    try self.buf.delete(c.start, c.end);
                    self.cursor = c.start;
                },
            }
            self.dirty_from = @min(self.dirty_from, c.start.line);
            self.redo_stack.items.len -= 1;
            self.undo_stack.appendAssumeCapacity(c);
            self.anchor = null;
        }
        return true;
    }

    // ───────────── Computing positions ─────────────

    fn posLeft(self: *const Editor, p: Pos) Pos {
        if (p.col > 0) return .{ .line = p.line, .col = text.prevBoundary(self.buf.line(p.line), p.col) };
        if (p.line == 0) return p;
        return .{ .line = p.line - 1, .col = self.buf.line(p.line - 1).len };
    }

    fn posRight(self: *const Editor, p: Pos) Pos {
        const l = self.buf.line(p.line);
        if (p.col < l.len) return .{ .line = p.line, .col = text.nextBoundary(l, p.col) };
        if (p.line + 1 >= self.buf.lineCount()) return p;
        return .{ .line = p.line + 1, .col = 0 };
    }

    fn posWordLeft(self: *const Editor, p: Pos) Pos {
        if (p.col == 0) return self.posLeft(p);
        const l = self.buf.line(p.line);
        var col = p.col;
        // First skip whitespace, then one contiguous character class.
        while (col > 0) {
            const prev = text.prevBoundary(l, col);
            if (text.classOf(l[prev..col]) != .space) break;
            col = prev;
        }
        if (col == 0) return .{ .line = p.line, .col = 0 };
        const class = text.classOf(l[text.prevBoundary(l, col)..col]);
        while (col > 0) {
            const prev = text.prevBoundary(l, col);
            if (text.classOf(l[prev..col]) != class) break;
            col = prev;
        }
        return .{ .line = p.line, .col = col };
    }

    fn posWordRight(self: *const Editor, p: Pos) Pos {
        const l = self.buf.line(p.line);
        if (p.col >= l.len) return self.posRight(p);
        var col = p.col;
        while (col < l.len) {
            const next = text.nextBoundary(l, col);
            if (text.classOf(l[col..next]) != .space) break;
            col = next;
        }
        if (col >= l.len) return .{ .line = p.line, .col = l.len };
        const class = text.classOf(l[col..text.nextBoundary(l, col)]);
        while (col < l.len) {
            const next = text.nextBoundary(l, col);
            if (text.classOf(l[col..next]) != class) break;
            col = next;
        }
        return .{ .line = p.line, .col = col };
    }

    // ───────────── Moving the cursor ─────────────

    /// Sets the cursor. `extend` = Shift held: extend the selection.
    fn moveTo(self: *Editor, p: Pos, extend: bool) void {
        self.merge = .none;
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else {
            self.anchor = null;
        }
        self.cursor = p;
    }

    /// Puts the cursor anywhere (mouse click). The position is clamped into the
    /// valid range and onto a character boundary.
    pub fn setCursor(self: *Editor, p: Pos, extend: bool) void {
        var q = self.buf.clamp(p);
        q.col = text.snap(self.buf.line(q.line), q.col);
        self.goal = null;
        self.moveTo(q, extend);
    }

    pub fn moveLeft(self: *Editor, extend: bool) void {
        self.goal = null;
        if (!extend) {
            if (self.selection()) |sel| return self.moveTo(sel.start, false);
        }
        self.moveTo(self.posLeft(self.cursor), extend);
    }

    pub fn moveRight(self: *Editor, extend: bool) void {
        self.goal = null;
        if (!extend) {
            if (self.selection()) |sel| return self.moveTo(sel.end, false);
        }
        self.moveTo(self.posRight(self.cursor), extend);
    }

    pub fn moveWordLeft(self: *Editor, extend: bool) void {
        self.goal = null;
        self.moveTo(self.posWordLeft(self.cursor), extend);
    }

    pub fn moveWordRight(self: *Editor, extend: bool) void {
        self.goal = null;
        self.moveTo(self.posWordRight(self.cursor), extend);
    }

    /// Moves the cursor by `delta` lines while keeping the screen column.
    pub fn moveLines(self: *Editor, delta: isize, extend: bool) void {
        const goal = self.goal orelse text.displayCol(self.curLine(), self.cursor.col, self.tab_width);
        const last = self.buf.lineCount() - 1;
        const cur: isize = @intCast(self.cursor.line);
        const target = cur + delta;

        var p: Pos = undefined;
        if (target < 0) {
            p = .{ .line = 0, .col = 0 };
        } else if (target > last) {
            p = .{ .line = last, .col = self.buf.line(last).len };
        } else {
            const line: usize = @intCast(target);
            p = .{ .line = line, .col = text.colAtDisplay(self.buf.line(line), goal, self.tab_width) };
        }
        self.moveTo(p, extend);
        self.goal = goal;
    }

    /// Home: jumps to the first character of the line, the second time all the way
    /// left.
    pub fn moveHome(self: *Editor, extend: bool) void {
        self.goal = null;
        const indent = text.indentLen(self.curLine());
        const col: usize = if (self.cursor.col == indent) 0 else indent;
        self.moveTo(.{ .line = self.cursor.line, .col = col }, extend);
    }

    pub fn moveEnd(self: *Editor, extend: bool) void {
        self.goal = null;
        self.moveTo(.{ .line = self.cursor.line, .col = self.curLine().len }, extend);
    }

    pub fn moveDocStart(self: *Editor, extend: bool) void {
        self.goal = null;
        self.moveTo(.{}, extend);
    }

    pub fn moveDocEnd(self: *Editor, extend: bool) void {
        self.goal = null;
        self.moveTo(self.buf.endPos(), extend);
    }

    pub fn selectAll(self: *Editor) void {
        self.goal = null;
        self.merge = .none;
        self.anchor = .{};
        self.cursor = self.buf.endPos();
    }

    pub fn clearSelection(self: *Editor) void {
        self.anchor = null;
    }

    /// Selects the word at position `p` (double click).
    pub fn selectWordAt(self: *Editor, p: Pos) void {
        self.setCursor(p, false);
        const l = self.curLine();
        if (l.len == 0) return;
        var col = self.cursor.col;
        if (col >= l.len) col = text.prevBoundary(l, col);
        const class = text.classOf(l[col..text.nextBoundary(l, col)]);
        var start = col;
        while (start > 0) {
            const prev = text.prevBoundary(l, start);
            if (text.classOf(l[prev..start]) != class) break;
            start = prev;
        }
        var end = col;
        while (end < l.len) {
            const next = text.nextBoundary(l, end);
            if (text.classOf(l[end..next]) != class) break;
            end = next;
        }
        self.anchor = .{ .line = self.cursor.line, .col = start };
        self.cursor = .{ .line = self.cursor.line, .col = end };
    }

    /// Selects the whole line including the newline (triple click).
    pub fn selectLineAt(self: *Editor, p: Pos) void {
        self.setCursor(p, false);
        const line = self.cursor.line;
        self.anchor = .{ .line = line, .col = 0 };
        self.cursor = if (line + 1 < self.buf.lineCount())
            .{ .line = line + 1, .col = 0 }
        else
            .{ .line = line, .col = self.buf.line(line).len };
    }

    // ───────────── Search ─────────────

    /// Searches for `needle` from `from`. Wraps around at the end of the file
    /// (and vice versa). Without uppercase letters in the query, case is
    /// ignored.
    pub fn find(self: *const Editor, needle: []const u8, from: Pos, forward: bool) ?Range {
        if (needle.len == 0 or std.mem.indexOfScalar(u8, needle, '\n') != null) return null;
        var exact = false;
        for (needle) |b| {
            if (std.ascii.isUpper(b)) exact = true;
        }
        const n = self.buf.lineCount();
        const start = self.buf.clamp(from);

        // One round through all lines plus the start line once more.
        var step: usize = 0;
        while (step <= n) : (step += 1) {
            const line = if (forward) (start.line + step) % n else (start.line + n - (step % n)) % n;
            const l = self.buf.line(line);
            var lo: usize = 0;
            var hi: usize = l.len;
            // What counts is where a match starts. Forward: from the cursor on,
            // and on the way back round everything that starts before it, even
            // if it reaches past the cursor (the cursor can sit inside the
            // only match). Backward the same, mirrored.
            const reach = @min(l.len, start.col + needle.len - 1);
            if (forward) {
                if (step == 0) lo = start.col;
                if (step == n) hi = reach;
            } else {
                if (step == 0) hi = reach;
                if (step == n) lo = start.col;
            }
            if (searchLine(l, needle, lo, hi, forward, exact)) |col| {
                return .{
                    .start = .{ .line = line, .col = col },
                    .end = .{ .line = line, .col = col + needle.len },
                };
            }
        }
        return null;
    }

    /// If there is a bracket at `pos`, returns the position of its counterpart.
    /// Brackets are simply counted, without understanding strings or comments.
    /// Searches at most `max_lines` lines.
    pub fn matchingBracket(self: *const Editor, pos: Pos, max_lines: usize) ?Pos {
        const l0 = self.buf.line(pos.line);
        if (pos.col >= l0.len) return null;
        const open = "([{";
        const close = ")]}";
        const b = l0[pos.col];
        const forward = std.mem.indexOfScalar(u8, open, b) != null;
        const idx = std.mem.indexOfScalar(u8, if (forward) open else close, b) orelse return null;
        const partner = if (forward) close[idx] else open[idx];

        var depth: usize = 0;
        var line = pos.line;
        var steps: usize = 0;
        while (steps <= max_lines) : (steps += 1) {
            const l = self.buf.line(line);
            if (forward) {
                var i: usize = if (line == pos.line) pos.col else 0;
                while (i < l.len) : (i += 1) {
                    if (l[i] == b) depth += 1 else if (l[i] == partner) {
                        depth -= 1;
                        if (depth == 0) return .{ .line = line, .col = i };
                    }
                }
                if (line + 1 >= self.buf.lineCount()) return null;
                line += 1;
            } else {
                var i: usize = if (line == pos.line) pos.col + 1 else l.len;
                while (i > 0) {
                    i -= 1;
                    if (l[i] == b) depth += 1 else if (l[i] == partner) {
                        depth -= 1;
                        if (depth == 0) return .{ .line = line, .col = i };
                    }
                }
                if (line == 0) return null;
                line -= 1;
            }
        }
        return null;
    }

    /// The bracket at the cursor (under it or directly before it) plus its
    /// counterpart.
    pub fn bracketPair(self: *const Editor, max_lines: usize) ?[2]Pos {
        const c = self.cursor;
        if (self.matchingBracket(c, max_lines)) |m| return .{ c, m };
        if (c.col > 0) {
            const before: Pos = .{ .line = c.line, .col = c.col - 1 };
            if (self.matchingBracket(before, max_lines)) |m| return .{ before, m };
        }
        return null;
    }

    /// Like `find`, but without wrapping: searches only from `from` to the end
    /// of the file.
    pub fn findForward(self: *const Editor, needle: []const u8, from: Pos) ?Range {
        const hit = self.find(needle, from, true) orelse return null;
        if (hit.start.lessThan(from)) return null;
        return hit;
    }

    /// Replaces every match in the whole file, all in one undo step. Returns
    /// the number of replacements.
    pub fn replaceAll(self: *Editor, needle: []const u8, with: []const u8) Error!usize {
        return self.replaceFrom(needle, with, .{});
    }

    /// Selects exactly this range (e.g. a search match).
    pub fn selectRange(self: *Editor, r: Range) void {
        self.merge = .none;
        self.goal = null;
        self.anchor = self.buf.clamp(r.start);
        self.cursor = self.buf.clamp(r.end);
    }

    /// Like `replaceAll`, but only from position `from` to the end of the file.
    pub fn replaceFrom(self: *Editor, needle: []const u8, with: []const u8, from: Pos) Error!usize {
        if (!std.unicode.utf8ValidateSlice(with)) return error.InvalidUtf8;
        if (std.mem.indexOfAny(u8, with, "\r\n") != null) return error.InvalidUtf8;
        const group = self.newGroup(.none);
        const mark = self.undo_stack.items.len;
        errdefer self.rollbackTo(mark);
        self.goal = null;
        const cursor_before = self.cursor;
        var count: usize = 0;
        var pos: Pos = self.buf.clamp(from);
        while (self.findForward(needle, pos)) |hit| {
            try self.applyDelete(group, hit.start, hit.end);
            pos = try self.applyInsert(group, hit.start, with);
            count += 1;
        }
        if (count > 0) {
            self.anchor = null;
            var c = self.buf.clamp(cursor_before);
            c.col = text.snap(self.buf.line(c.line), c.col);
            self.cursor = c;
        }
        return count;
    }

    /// Jumps to the next match and selects it.
    pub fn findAndSelect(self: *Editor, needle: []const u8, forward: bool) bool {
        var from = self.cursor;
        if (self.selection()) |sel| from = if (forward) sel.end else sel.start;
        const hit = self.find(needle, from, forward) orelse return false;
        self.merge = .none;
        self.goal = null;
        self.anchor = hit.start;
        self.cursor = hit.end;
        return true;
    }
};

/// Next match of `needle` in a single line from byte `from`. Same rule as the
/// search: without uppercase letters, case is ignored.
pub fn findInLine(l: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or from > l.len) return null;
    var exact = false;
    for (needle) |b| {
        if (std.ascii.isUpper(b)) exact = true;
    }
    return searchLine(l, needle, from, l.len, true, exact);
}

/// Finds a match lying entirely within [lo, hi) of the line.
fn searchLine(l: []const u8, needle: []const u8, lo: usize, hi: usize, forward: bool, exact: bool) ?usize {
    if (hi > l.len or lo > hi or hi - lo < needle.len) return null;
    const last = hi - needle.len;
    if (forward) {
        var i = lo;
        while (i <= last) : (i += 1) {
            if (matchAt(l, needle, i, exact)) return i;
        }
    } else {
        var i = last + 1;
        while (i > lo) {
            i -= 1;
            if (matchAt(l, needle, i, exact)) return i;
        }
    }
    return null;
}

fn matchAt(l: []const u8, needle: []const u8, at: usize, exact: bool) bool {
    const part = l[at..][0..needle.len];
    return if (exact) std.mem.eql(u8, part, needle) else std.ascii.eqlIgnoreCase(part, needle);
}

// ───────────────────────────── Tests ─────────────────────────────

const testing = std.testing;

fn makeEditor(content: []const u8) !Editor {
    return Editor.fromBuffer(testing.allocator, try Buffer.fromBytes(testing.allocator, content));
}

fn expectContent(ed: *const Editor, expected: []const u8) !void {
    const got = try ed.buf.toBytes(testing.allocator, "\n");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
    try ed.buf.checkInvariants();
    try expectCursorValid(ed);
}

fn expectCursorValid(ed: *const Editor) !void {
    try testing.expect(ed.buf.isValid(ed.cursor));
    const l = ed.buf.line(ed.cursor.line);
    try testing.expectEqual(ed.cursor.col, text.snap(l, ed.cursor.col));
    if (ed.anchor) |a| {
        try testing.expect(ed.buf.isValid(a));
        try testing.expectEqual(a.col, text.snap(ed.buf.line(a.line), a.col));
    }
}

test "typing and modified state" {
    var ed = try Editor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect(!ed.isModified());
    try ed.typeText("H");
    try ed.typeText("i");
    try expectContent(&ed, "Hi");
    try testing.expect(ed.isModified());
    ed.markSaved();
    try testing.expect(!ed.isModified());
    _ = try ed.undo();
    try testing.expect(ed.isModified());
    _ = try ed.redo();
    try testing.expect(!ed.isModified());
}

test "undo works word by word" {
    var ed = try Editor.init(testing.allocator);
    defer ed.deinit();
    for ("hallo welt") |ch| try ed.typeText(&.{ch});
    try expectContent(&ed, "hallo welt");
    _ = try ed.undo();
    try expectContent(&ed, "hallo ");
    _ = try ed.undo();
    try expectContent(&ed, "hallo");
    _ = try ed.undo();
    try expectContent(&ed, "");
    try testing.expect(!try ed.undo());
    _ = try ed.redo();
    _ = try ed.redo();
    _ = try ed.redo();
    try expectContent(&ed, "hallo welt");
    try testing.expectEqual(Pos{ .line = 0, .col = 10 }, ed.cursor);
}

test "backspace deletes whole visible characters" {
    var ed = try makeEditor("aä🦅👨‍👩‍👧");
    defer ed.deinit();
    ed.moveDocEnd(false);
    try ed.backspace();
    try expectContent(&ed, "aä🦅");
    try ed.backspace();
    try expectContent(&ed, "aä");
    try ed.backspace();
    try expectContent(&ed, "a");
    _ = try ed.undo(); // all three backspaces are one step
    try expectContent(&ed, "aä🦅👨‍👩‍👧");
}

test "backspace at line start joins lines" {
    var ed = try makeEditor("eins\nzwei");
    defer ed.deinit();
    ed.setCursor(.{ .line = 1, .col = 0 }, false);
    try ed.backspace();
    try expectContent(&ed, "einszwei");
    try testing.expectEqual(Pos{ .line = 0, .col = 4 }, ed.cursor);
}

test "delete at line end joins lines, nothing happens at end of file" {
    var ed = try makeEditor("eins\nzwei");
    defer ed.deinit();
    ed.moveEnd(false);
    try ed.deleteForward();
    try expectContent(&ed, "einszwei");
    ed.moveDocEnd(false);
    try ed.deleteForward();
    try expectContent(&ed, "einszwei");
}

test "typing replaces the selection and undo restores it" {
    var ed = try makeEditor("eins zwei drei");
    defer ed.deinit();
    ed.setCursor(.{ .line = 0, .col = 5 }, false);
    ed.setCursor(.{ .line = 0, .col = 9 }, true);
    try ed.typeText("X");
    try expectContent(&ed, "eins X drei");
    _ = try ed.undo();
    try expectContent(&ed, "eins zwei drei");
    try testing.expectEqual(Pos{ .line = 0, .col = 9 }, ed.cursor);
    try testing.expectEqual(Pos{ .line = 0, .col = 5 }, ed.anchor.?);
}

test "enter keeps the indentation" {
    var ed = try makeEditor("    wert = 1");
    defer ed.deinit();
    ed.moveEnd(false);
    try ed.newline();
    try ed.typeText("x");
    try expectContent(&ed, "    wert = 1\n    x");
}

test "tab indents to the next tab stop, with spaces or a real tab" {
    var ed = try makeEditor("ab");
    defer ed.deinit();
    ed.moveEnd(false);
    try ed.tab();
    try expectContent(&ed, "ab  ");

    var ed2 = try makeEditor("\tschon mit Tabs");
    defer ed2.deinit();
    try testing.expect(!ed2.soft_tabs);
    try ed2.tab();
    try expectContent(&ed2, "\t\tschon mit Tabs");
}

test "paste converts Windows line endings and rejects broken UTF-8" {
    var ed = try Editor.init(testing.allocator);
    defer ed.deinit();
    try ed.insertText("a\r\nb\rc");
    try expectContent(&ed, "a\nb\nc");
    try testing.expectError(error.InvalidUtf8, ed.insertText("\xff\xfe"));
    try expectContent(&ed, "a\nb\nc");
}

test "arrow up/down keeps the column" {
    var ed = try makeEditor("lange zeile hier\nkurz\nlange zeile dort");
    defer ed.deinit();
    ed.setCursor(.{ .line = 0, .col = 12 }, false);
    ed.moveLines(1, false);
    try testing.expectEqual(Pos{ .line = 1, .col = 4 }, ed.cursor);
    ed.moveLines(1, false);
    try testing.expectEqual(Pos{ .line = 2, .col = 12 }, ed.cursor);
    ed.moveLines(5, false);
    try testing.expectEqual(Pos{ .line = 2, .col = 16 }, ed.cursor);
    ed.moveLines(-99, false);
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, ed.cursor);
}

test "word jumps" {
    var ed = try makeEditor("foo.bar  größe_1 ende");
    defer ed.deinit();
    ed.moveWordRight(false);
    try testing.expectEqual(@as(usize, 3), ed.cursor.col); // after foo
    ed.moveWordRight(false);
    try testing.expectEqual(@as(usize, 4), ed.cursor.col); // after the dot
    ed.moveWordRight(false);
    try testing.expectEqual(@as(usize, 7), ed.cursor.col); // after bar
    ed.moveWordRight(false);
    try testing.expectEqual(@as(usize, 9 + "größe_1".len), ed.cursor.col);
    ed.moveWordLeft(false);
    try testing.expectEqual(@as(usize, 9), ed.cursor.col);
    ed.moveDocEnd(false);
    try ed.deleteWordBack();
    try expectContent(&ed, "foo.bar  größe_1 ");
}

test "home toggles between indentation and line start" {
    var ed = try makeEditor("    text");
    defer ed.deinit();
    ed.moveEnd(false);
    ed.moveHome(false);
    try testing.expectEqual(@as(usize, 4), ed.cursor.col);
    ed.moveHome(false);
    try testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "select word and line" {
    var ed = try makeEditor("eins zwei\ndrei");
    defer ed.deinit();
    ed.selectWordAt(.{ .line = 0, .col = 6 });
    const w = (try ed.selectedText(testing.allocator)).?;
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("zwei", w);
    ed.selectLineAt(.{ .line = 0, .col = 2 });
    const l = (try ed.selectedText(testing.allocator)).?;
    defer testing.allocator.free(l);
    try testing.expectEqualStrings("eins zwei\n", l);
}

test "cut" {
    var ed = try makeEditor("eins zwei");
    defer ed.deinit();
    ed.selectWordAt(.{ .line = 0, .col = 0 });
    const txt = (try ed.cut(testing.allocator)).?;
    defer testing.allocator.free(txt);
    try testing.expectEqualStrings("eins", txt);
    try expectContent(&ed, " zwei");
}

test "search forward, backward, wrapping and case" {
    var ed = try makeEditor("Alpha beta\ngamma ALPHA\nalpha");
    defer ed.deinit();
    try testing.expect(ed.findAndSelect("alpha", true));
    try testing.expectEqual(Pos{ .line = 0, .col = 5 }, ed.cursor);
    try testing.expect(ed.findAndSelect("alpha", true));
    try testing.expectEqual(Pos{ .line = 1, .col = 11 }, ed.cursor);
    try testing.expect(ed.findAndSelect("alpha", true));
    try testing.expectEqual(Pos{ .line = 2, .col = 5 }, ed.cursor);
    try testing.expect(ed.findAndSelect("alpha", true)); // wraps around to the start
    try testing.expectEqual(Pos{ .line = 0, .col = 5 }, ed.cursor);
    try testing.expect(ed.findAndSelect("alpha", false)); // backwards past the start
    try testing.expectEqual(Pos{ .line = 2, .col = 5 }, ed.cursor);
    // Uppercase letter in the query: now case matters.
    ed.setCursor(.{}, false);
    try testing.expect(ed.findAndSelect("ALPHA", true));
    try testing.expectEqual(Pos{ .line = 1, .col = 11 }, ed.cursor);
    try testing.expect(!ed.findAndSelect("fehlt", true));
}

test "random test: arbitrary commands, then undo everything" {
    const gpa = testing.allocator;
    const start_text = "erste zeile\n\tzweite mit tab\nGröße 🦅 👨‍👩‍👧 ende\n\nletzte";
    const snippets = [_][]const u8{ "a", "B", " ", "ä", "🦅", "_", ".", "wort", "x\ny", "\r\n" };

    var seed: u64 = 1;
    while (seed <= 30) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();
        var ed = try makeEditor(start_text);
        defer ed.deinit();

        var step: usize = 0;
        while (step < 600) : (step += 1) {
            const extend = rnd.boolean();
            switch (rnd.uintLessThan(u8, 26)) {
                0, 1, 2, 3 => try ed.typeText(snippets[rnd.uintLessThan(usize, 8)]),
                4 => try ed.insertText(snippets[rnd.uintLessThan(usize, snippets.len)]),
                5 => try ed.newline(),
                6 => try ed.tab(),
                7, 8 => try ed.backspace(),
                9 => try ed.deleteForward(),
                10 => try ed.deleteWordBack(),
                11 => try ed.deleteWordForward(),
                12 => ed.moveLeft(extend),
                13 => ed.moveRight(extend),
                14 => ed.moveLines(rnd.intRangeAtMost(isize, -3, 3), extend),
                15 => ed.moveWordLeft(extend),
                16 => ed.moveWordRight(extend),
                17 => ed.moveHome(extend),
                18 => ed.moveEnd(extend),
                19 => _ = try ed.undo(),
                20 => _ = try ed.redo(),
                21 => ed.setCursor(.{ .line = rnd.uintLessThan(usize, 12), .col = rnd.uintLessThan(usize, 40) }, extend),
                22 => ed.selectWordAt(.{ .line = rnd.uintLessThan(usize, 12), .col = rnd.uintLessThan(usize, 40) }),
                23 => {
                    if (try ed.cut(gpa)) |t| gpa.free(t);
                },
                24 => _ = ed.findAndSelect("e", rnd.boolean()),
                else => ed.selectLineAt(.{ .line = rnd.uintLessThan(usize, 12), .col = 0 }),
            }
            try ed.buf.checkInvariants();
            try expectCursorValid(&ed);
        }

        // Undo everything: the initial text must be back exactly.
        while (try ed.undo()) {}
        try expectContent(&ed, start_text);
        try testing.expect(!ed.isModified());
        // And redo everything, then undo again.
        while (try ed.redo()) {}
        while (try ed.undo()) {}
        try expectContent(&ed, start_text);
    }
}

test "cut whole line" {
    const gpa = testing.allocator;
    var ed = Editor.fromBuffer(gpa, try Buffer.fromBytes(gpa, "eins\nzwei äöü\ndrei"));
    defer ed.deinit();

    // In the middle of the file: line gone, cursor at the start of the line
    // that moved up.
    ed.setCursor(.{ .line = 1, .col = 3 }, false);
    const a = (try ed.cutLine(gpa)).?;
    defer gpa.free(a);
    try testing.expectEqualStrings("zwei äöü\n", a);
    try testing.expectEqual(@as(usize, 2), ed.buf.lineCount());
    try testing.expectEqualStrings("drei", ed.buf.line(1));
    try testing.expect(ed.cursor.eql(.{ .line = 1, .col = 0 }));
    try testing.expect(ed.selection() == null);

    // Last line: no empty line remains.
    const b = (try ed.cutLine(gpa)).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("drei\n", b);
    try testing.expectEqual(@as(usize, 1), ed.buf.lineCount());
    try testing.expect(ed.cursor.eql(.{ .line = 0, .col = 0 }));

    // Only line: becomes empty. After that there is nothing left to take.
    const c = (try ed.cutLine(gpa)).?;
    defer gpa.free(c);
    try testing.expectEqualStrings("eins\n", c);
    try testing.expectEqualStrings("", ed.buf.line(0));
    try testing.expect(try ed.cutLine(gpa) == null);

    // Every cut is its own undo step.
    _ = try ed.undo();
    _ = try ed.undo();
    _ = try ed.undo();
    const all = try ed.buf.toBytes(gpa, "\n");
    defer gpa.free(all);
    try testing.expectEqualStrings("eins\nzwei äöü\ndrei", all);
}

test "indent and outdent several lines" {
    var ed = try makeEditor("eins\nzwei\n\ndrei");
    defer ed.deinit();
    ed.setCursor(.{ .line = 0, .col = 2 }, false);
    ed.setCursor(.{ .line = 3, .col = 2 }, true);
    try ed.indentLines();
    try expectContent(&ed, "    eins\n    zwei\n\n    drei");
    // The selection moves along, the empty line stays empty.
    try testing.expectEqual(Pos{ .line = 0, .col = 6 }, ed.selection().?.start);
    try testing.expectEqual(Pos{ .line = 3, .col = 6 }, ed.selection().?.end);
    try expectCursorValid(&ed);

    try ed.dedentLines();
    try expectContent(&ed, "eins\nzwei\n\ndrei");
    try testing.expectEqual(Pos{ .line = 0, .col = 2 }, ed.selection().?.start);
    try ed.dedentLines(); // nothing left to remove
    try expectContent(&ed, "eins\nzwei\n\ndrei");

    // One undo step reverts the whole indentation.
    try ed.indentLines();
    _ = try ed.undo();
    try expectContent(&ed, "eins\nzwei\n\ndrei");

    // With real tabs.
    ed.soft_tabs = false;
    ed.setCursor(.{ .line = 1, .col = 1 }, false);
    try ed.indentLines();
    try expectContent(&ed, "eins\n\tzwei\n\ndrei");
    try ed.dedentLines();
    try expectContent(&ed, "eins\nzwei\n\ndrei");
}

test "toggle comment" {
    var ed = try makeEditor("a = 1\n    b = 2\n\nc");
    defer ed.deinit();
    ed.setCursor(.{ .line = 1, .col = 6 }, false);
    try ed.toggleComment("#");
    try expectContent(&ed, "a = 1\n    # b = 2\n\nc");
    try testing.expectEqual(Pos{ .line = 1, .col = 8 }, ed.cursor);
    try ed.toggleComment("#");
    try expectContent(&ed, "a = 1\n    b = 2\n\nc");
    try testing.expectEqual(Pos{ .line = 1, .col = 6 }, ed.cursor);

    // Several lines: the marker sits in the same column for all of them.
    ed.selectAll();
    try ed.toggleComment("//");
    try expectContent(&ed, "// a = 1\n//     b = 2\n\n// c");
    try expectCursorValid(&ed);
    // Mixed (one line without comment) means: comment everything out.
    ed.setCursor(.{ .line = 3, .col = 0 }, false);
    try ed.toggleComment("//");
    ed.selectAll();
    try ed.toggleComment("//");
    try expectContent(&ed, "// // a = 1\n// //     b = 2\n\n// c");
    _ = try ed.undo();
    _ = try ed.undo();
    _ = try ed.undo();
    try expectContent(&ed, "a = 1\n    b = 2\n\nc");
}

test "duplicate and move line" {
    var ed = try makeEditor("eins\nzwei\ndrei");
    defer ed.deinit();
    ed.setCursor(.{ .line = 1, .col = 2 }, false);
    try ed.duplicateLine();
    try expectContent(&ed, "eins\nzwei\nzwei\ndrei");
    try testing.expectEqual(Pos{ .line = 2, .col = 2 }, ed.cursor);
    _ = try ed.undo();

    try testing.expect(try ed.moveLine(true));
    try expectContent(&ed, "zwei\neins\ndrei");
    try testing.expectEqual(Pos{ .line = 0, .col = 2 }, ed.cursor);
    try testing.expect(!try ed.moveLine(true));
    try testing.expect(try ed.moveLine(false));
    try testing.expect(try ed.moveLine(false));
    try expectContent(&ed, "eins\ndrei\nzwei");
    try testing.expect(!try ed.moveLine(false));
    try expectCursorValid(&ed);
}

test "replace all in one undo step" {
    var ed = try makeEditor("Hund und hund\nkein Tier\nhundert Hunde");
    defer ed.deinit();
    // Without uppercase letters in the query, case is ignored.
    try testing.expectEqual(@as(usize, 4), try ed.replaceAll("hund", "Katze"));
    try expectContent(&ed, "Katze und Katze\nkein Tier\nKatzeert Katzee");
    try expectCursorValid(&ed);
    _ = try ed.undo();
    try expectContent(&ed, "Hund und hund\nkein Tier\nhundert Hunde");

    // The replacement may contain the query without looping forever.
    try testing.expectEqual(@as(usize, 2), try ed.replaceAll("Hund", "Hundehund"));
    try testing.expectEqual(@as(usize, 0), try ed.replaceAll("gibtsnicht", "x"));
    // Deleting via an empty replacement.
    _ = try ed.undo();
    try testing.expectEqual(@as(usize, 4), try ed.replaceAll("hund", ""));
    try expectContent(&ed, " und \nkein Tier\nert e");
}

test "bracket pairs" {
    var ed = try makeEditor("f(a[1], {\n  x: (2)\n})  ]");
    defer ed.deinit();
    try testing.expectEqual(Pos{ .line = 2, .col = 1 }, ed.matchingBracket(.{ .line = 0, .col = 1 }, 100).?);
    try testing.expectEqual(Pos{ .line = 0, .col = 1 }, ed.matchingBracket(.{ .line = 2, .col = 1 }, 100).?);
    try testing.expectEqual(Pos{ .line = 0, .col = 5 }, ed.matchingBracket(.{ .line = 0, .col = 3 }, 100).?);
    try testing.expectEqual(Pos{ .line = 2, .col = 0 }, ed.matchingBracket(.{ .line = 0, .col = 8 }, 100).?);
    // No bracket, bracket without partner, search limit too tight.
    try testing.expect(ed.matchingBracket(.{ .line = 0, .col = 0 }, 100) == null);
    try testing.expect(ed.matchingBracket(.{ .line = 2, .col = 4 }, 100) == null);
    try testing.expect(ed.matchingBracket(.{ .line = 0, .col = 1 }, 0) == null);
    // Cursor directly after the bracket counts too.
    ed.setCursor(.{ .line = 2, .col = 2 }, false);
    const pair = ed.bracketPair(100).?;
    try testing.expectEqual(Pos{ .line = 2, .col = 1 }, pair[0]);
    try testing.expectEqual(Pos{ .line = 0, .col = 1 }, pair[1]);
}

test "replacing the whole text is one step, and undo selects nothing" {
    var ed = try Editor.init(testing.allocator);
    defer ed.deinit();
    try ed.typeText("eins\nzwei\ndrei");
    ed.setCursor(.{ .line = 1, .col = 2 }, false);
    try ed.replaceText("alt\n");
    try expectContent(&ed, "alt\n");
    _ = try ed.undo();
    try expectContent(&ed, "eins\nzwei\ndrei");
    try testing.expect(ed.selection() == null);
    try testing.expectEqual(Pos{ .line = 1, .col = 2 }, ed.cursor);
}

/// Fails exactly one allocation or resize (the k-th), then works again: a
/// short squeeze, as out-of-memory usually is in practice.
const FailOnce = struct {
    inner: Allocator,
    k: usize,
    n: usize = 0,
    failed: bool = false,

    fn allocator(self: *FailOnce) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn hit(self: *FailOnce) bool {
        defer self.n += 1;
        if (self.n != self.k) return false;
        self.failed = true;
        return true;
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        return if (self.hit()) null else self.inner.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        return if (len > m.len and self.hit()) false else self.inner.rawResize(m, a, len, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        return if (len > m.len and self.hit()) null else self.inner.rawRemap(m, a, len, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(m, a, ra);
    }
};

/// Runs `op` on a fresh editor with `start` as text and lets the k-th
/// memory request fail, for every k until `op` gets through.
/// A short squeeze (one request fails): afterwards the text, cursor,
/// selection and undo state are exactly as before.
/// Memory gone for good (every request from the k-th on fails): no crash, a
/// valid cursor, and once memory is back a single undo restores the text.
fn expectAllOrNothing(start: []const u8, prepare: *const fn (*Editor) anyerror!void, op: *const fn (*Editor) anyerror!void) !void {
    var k: usize = 0;
    while (k < 2000) : (k += 1) {
        var once: FailOnce = .{ .inner = testing.allocator, .k = std.math.maxInt(usize) };
        const gpa = once.allocator();
        var ed = Editor.fromBuffer(gpa, try Buffer.fromBytes(gpa, start));
        defer ed.deinit();
        try prepare(&ed);
        const cursor = ed.cursor;
        const anchor = ed.anchor;
        const depth = ed.undo_stack.items.len;
        const modified = ed.isModified();
        once.k = once.n + k;
        op(&ed) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try expectContent(&ed, start);
            try testing.expectEqual(cursor, ed.cursor);
            try testing.expectEqual(anchor, ed.anchor);
            try testing.expectEqual(depth, ed.undo_stack.items.len);
            try testing.expectEqual(modified, ed.isModified());
            continue;
        };
        if (!once.failed) break;
        // The failed request was one the edit could do without.
    } else return error.TestUnexpectedResult;

    k = 0;
    while (k < 2000) : (k += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
        const gpa = failing.allocator();
        var ed = Editor.fromBuffer(gpa, try Buffer.fromBytes(gpa, start));
        defer ed.deinit();
        try prepare(&ed);
        const depth = ed.undo_stack.items.len;
        failing.fail_index = failing.alloc_index + k;
        failing.resize_fail_index = failing.resize_index + k;
        op(&ed) catch {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try ed.buf.checkInvariants();
            try expectCursorValid(&ed);
            if (ed.undo_stack.items.len > depth) _ = try ed.undo();
            try testing.expectEqual(depth, ed.undo_stack.items.len);
            try expectContent(&ed, start);
            continue;
        };
        break;
    } else return error.TestUnexpectedResult;
}

fn noPrep(_: *Editor) anyerror!void {}
fn prepSecondLine(ed: *Editor) anyerror!void {
    ed.setCursor(.{ .line = 1, .col = 2 }, false);
}
fn prepSelectAcross(ed: *Editor) anyerror!void {
    ed.setCursor(.{ .line = 0, .col = 2 }, false);
    ed.setCursor(.{ .line = 2, .col = 1 }, true);
}
fn prepTyped(ed: *Editor) anyerror!void {
    // Earlier typing merges with what comes next; a failure must not take it back.
    ed.setCursor(.{ .line = 2, .col = 0 }, false);
    try ed.typeText("x");
}

test "multi-part edits are all or nothing when memory runs out" {
    const start = "eins\nzwei äöü\ndrei\nvier";
    try expectAllOrNothing(start, noPrep, struct {
        fn f(ed: *Editor) anyerror!void {
            try ed.replaceText("ganz\nneuer\ntext\n");
        }
    }.f);
    try expectAllOrNothing(start, prepSecondLine, struct {
        fn f(ed: *Editor) anyerror!void {
            _ = try ed.moveLine(true);
        }
    }.f);
    try expectAllOrNothing(start, noPrep, struct {
        fn f(ed: *Editor) anyerror!void {
            _ = try ed.replaceFrom("e", "EEE", .{});
        }
    }.f);
    try expectAllOrNothing(start, prepSelectAcross, struct {
        fn f(ed: *Editor) anyerror!void {
            try ed.insertText("ein\r\nlanger\r\neinschub");
        }
    }.f);
    try expectAllOrNothing(start, prepSelectAcross, struct {
        fn f(ed: *Editor) anyerror!void {
            try ed.toggleComment("//");
        }
    }.f);
    try expectAllOrNothing(start, prepSelectAcross, struct {
        fn f(ed: *Editor) anyerror!void {
            try ed.tab();
        }
    }.f);
}

test "a failed edit keeps earlier typing it would have merged with" {
    var once: FailOnce = .{ .inner = testing.allocator, .k = std.math.maxInt(usize) };
    const gpa = once.allocator();
    var ed = Editor.fromBuffer(gpa, try Buffer.fromBytes(gpa, "ab\n"));
    defer ed.deinit();
    try prepTyped(&ed);
    once.k = once.n;
    try testing.expectError(error.OutOfMemory, ed.typeText("y"));
    try expectContent(&ed, "ab\nx");
}

test "search finds a match the cursor sits inside" {
    var ed = try makeEditor("hello\nworld");
    defer ed.deinit();
    const inside: Pos = .{ .line = 0, .col = 2 };
    const fwd = ed.find("hello", inside, true).?;
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, fwd.start);
    const back = ed.find("hello", inside, false).?;
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, back.start);
    // Backwards from the end of a match finds that match, not one before it.
    try testing.expectEqual(Pos{ .line = 1, .col = 0 }, ed.find("world", .{ .line = 1, .col = 3 }, false).?.start);
}

test "searching on from a selected match moves to the next one or stays" {
    var ed = try makeEditor("ab ab ab");
    defer ed.deinit();
    ed.setCursor(.{ .line = 0, .col = 3 }, false);
    try testing.expect(ed.findAndSelect("ab", true));
    try testing.expectEqual(Pos{ .line = 0, .col = 3 }, ed.anchor.?);
    try testing.expect(ed.findAndSelect("ab", true));
    try testing.expectEqual(Pos{ .line = 0, .col = 6 }, ed.anchor.?);
    try testing.expect(ed.findAndSelect("ab", true));
    try testing.expectEqual(Pos{ .line = 0, .col = 0 }, ed.anchor.?);
    try testing.expect(ed.findAndSelect("ab", false));
    try testing.expectEqual(Pos{ .line = 0, .col = 6 }, ed.anchor.?);
    // The only match: stays selected, in both directions.
    var one = try makeEditor("x only y");
    defer one.deinit();
    try testing.expect(one.findAndSelect("only", true));
    try testing.expect(one.findAndSelect("only", true));
    try testing.expectEqual(Pos{ .line = 0, .col = 2 }, one.anchor.?);
    try testing.expect(one.findAndSelect("only", false));
    try testing.expectEqual(Pos{ .line = 0, .col = 2 }, one.anchor.?);
}

test "word jumps and double click stay fast on a very long line" {
    // Minified JSON with a 200 KB base64 blob: each step used to scan the
    // line from its start, which froze iro for minutes.
    const gpa = testing.allocator;
    const blob_len = 200_000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "{\"blob\":\"");
    for (0..blob_len) |i| try src.append(gpa, "abcXYZ019+/"[i % 11]);
    try src.appendSlice(gpa, "\",\"日本\":\"é👨‍👩‍👧\"}");
    var ed = try makeEditor(src.items);
    defer ed.deinit();

    const start = std.Io.Timestamp.now(testing.io, .awake);
    ed.selectWordAt(.{ .line = 0, .col = 9 + blob_len / 2 });
    try testing.expect(ed.selection() != null);
    ed.setCursor(.{ .line = 0, .col = 9 }, false);
    ed.moveWordRight(false);
    try testing.expect(ed.cursor.col > 9);
    ed.setCursor(.{ .line = 0, .col = src.items.len }, false);
    var steps: usize = 0;
    while (ed.cursor.col > 0) : (steps += 1) ed.moveWordLeft(false);
    const ms = start.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
    // Takes a few milliseconds now; the old way needed far longer than this.
    try testing.expect(ms < 2_000);
    try testing.expect(steps > 3);
}

test "undo after cutting a line brings the cursor back, nothing selected" {
    const gpa = testing.allocator;
    const cases = [_]struct { text: []const u8, at: Pos }{
        .{ .text = "eins\nzwei äöü\ndrei", .at = .{ .line = 1, .col = 3 } }, // middle
        .{ .text = "eins\nzwei", .at = .{ .line = 1, .col = 2 } }, // last line
        .{ .text = "eins", .at = .{ .line = 0, .col = 1 } }, // only line
    };
    for (cases) |case| {
        var ed = Editor.fromBuffer(gpa, try Buffer.fromBytes(gpa, case.text));
        defer ed.deinit();
        ed.setCursor(case.at, false);
        const cut = (try ed.cutLine(gpa)).?;
        gpa.free(cut);
        try testing.expect(try ed.undo());
        try expectContent(&ed, case.text);
        try testing.expect(ed.selection() == null);
        try testing.expect(ed.cursor.eql(case.at));
        // Redo cuts it again.
        try testing.expect(try ed.redo());
        try testing.expect(ed.selection() == null);
    }
}
