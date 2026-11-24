// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! The core of iro: everything that works without a terminal and can therefore
//! be tested fully automatically.

pub const buffer = @import("buffer.zig");
pub const text = @import("text.zig");
pub const editor = @import("editor.zig");
pub const fileio = @import("fileio.zig");
pub const syntax = @import("syntax.zig");
pub const tree = @import("tree.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const finder = @import("finder.zig");
pub const config = @import("config.zig");
pub const lang = @import("lang.zig");
pub const gitdiff = @import("gitdiff.zig");
pub const icons = @import("icons.zig");
pub const minimap = @import("minimap.zig");
pub const help = @import("help.zig");
pub const complete = @import("complete.zig");
pub const about = @import("about.zig");
pub const menu = @import("menu.zig");
pub const settings = @import("settings.zig");
pub const index = @import("index.zig");
pub const search = @import("search.zig");
pub const history = @import("history.zig");
pub const guard = @import("guard.zig");
pub const signals = @import("signals.zig");

pub const Buffer = buffer.Buffer;
pub const Pos = buffer.Pos;
pub const Editor = editor.Editor;
pub const Range = editor.Range;

test {
    _ = buffer;
    _ = text;
    _ = editor;
    _ = fileio;
    _ = syntax;
    _ = tree;
    _ = fuzzy;
    _ = finder;
    _ = config;
    _ = lang;
    _ = gitdiff;
    _ = icons;
    _ = minimap;
    _ = help;
    _ = complete;
    _ = about;
    _ = menu;
    _ = settings;
    _ = index;
    _ = signals;
    _ = search;
    _ = history;
    _ = guard;
}
