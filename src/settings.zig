// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! The settings page (main menu → Settings): what it shows and how iro writes
//! the chosen values to `~/.config/iro/gewaehlt.lua`.
//!
//! iro never touches init.lua. It is read after gewaehlt.lua and therefore
//! always has the last word; whatever it sets is shown with a lock on the page.
//!
//! iro writes gewaehlt.lua in a fixed, simple form, so this file can read it
//! back without Lua (`Chosen.parse`). Drawing happens in draw.zig, input
//! handling in main.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const Cmd = config.Cmd;
const lang = @import("lang.zig");
const Lang = lang.Lang;
const Text = lang.Text;

pub const Kind = enum { header, toggle, theme, tab_width, indent, gear, language, key, open_init };

pub const Item = struct {
    kind: Kind,
    /// Lua name: global variable, or for keys the name inside `keys`.
    lua: []const u8 = "",
    label: Text,
    /// One sentence of explanation, at the bottom of the card.
    say: Text = .{ .de = "", .en = "" },
    cmd: ?Cmd = null,
};

const fixed = [_]Item{
    .{ .kind = .header, .label = .{ .de = "Aussehen", .en = "Appearance" } },
    .{ .kind = .theme, .lua = "theme", .label = .{ .de = "Farbsatz", .en = "Color scheme" }, .say = .{
        .de = "„terminal“ nimmt die Farben deines Terminals und folgt damit dem Wallpaper. ←/→ schaltet durch, die Wirkung siehst du sofort.",
        .en = "\"terminal\" uses your terminal's colors, so it follows your wallpaper. ←/→ cycles through, changes show instantly.",
    } },
    .{ .kind = .toggle, .lua = "icons", .label = .{ .de = "Nerd-Font-Symbole", .en = "Nerd Font icons" }, .say = .{
        .de = "Kleine Symbole in Baum, Tabs, Menü und Statuszeile. Braucht eine Nerd-Font im Terminal.",
        .en = "Small icons in the tree, tabs, menu and status bar. Needs a Nerd Font in your terminal.",
    } },
    .{ .kind = .toggle, .lua = "indent_guides", .label = .{ .de = "Einrückhilfen", .en = "Indent guides" }, .say = .{
        .de = "Feine senkrechte Linien in der Einrückung.",
        .en = "Thin vertical lines inside the indentation.",
    } },
    .{ .kind = .toggle, .lua = "scrollbar", .label = .{ .de = "Rollbalken", .en = "Scrollbar" }, .say = .{
        .de = "Schmaler Balken rechts, sobald die Datei länger ist als das Fenster.",
        .en = "A slim bar on the right once the file is longer than the window.",
    } },
    .{ .kind = .toggle, .lua = "minimap", .label = .{ .de = "Minimap", .en = "Minimap" }, .say = .{
        .de = "Die ganze Datei als Braille-Punkte rechts am Rand, anklickbar.",
        .en = "The whole file as Braille dots along the right edge, clickable.",
    } },
    .{ .kind = .toggle, .lua = "wrap", .label = .{ .de = "Zeilenumbruch", .en = "Soft wrap" }, .say = .{
        .de = "Lange Zeilen am Fensterrand umbrechen statt seitlich zu scrollen.",
        .en = "Wrap long lines at the window edge instead of scrolling sideways.",
    } },
    .{ .kind = .toggle, .lua = "git_gutter", .label = .{ .de = "Git-Spalte", .en = "Git gutter" }, .say = .{
        .de = "Neben den Zeilennummern: was seit dem letzten Commit neu, geändert oder weg ist.",
        .en = "Next to the line numbers: what is new, changed or gone since the last commit.",
    } },
    .{ .kind = .toggle, .lua = "trailing_spaces", .label = .{ .de = "Leerzeichen am Zeilenende", .en = "Trailing whitespace" }, .say = .{
        .de = "Überflüssige Leerzeichen am Zeilenende sichtbar machen.",
        .en = "Make stray spaces at the end of a line visible.",
    } },
    .{ .kind = .toggle, .lua = "brackets", .label = .{ .de = "Klammer-Paare", .en = "Bracket pairs" }, .say = .{
        .de = "Die Klammer am Cursor und ihr Gegenstück hervorheben.",
        .en = "Highlight the bracket at the cursor and its partner.",
    } },
    .{ .kind = .toggle, .lua = "animations", .label = .{ .de = "Animationen", .en = "Animations" }, .say = .{
        .de = "Baum-Gleiten, Zeilen-Puls und der Effekt bei „Über iro“. Kosten im Leerlauf nichts.",
        .en = "Tree slide, line pulse and the effect in \"About iro\". They cost nothing while idle.",
    } },
    .{ .kind = .toggle, .lua = "start_screen", .label = .{ .de = "Startseite", .en = "Start screen" }, .say = .{
        .de = "Logo und Kurzbefehle, wenn iro ohne Datei startet.",
        .en = "Logo and shortcuts when iro starts without a file.",
    } },
    .{ .kind = .header, .label = .{ .de = "Bedienung", .en = "Behavior" } },
    .{ .kind = .gear, .lua = "gear", .label = .{ .de = "Gear beim Start", .en = "Gear at startup" }, .say = .{
        .de = "Blade: nur der Text, für Configs. Forge: Baum, Minimap, Git. „automatisch“: Einzeldatei → Blade, sonst → Forge. Alt+G wechselt jederzeit.",
        .en = "Blade: just the text, for configs. Forge: tree, minimap, git. \"auto\": single file → Blade, otherwise → Forge. Alt+G switches anytime.",
    } },
    .{ .kind = .toggle, .lua = "auto_gear", .label = .{ .de = "Automatikgetriebe", .en = "Automatic gear shift" }, .say = .{
        .de = "Schaltet in Blade automatisch zu Forge hoch, sobald du Dateibaum, zweiten Tab, geteilte Ansicht oder Dateisuche öffnest.",
        .en = "In Blade, automatically shifts up to Forge when you open the file tree, a second tab, split view or file search.",
    } },
    .{ .kind = .language, .lua = "language", .label = .{ .de = "Sprache · Language", .en = "Language · Sprache" }, .say = .{
        .de = "„automatisch“ folgt der Sprache deines Systems (LANG). ←/→ schaltet um, sofort.",
        .en = "\"auto\" follows your system language (LANG). ←/→ switches, instantly.",
    } },
    .{ .kind = .toggle, .lua = "esc_menu", .label = .{ .de = "Esc öffnet das Hauptmenü", .en = "Esc opens the main menu" }, .say = .{
        .de = "Nur wenn Esc gerade nichts anderes aufzuheben hat. F10 geht immer.",
        .en = "Only when Esc has nothing else to cancel. F10 always works.",
    } },
    .{ .kind = .toggle, .lua = "tree_on_start", .label = .{ .de = "Dateibaum beim Start", .en = "File tree at startup" }, .say = .{
        .de = "Den Dateibaum gleich beim Start einblenden (nur in Forge).",
        .en = "Show the file tree right at startup (Forge only).",
    } },
    .{ .kind = .toggle, .lua = "dotfiles", .label = .{ .de = "Punkt-Dateien im Baum", .en = "Dotfiles in the tree" }, .say = .{
        .de = "Versteckte Dateien wie .gitignore im Baum zeigen.",
        .en = "Show hidden files like .gitignore in the tree.",
    } },
    .{ .kind = .toggle, .lua = "history", .label = .{ .de = "Frühere Versionen aufheben", .en = "Keep earlier versions" }, .say = .{
        .de = "Vor jedem Speichern kommt der alte Stand in den Verlauf, die letzten 20 pro Datei. Alt+R holt ihn zurück. Geheimnisse bekommen keine Kopien.",
        .en = "Before every save the old state goes into the history, the last 20 per file. Alt+R brings it back. Secrets get no copies.",
    } },
    .{ .kind = .toggle, .lua = "config_guard", .label = .{ .de = "Config Guard", .en = "Config Guard" }, .say = .{
        .de = "Prüft bekannte Configs (fstab, sudoers, sshd, systemd, Shell, JSON, Hyprland) beim Speichern und warnt bei Fehlern.",
        .en = "Checks known configs (fstab, sudoers, sshd, systemd, shell, JSON, Hyprland) on save and warns on errors.",
    } },
    .{ .kind = .tab_width, .lua = "tab_width", .label = .{ .de = "Tab-Breite", .en = "Tab width" }, .say = .{
        .de = "Wie breit ein Tab aussieht und wie weit Tab einrückt. ←/→ ändert.",
        .en = "How wide a tab looks and how far Tab indents. ←/→ changes it.",
    } },
    .{ .kind = .indent, .lua = "spaces", .label = .{ .de = "Einrücken mit", .en = "Indent with" }, .say = .{
        .de = "„automatisch“ schaut pro Datei, was sie schon benutzt. ←/→ schaltet durch.",
        .en = "\"auto\" looks at what each file already uses. ←/→ cycles through.",
    } },
    .{ .kind = .header, .label = .{ .de = "Tasten", .en = "Keys" } },
};

const tail = [_]Item{
    .{ .kind = .header, .label = .{ .de = "Von Hand", .en = "By hand" } },
    .{ .kind = .open_init, .label = .{ .de = "init.lua öffnen …", .en = "Open init.lua …" }, .say = .{
        .de = "Für alles, was hier nicht steht (Farben, eigener Lua-Code). Was dort steht, gewinnt.",
        .en = "For everything not listed here (colors, your own Lua code). Whatever is in there wins.",
    } },
};

/// Everything on the page: fixed entries, then every command with its key, then
/// the link to init.lua.
pub const items: [fixed.len + config.cmd_specs.len + tail.len]Item = blk: {
    var out: [fixed.len + config.cmd_specs.len + tail.len]Item = undefined;
    for (fixed, 0..) |it, i| out[i] = it;
    for (config.cmd_specs, 0..) |spec, i| out[fixed.len + i] = .{
        .kind = .key,
        .lua = spec.lua_key,
        .label = spec.name,
        .say = .{
            .de = "Enter, dann die neue Taste drücken. Dort: Entf schaltet die Taste ab, Esc bricht ab.",
            .en = "Enter, then press the new key. There: Del disables the key, Esc cancels.",
        },
        .cmd = spec.cmd,
    };
    for (tail, 0..) |it, i| out[fixed.len + config.cmd_specs.len + i] = it;
    break :blk out;
};

pub fn selectable(i: usize) bool {
    return i < items.len and items[i].kind != .header;
}

/// Next selectable entry; stops at the edges (the list is long, wrapping around
/// would not help).
pub fn move(sel: usize, delta: isize) usize {
    var i: isize = @intCast(@min(sel, items.len - 1));
    const step: isize = if (delta < 0) -1 else 1;
    var left: usize = @abs(delta);
    var best = sel;
    while (left > 0) {
        i += step;
        if (i < 0 or i >= items.len) break;
        if (selectable(@intCast(i))) {
            best = @intCast(i);
            left -= 1;
        }
    }
    return best;
}

pub fn first() usize {
    return move(0, 1);
}

pub fn last() usize {
    return if (selectable(items.len - 1)) items.len - 1 else move(items.len - 1, -1);
}

/// The first row of the list to show so that entry `sel` is visible, with
/// its heading above it if there is room. `list_h`: rows of the list.
pub fn keepVisible(sel: usize, top: usize, list_h: usize) usize {
    var t = top;
    if (sel < t) t = sel;
    if (sel >= t + list_h) t = sel + 1 - list_h;
    if (t > 0 and t == sel and !selectable(t - 1)) t -= 1;
    return @min(t, items.len -| list_h);
}

pub const View = struct { sel: usize, top: usize };

/// Mouse wheel: scrolls the list by `delta` rows. Where the selection would
/// leave the view it comes along, to the first or last entry still shown;
/// otherwise `keepVisible` would scroll straight back to it.
pub fn scroll(sel: usize, top: usize, delta: isize, list_h: usize) View {
    if (list_h == 0) return .{ .sel = sel, .top = top };
    const max_top: isize = @intCast(items.len -| list_h);
    const t: usize = @intCast(std.math.clamp(@as(isize, @intCast(top)) + delta, 0, max_top));
    const end = @min(t + list_h, items.len);
    var s = sel;
    if (s < t) {
        var i = t;
        while (i < end and !selectable(i)) i += 1;
        if (i < end) s = i;
    } else if (s >= end) {
        var i = end;
        while (i > t) {
            i -= 1;
            if (selectable(i)) {
                s = i;
                break;
            }
        }
    }
    return .{ .sel = s, .top = t };
}

pub const theme_names = blk: {
    var out: [config.presets.len][]const u8 = undefined;
    for (config.presets, 0..) |p, i| out[i] = p.name;
    break :blk out;
};

/// Next theme in direction `dir`.
pub fn cycleTheme(current: []const u8, dir: isize) []const u8 {
    var idx: usize = 0;
    for (theme_names, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, current)) idx = i;
    }
    const n: isize = theme_names.len;
    return theme_names[@intCast(@mod(@as(isize, @intCast(idx)) + dir, n))];
}

/// Indentation: automatic (nothing set), spaces, tabs.
pub fn cycleIndent(current: ?bool, dir: isize) ?bool {
    const order = [_]?bool{ null, true, false };
    var idx: usize = 0;
    for (order, 0..) |o, i| {
        if (o == current) idx = i;
    }
    return order[@intCast(@mod(@as(isize, @intCast(idx)) + dir, 3))];
}

/// Gear at start: automatic (nothing set), Blade, Forge.
pub fn cycleGear(current: ?config.Gear, dir: isize) ?config.Gear {
    const order = [_]?config.Gear{ null, .blade, .forge };
    var idx: usize = 0;
    for (order, 0..) |o, i| {
        if (o == current) idx = i;
    }
    return order[@intCast(@mod(@as(isize, @intCast(idx)) + dir, 3))];
}

pub fn gearName(v: ?config.Gear, l: Lang) []const u8 {
    return if (v) |g| (if (g == .blade) "Blade" else "Forge") else auto(l);
}

fn auto(l: Lang) []const u8 {
    return if (l == .en) "auto" else "automatisch";
}

/// Language: automatic (nothing set), English, Deutsch.
pub fn cycleLanguage(current: ?Lang, dir: isize) ?Lang {
    const order = [_]?Lang{ null, .en, .de };
    var idx: usize = 0;
    for (order, 0..) |o, i| {
        if (o == current) idx = i;
    }
    return order[@intCast(@mod(@as(isize, @intCast(idx)) + dir, 3))];
}

/// Language names are always shown in their own language, so you can find your
/// way back from the wrong one.
pub fn languageName(v: ?Lang, l: Lang) []const u8 {
    return if (v) |x| (if (x == .en) "English" else "Deutsch") else auto(l);
}

pub fn languageLua(x: Lang) []const u8 {
    return if (x == .en) "\"en\"" else "\"de\"";
}

/// How the value appears in gewaehlt.lua.
pub fn gearLua(g: config.Gear) []const u8 {
    return if (g == .blade) "\"blade\"" else "\"forge\"";
}

pub fn indentName(v: ?bool, l: Lang) []const u8 {
    return if (v) |s| (if (s) (if (l == .en) "Spaces" else "Leerzeichen") else "Tabs") else auto(l);
}

/// What was chosen on the page. Values are stored as ready-made Lua text
/// (`false`, `4`, `"nord"`), keys as key names ("" = disabled).
pub const Chosen = struct {
    values: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    keys: std.StringArrayHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Chosen, gpa: Allocator) void {
        for (self.values.values()) |v| gpa.free(v);
        for (self.keys.values()) |v| gpa.free(v);
        self.values.deinit(gpa);
        self.keys.deinit(gpa);
        self.* = .{};
    }

    /// The name must be one from `items`; the fixed string from there is
    /// stored, so no foreign pointers are left dangling.
    fn staticName(raw_name: []const u8, want_key: bool) ?[]const u8 {
        // Older gewaehlt.lua files contain German names. They become English here,
        // and the file is rewritten that way on the next change.
        const name = config.canonical(raw_name);
        for (items) |it| {
            if ((it.kind == .key) != want_key) continue;
            if (it.lua.len > 0 and std.mem.eql(u8, it.lua, name)) return it.lua;
        }
        return null;
    }

    fn put(map: *std.StringArrayHashMapUnmanaged([]u8), gpa: Allocator, name: []const u8, value: []const u8) Allocator.Error!void {
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        const gop = try map.getOrPut(gpa, name);
        if (gop.found_existing) gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = v;
    }

    pub fn set(self: *Chosen, gpa: Allocator, name: []const u8, lua_value: []const u8) Allocator.Error!void {
        const n = staticName(name, false) orelse return;
        try put(&self.values, gpa, n, lua_value);
    }

    pub fn setKey(self: *Chosen, gpa: Allocator, lua_key: []const u8, label: []const u8) Allocator.Error!void {
        const n = staticName(lua_key, true) orelse return;
        try put(&self.keys, gpa, n, label);
    }

    /// Back to the default: the entry disappears from the file.
    pub fn unset(self: *Chosen, gpa: Allocator, name: []const u8, is_key: bool) void {
        const map = if (is_key) &self.keys else &self.values;
        if (map.fetchOrderedRemove(config.canonical(name))) |kv| gpa.free(kv.value);
    }

    pub fn has(self: *const Chosen, name: []const u8, is_key: bool) bool {
        return (if (is_key) self.keys else self.values).contains(config.canonical(name));
    }

    pub fn keyOf(self: *const Chosen, lua_key: []const u8) ?[]const u8 {
        return self.keys.get(config.canonical(lua_key));
    }

    /// The content of gewaehlt.lua.
    pub fn render(self: *const Chosen, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa,
            \\-- Von iro geschrieben: das, was du auf der Einstellungsseite
            \\-- (Hauptmenü → Einstellungen) angeklickt hast.
            \\-- Bitte nicht von Hand ändern, iro schreibt die Datei bei jedem Klick neu.
            \\-- Eigene Wünsche gehören in die init.lua. Die wird danach gelesen
            \\-- und hat immer das letzte Wort.
            \\
        );
        for (self.values.keys(), self.values.values()) |k, v| {
            try out.print(gpa, "{s} = {s}\n", .{ k, v });
        }
        if (self.keys.count() > 0) {
            try out.appendSlice(gpa, "keys = {\n");
            for (self.keys.keys(), self.keys.values()) |k, v| {
                try out.print(gpa, "    {s} = \"", .{k});
                for (v) |c| {
                    if (c == '"' or c == '\\') try out.append(gpa, '\\');
                    try out.append(gpa, c);
                }
                try out.appendSlice(gpa, "\",\n");
            }
            try out.appendSlice(gpa, "}\n");
        }
        return out.toOwnedSlice(gpa);
    }

    /// Reads a gewaehlt.lua in the form `render` writes. Lines that don't fit
    /// are skipped.
    pub fn parse(gpa: Allocator, src: []const u8) Allocator.Error!Chosen {
        var c: Chosen = .{};
        errdefer c.deinit(gpa);
        var in_keys = false;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or std.mem.startsWith(u8, line, "--")) continue;
            if ((std.mem.startsWith(u8, line, "keys") or std.mem.startsWith(u8, line, "tasten")) and std.mem.endsWith(u8, line, "{")) {
                in_keys = true;
                continue;
            }
            if (in_keys and line[0] == '}') {
                in_keys = false;
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const name = std.mem.trim(u8, line[0..eq], " \t");
            var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (in_keys) {
                if (std.mem.endsWith(u8, value, ",")) value = std.mem.trimEnd(u8, value[0 .. value.len - 1], " \t");
                if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') continue;
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(gpa);
                var i: usize = 1;
                while (i + 1 < value.len) : (i += 1) {
                    if (value[i] == '\\' and i + 2 < value.len) i += 1;
                    try buf.append(gpa, value[i]);
                }
                try c.setKey(gpa, name, buf.items);
            } else {
                if (value.len == 0) continue;
                try c.set(gpa, name, value);
            }
        }
        return c;
    }
};

test "page: every command has a key entry, headings are not selectable" {
    var keys: usize = 0;
    for (items) |it| {
        if (it.kind == .key) keys += 1;
        if (it.kind == .toggle) {
            var cfg: config.Config = .{};
            try std.testing.expect(cfg.boolPtr(it.lua) != null);
        }
    }
    try std.testing.expectEqual(config.cmd_specs.len, keys);
    try std.testing.expect(!selectable(0));
    try std.testing.expect(selectable(first()));
    try std.testing.expectEqual(first(), move(first(), -1));
    try std.testing.expectEqual(items.len - 1, last());
    // Across the "Behaviour" heading.
    var i: usize = first();
    while (items[i].lua.len == 0 or !std.mem.eql(u8, items[i].lua, "start_screen")) i += 1;
    try std.testing.expectEqualStrings("gear", items[move(i, 1)].lua);
}

test "theme and indentation cycle around" {
    try std.testing.expectEqualStrings("mohawk", cycleTheme("terminal", 1));
    try std.testing.expectEqualStrings("bernstein", cycleTheme("terminal", -1));
    try std.testing.expectEqual(@as(?bool, true), cycleIndent(null, 1));
    try std.testing.expectEqual(@as(?bool, null), cycleIndent(false, 1));
    try std.testing.expectEqual(@as(?config.Gear, .blade), cycleGear(null, 1));
    try std.testing.expectEqual(@as(?config.Gear, null), cycleGear(.forge, 1));
    try std.testing.expectEqual(@as(?config.Gear, .forge), cycleGear(null, -1));
    try std.testing.expectEqualStrings("automatisch", gearName(null, .de));
    try std.testing.expectEqualStrings("auto", gearName(null, .en));
    try std.testing.expectEqual(@as(?Lang, .en), cycleLanguage(null, 1));
    try std.testing.expectEqualStrings("Deutsch", languageName(.de, .en));
}

test "gewaehlt.lua: write, read back, Lua understands it" {
    const gpa = std.testing.allocator;
    var c: Chosen = .{};
    defer c.deinit(gpa);
    try c.set(gpa, "minimap", "false");
    try c.set(gpa, "thema", "\"nord\"");
    try c.set(gpa, "tab_breite", "2");
    try c.set(gpa, "unbekannt", "true"); // is ignored
    try c.setKey(gpa, "speichern", "Strg+E");
    try c.setKey(gpa, "suchen", "");
    try c.setKey(gpa, "kommentar", "Strg+\"");
    c.unset(gpa, "tab_breite", false);

    const txt = try c.render(gpa);
    defer gpa.free(txt);
    try std.testing.expect(std.mem.indexOf(u8, txt, "unbekannt") == null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "tab_breite") == null);
    // German names are written to the file in English.
    try std.testing.expect(std.mem.indexOf(u8, txt, "theme = \"nord\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "keys = {") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "save = \"Strg+E\"") != null);

    var back = try Chosen.parse(gpa, txt);
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("false", back.values.get("minimap").?);
    try std.testing.expectEqualStrings("Strg+E", back.keyOf("speichern").?);
    try std.testing.expectEqualStrings("", back.keyOf("suchen").?);
    try std.testing.expectEqualStrings("Strg+\"", back.keyOf("kommentar").?);

    // The same file through the real Lua loader, as the lower layer.
    var cfg = try config.Config.loadLayered(gpa, txt, "minimap = true");
    defer cfg.deinit(gpa);
    try std.testing.expect(cfg.err_msg == null);
    try std.testing.expect(cfg.minimap); // init.lua wins
    try std.testing.expect(cfg.isPinned("minimap"));
    try std.testing.expect(!cfg.isPinned("thema"));
    try std.testing.expectEqualStrings("nord", cfg.theme_name);
    try std.testing.expectEqualStrings("Strg+E", cfg.keyLabel(.save));
    try std.testing.expectEqualStrings("", cfg.keyLabel(.search));
}

test "empty keys table in init.lua does not erase chosen keys" {
    const gpa = std.testing.allocator;
    var cfg = try config.Config.loadLayered(gpa, "tasten = {\n    speichern = \"Strg+E\",\n}\n", "tasten = {\n    -- speichern = \"Strg+S\",\n}\n");
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("Strg+E", cfg.keyLabel(.save));
    try std.testing.expect(!cfg.keyPinned(.save));
}

test "pressed key becomes config text and back" {
    const gpa = std.testing.allocator;
    const Key = @import("vaxis").Key;
    const cases = [_]struct { key: Key, want: []const u8 }{
        .{ .key = .{ .codepoint = 'e', .mods = .{ .ctrl = true } }, .want = "Strg+E" },
        .{ .key = .{ .codepoint = 's', .mods = .{ .ctrl = true, .shift = true } }, .want = "Strg+Umschalt+S" },
        .{ .key = .{ .codepoint = Key.f7 }, .want = "F7" },
        .{ .key = .{ .codepoint = Key.page_down, .mods = .{ .alt = true } }, .want = "Alt+Bild ab" },
        .{ .key = .{ .codepoint = ',', .mods = .{ .ctrl = true } }, .want = "Strg+Komma" },
        .{ .key = .{ .codepoint = '+', .mods = .{ .ctrl = true } }, .want = "Strg+Plus" },
    };
    for (cases) |cs| {
        const label = (try config.labelForKey(gpa, cs.key)).?;
        defer gpa.free(label);
        try std.testing.expectEqualStrings(cs.want, label);
        const kb = (try config.KeyBind.parse(gpa, label)).?;
        defer kb.deinit(gpa);
        try std.testing.expect(kb.matches(cs.key));
    }
    try std.testing.expect((try config.labelForKey(gpa, .{ .codepoint = Key.left_shift })) == null);
}

test "every theme loads by name, retro themes colour the text too" {
    const gpa = std.testing.allocator;
    for (theme_names) |name| {
        const src = try std.fmt.allocPrint(gpa, "thema = \"{s}\"", .{name});
        defer gpa.free(src);
        var cfg = try config.Config.loadFromSlice(gpa, src);
        defer cfg.deinit(gpa);
        try std.testing.expect(cfg.err_msg == null);
        try std.testing.expectEqualStrings(name, cfg.theme_name);
    }
    var cfg = try config.Config.loadFromSlice(gpa, "thema = \"phosphor\"");
    defer cfg.deinit(gpa);
    try std.testing.expect(cfg.theme.text != .default);
    try std.testing.expect(theme_names.len >= 17);
}

test "mouse wheel scrolls the settings list instead of snapping back" {
    const list_h = 10;
    var sel = first();
    var top = keepVisible(sel, 0, list_h);
    const max_top = items.len - list_h;
    try std.testing.expect(max_top > 6);
    // Down to the end, the way drawing settles it after each step.
    var steps: usize = 0;
    while (top < max_top) : (steps += 1) {
        const v = scroll(sel, top, 3, list_h);
        sel = v.sel;
        const before = top;
        top = keepVisible(sel, v.top, list_h);
        try std.testing.expect(top > before);
        try std.testing.expect(selectable(sel) and sel >= top and sel < top + list_h);
        try std.testing.expect(steps < items.len);
    }
    // And back up.
    while (top > 0) {
        const v = scroll(sel, top, -3, list_h);
        sel = v.sel;
        const before = top;
        top = keepVisible(sel, v.top, list_h);
        try std.testing.expect(top < before);
        try std.testing.expect(selectable(sel) and sel >= top and sel < top + list_h);
    }
    // A selection that stays in view is left alone.
    const v = scroll(first(), 0, 0, list_h);
    try std.testing.expectEqual(first(), v.sel);
}
