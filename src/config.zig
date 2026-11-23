// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Settings from Lua (`~/.config/iro/init.lua`): options, keys and colours.
//!
//! Binds the Lua 5.4 C library directly. A broken `init.lua` never crashes iro:
//! syntax, runtime and input errors end up readable in `err_msg` and are shown
//! in the status line.

const std = @import("std");
const lang = @import("lang.zig");
pub const Lang = lang.Lang;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const Key = vaxis.Key;

pub const ColorSpec = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,
};

/// A colour that iro may compute to suit the terminal background ("auto"), that
/// is omitted entirely ("off"), or that is fixed.
pub const AutoColor = union(enum) {
    auto,
    off,
    color: ColorSpec,
};

fn hex(comptime s: *const [7]u8) ColorSpec {
    const d = struct {
        fn digit(c: u8) u8 {
            return switch (c) {
                '0'...'9' => c - '0',
                'A'...'F' => c - 'A' + 10,
                'a'...'f' => c - 'a' + 10,
                else => @compileError("keine Hex-Ziffer"),
            };
        }
    }.digit;
    return .{ .rgb = .{
        d(s[1]) * 16 + d(s[2]),
        d(s[3]) * 16 + d(s[4]),
        d(s[5]) * 16 + d(s[6]),
    } };
}

/// Built-in themes for `theme = "…"`. "terminal" (the default) uses the
/// terminal palette and therefore follows the wallpaper.
pub const presets = blk: {
    // Every hex colour is computed at compile time; with this many themes Zig
    // needs a larger evaluation budget than usual.
    @setEvalBranchQuota(200_000);
    break :blk [_]struct { name: []const u8, theme: Theme }{
    .{ .name = "terminal", .theme = .{} },
    .{ .name = "mohawk", .theme = .{
        .akzent = hex("#00E5FF"),
        .tasten = hex("#FF0087"),
        .warnung = hex("#FFB300"),
        .fehler = hex("#FF3B5C"),
        .kommentar = hex("#5C7A82"),
        .zeichenkette = hex("#FF7AC6"),
        .zahl = hex("#FFB86C"),
        .befehlswort = hex("#B388FF"),
        .schluessel = hex("#E6F7FA"),
        .ueberschrift = hex("#00E5FF"),
        .git_neu = hex("#3DDC97"),
        .git_geaendert = hex("#00B8D4"),
        .git_weg = hex("#FF3B5C"),
    } },
    .{ .name = "nord", .theme = .{
        .akzent = hex("#88C0D0"),
        .tasten = hex("#EBCB8B"),
        .warnung = hex("#EBCB8B"),
        .fehler = hex("#BF616A"),
        .kommentar = hex("#616E88"),
        .zeichenkette = hex("#A3BE8C"),
        .zahl = hex("#B48EAD"),
        .befehlswort = hex("#81A1C1"),
        .schluessel = hex("#D8DEE9"),
        .ueberschrift = hex("#8FBCBB"),
        .git_neu = hex("#A3BE8C"),
        .git_geaendert = hex("#EBCB8B"),
        .git_weg = hex("#BF616A"),
    } },
    .{ .name = "gruvbox", .theme = .{
        .akzent = hex("#83A598"),
        .tasten = hex("#FABD2F"),
        .warnung = hex("#FE8019"),
        .fehler = hex("#FB4934"),
        .kommentar = hex("#928374"),
        .zeichenkette = hex("#B8BB26"),
        .zahl = hex("#D3869B"),
        .befehlswort = hex("#FB4934"),
        .schluessel = hex("#EBDBB2"),
        .ueberschrift = hex("#FABD2F"),
        .git_neu = hex("#B8BB26"),
        .git_geaendert = hex("#83A598"),
        .git_weg = hex("#FB4934"),
    } },
    .{ .name = "catppuccin", .theme = .{
        .akzent = hex("#89B4FA"),
        .tasten = hex("#F5C2E7"),
        .warnung = hex("#F9E2AF"),
        .fehler = hex("#F38BA8"),
        .kommentar = hex("#6C7086"),
        .zeichenkette = hex("#A6E3A1"),
        .zahl = hex("#FAB387"),
        .befehlswort = hex("#CBA6F7"),
        .schluessel = hex("#CDD6F4"),
        .ueberschrift = hex("#89DCEB"),
        .git_neu = hex("#A6E3A1"),
        .git_geaendert = hex("#F9E2AF"),
        .git_weg = hex("#F38BA8"),
    } },
    .{ .name = "tokyonacht", .theme = .{
        .akzent = hex("#7AA2F7"),
        .tasten = hex("#BB9AF7"),
        .warnung = hex("#E0AF68"),
        .fehler = hex("#F7768E"),
        .kommentar = hex("#565F89"),
        .zeichenkette = hex("#9ECE6A"),
        .zahl = hex("#FF9E64"),
        .befehlswort = hex("#BB9AF7"),
        .schluessel = hex("#C0CAF5"),
        .ueberschrift = hex("#7DCFFF"),
        .git_neu = hex("#9ECE6A"),
        .git_geaendert = hex("#E0AF68"),
        .git_weg = hex("#F7768E"),
    } },
    // Dracula: purple and pink, the night-shift classic.
    .{ .name = "dracula", .theme = .{
        .text = hex("#F8F8F2"),
        .akzent = hex("#BD93F9"),
        .tasten = hex("#FF79C6"),
        .warnung = hex("#F1FA8C"),
        .fehler = hex("#FF5555"),
        .kommentar = hex("#6272A4"),
        .zeichenkette = hex("#F1FA8C"),
        .zahl = hex("#BD93F9"),
        .befehlswort = hex("#FF79C6"),
        .schluessel = hex("#8BE9FD"),
        .ueberschrift = hex("#BD93F9"),
        .git_neu = hex("#50FA7B"),
        .git_geaendert = hex("#FFB86C"),
        .git_weg = hex("#FF5555"),
    } },
    // Rosé Pine: muted, rosé and gold, very calm.
    .{ .name = "rosepine", .theme = .{
        .text = hex("#E0DEF4"),
        .akzent = hex("#9CCFD8"),
        .tasten = hex("#EBBCBA"),
        .warnung = hex("#F6C177"),
        .fehler = hex("#EB6F92"),
        .kommentar = hex("#6E6A86"),
        .zeichenkette = hex("#F6C177"),
        .zahl = hex("#EBBCBA"),
        .befehlswort = hex("#C4A7E7"),
        .schluessel = hex("#E0DEF4"),
        .ueberschrift = hex("#C4A7E7"),
        .git_neu = hex("#9CCFD8"),
        .git_geaendert = hex("#F6C177"),
        .git_weg = hex("#EB6F92"),
    } },
    // Kanagawa: ink and woodblock, after Hokusai's Great Wave.
    .{ .name = "kanagawa", .theme = .{
        .text = hex("#DCD7BA"),
        .akzent = hex("#7E9CD8"),
        .tasten = hex("#D27E99"),
        .warnung = hex("#FF9E3B"),
        .fehler = hex("#E82424"),
        .kommentar = hex("#727169"),
        .zeichenkette = hex("#98BB6C"),
        .zahl = hex("#D27E99"),
        .befehlswort = hex("#957FB8"),
        .schluessel = hex("#E6C384"),
        .ueberschrift = hex("#7FB4CA"),
        .git_neu = hex("#76946A"),
        .git_geaendert = hex("#DCA561"),
        .git_weg = hex("#C34043"),
    } },
    // Everforest: forest green, warm and easy on the eyes.
    .{ .name = "everforest", .theme = .{
        .text = hex("#D3C6AA"),
        .akzent = hex("#A7C080"),
        .tasten = hex("#DBBC7F"),
        .warnung = hex("#E69875"),
        .fehler = hex("#E67E80"),
        .kommentar = hex("#859289"),
        .zeichenkette = hex("#83C092"),
        .zahl = hex("#D699B6"),
        .befehlswort = hex("#E67E80"),
        .schluessel = hex("#7FBBB3"),
        .ueberschrift = hex("#A7C080"),
        .git_neu = hex("#A7C080"),
        .git_geaendert = hex("#DBBC7F"),
        .git_weg = hex("#E67E80"),
    } },
    // One Dark: the colours everyone knows from Atom and VS Code.
    .{ .name = "onedark", .theme = .{
        .text = hex("#ABB2BF"),
        .akzent = hex("#61AFEF"),
        .tasten = hex("#C678DD"),
        .warnung = hex("#E5C07B"),
        .fehler = hex("#E06C75"),
        .kommentar = hex("#5C6370"),
        .zeichenkette = hex("#98C379"),
        .zahl = hex("#D19A66"),
        .befehlswort = hex("#C678DD"),
        .schluessel = hex("#E06C75"),
        .ueberschrift = hex("#61AFEF"),
        .git_neu = hex("#98C379"),
        .git_geaendert = hex("#E5C07B"),
        .git_weg = hex("#E06C75"),
    } },
    // Solarized Dark: scientifically tuned, unbreakable since 2011.
    .{ .name = "solarized", .theme = .{
        .text = hex("#839496"),
        .akzent = hex("#268BD2"),
        .tasten = hex("#D33682"),
        .warnung = hex("#B58900"),
        .fehler = hex("#DC322F"),
        .kommentar = hex("#586E75"),
        .zeichenkette = hex("#2AA198"),
        .zahl = hex("#D33682"),
        .befehlswort = hex("#859900"),
        .schluessel = hex("#93A1A1"),
        .ueberschrift = hex("#CB4B16"),
        .git_neu = hex("#859900"),
        .git_geaendert = hex("#B58900"),
        .git_weg = hex("#DC322F"),
    } },
    // Monokai: punchy, like Sublime Text in the old days.
    .{ .name = "monokai", .theme = .{
        .text = hex("#F8F8F2"),
        .akzent = hex("#A6E22E"),
        .tasten = hex("#F92672"),
        .warnung = hex("#FD971F"),
        .fehler = hex("#F92672"),
        .kommentar = hex("#75715E"),
        .zeichenkette = hex("#E6DB74"),
        .zahl = hex("#AE81FF"),
        .befehlswort = hex("#F92672"),
        .schluessel = hex("#66D9EF"),
        .ueberschrift = hex("#A6E22E"),
        .git_neu = hex("#A6E22E"),
        .git_geaendert = hex("#FD971F"),
        .git_weg = hex("#F92672"),
    } },
    // Ayu Dark: gold on night, clear and modern.
    .{ .name = "ayu", .theme = .{
        .text = hex("#BFBDB6"),
        .akzent = hex("#E6B450"),
        .tasten = hex("#59C2FF"),
        .warnung = hex("#FFB454"),
        .fehler = hex("#D95757"),
        .kommentar = hex("#626A73"),
        .zeichenkette = hex("#AAD94C"),
        .zahl = hex("#D2A6FF"),
        .befehlswort = hex("#FF8F40"),
        .schluessel = hex("#59C2FF"),
        .ueberschrift = hex("#E6B450"),
        .git_neu = hex("#7FD962"),
        .git_geaendert = hex("#73B8FF"),
        .git_weg = hex("#F26D78"),
    } },
    // Synthwave: eighties neon.
    .{ .name = "synthwave", .theme = .{
        .text = hex("#F0EFF4"),
        .akzent = hex("#36F9F6"),
        .tasten = hex("#FF7EDB"),
        .warnung = hex("#FEDE5D"),
        .fehler = hex("#FE4450"),
        .kommentar = hex("#848BBD"),
        .zeichenkette = hex("#FF8B39"),
        .zahl = hex("#F97E72"),
        .befehlswort = hex("#FEDE5D"),
        .schluessel = hex("#FF7EDB"),
        .ueberschrift = hex("#36F9F6"),
        .git_neu = hex("#72F1B8"),
        .git_geaendert = hex("#FEDE5D"),
        .git_weg = hex("#FE4450"),
    } },
    // Phosphor (iro original): green CRT monitor, even the text glows.
    .{ .name = "phosphor", .theme = .{
        .text = hex("#5CFF8A"),
        .akzent = hex("#33FF66"),
        .tasten = hex("#B6FF4D"),
        .warnung = hex("#E6FF4D"),
        .fehler = hex("#FF5C5C"),
        .kommentar = hex("#2E7A47"),
        .zeichenkette = hex("#9CFFB8"),
        .zahl = hex("#C9FFD3"),
        .befehlswort = hex("#33FF66"),
        .schluessel = hex("#D6FFE0"),
        .ueberschrift = hex("#7DFFA6"),
        .git_neu = hex("#33FF66"),
        .git_geaendert = hex("#B6FF4D"),
        .git_weg = hex("#FF5C5C"),
    } },
    // Bernstein (iro original): amber terminal like forty years ago.
    .{ .name = "bernstein", .theme = .{
        .text = hex("#FFB347"),
        .akzent = hex("#FFB000"),
        .tasten = hex("#FFD24D"),
        .warnung = hex("#FFE08A"),
        .fehler = hex("#FF6A3D"),
        .kommentar = hex("#8A5A14"),
        .zeichenkette = hex("#FFC966"),
        .zahl = hex("#FFE4A8"),
        .befehlswort = hex("#FF9500"),
        .schluessel = hex("#FFE9C2"),
        .ueberschrift = hex("#FFC233"),
        .git_neu = hex("#FFD24D"),
        .git_geaendert = hex("#FFA200"),
        .git_weg = hex("#FF6A3D"),
    } },
};
};

/// All names for messages and the template: "terminal, mohawk, …".
pub const preset_list = blk: {
    var out: []const u8 = "";
    for (presets, 0..) |p, i| out = out ++ (if (i == 0) "" else ", ") ++ p.name;
    break :blk out;
};

pub const Theme = struct {
    /// Colour of normal text. Default: the terminal's foreground colour.
    text: ColorSpec = .default,
    akzent: ColorSpec = .{ .index = 6 },
    tasten: ColorSpec = .{ .index = 3 },
    warnung: ColorSpec = .{ .index = 3 },
    fehler: ColorSpec = .{ .index = 1 },
    kommentar: ColorSpec = .{ .index = 8 },
    zeichenkette: ColorSpec = .{ .index = 11 },
    zahl: ColorSpec = .{ .index = 3 },
    befehlswort: ColorSpec = .{ .index = 5 },
    schluessel: ColorSpec = .{ .index = 7 },
    ueberschrift: ColorSpec = .{ .index = 6 },
    /// Git gutter and diff files: added, changed, removed.
    git_neu: ColorSpec = .{ .index = 2 },
    git_geaendert: ColorSpec = .{ .index = 4 },
    git_weg: ColorSpec = .{ .index = 1 },
    /// Background of the line containing the cursor.
    cursorzeile: AutoColor = .auto,
    /// Background of selected text. "off": inverted colours as before.
    auswahl: AutoColor = .auto,
};

pub const Scope = enum { global, text, tree };

/// All commands that can be bound to keys and (almost all) appear in the
/// command palette.
pub const Cmd = enum {
    palette,
    save,
    save_as,
    history,
    open,
    open_path,
    jump_dir,
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    search,
    search_next,
    goto_line,
    replace,
    comment,
    duplicate_line,
    line_up,
    line_down,
    undo,
    redo,
    select_all,
    copy,
    cut,
    paste,
    doc_start,
    doc_end,
    tree,
    tree_here,
    tree_hidden,
    tree_refresh,
    tree_new_file,
    tree_new_dir,
    tree_rename,
    tree_trash,
    complete,
    wrap,
    split,
    minimap,
    gear,
    hints,
    settings,
    open_config,
    reload_config,
    help,
    menu,
    about,
    quit,
};

pub const CmdMeta = struct {
    cmd: Cmd,
    /// Name in `keys = { … }` in init.lua, plus the German one iro also understands.
    lua_key: [:0]const u8,
    lua_de: [:0]const u8,
    name: lang.Text,
    default_key: []const u8,
    fallback_key: []const u8 = "",
    palette_hint: lang.Text = .{ .de = "", .en = "" },
    scope: Scope,
    in_palette: bool = true,
};

/// The order of this list also determines the order in the command palette.
pub const cmd_specs = [_]CmdMeta{
    .{ .cmd = .palette, .lua_key = "palette", .lua_de = "befehle", .name = .{ .de = "Befehlspalette öffnen", .en = "Open command palette" }, .default_key = "Strg+P", .scope = .global, .in_palette = false },
    .{ .cmd = .save, .lua_key = "save", .lua_de = "speichern", .name = .{ .de = "Datei speichern", .en = "Save file" }, .default_key = "Strg+S", .scope = .global },
    .{ .cmd = .save_as, .lua_key = "save_as", .lua_de = "speichern_unter", .name = .{ .de = "Datei speichern unter …", .en = "Save file as …" }, .default_key = "F12", .fallback_key = "Strg+Umschalt+S", .scope = .global },
    .{ .cmd = .history, .lua_key = "history", .lua_de = "versionen", .name = .{ .de = "Frühere Versionen dieser Datei …", .en = "Earlier versions of this file …" }, .default_key = "Alt+R", .scope = .global },
    .{ .cmd = .open, .lua_key = "open", .lua_de = "oeffnen", .name = .{ .de = "Datei öffnen: suchen …", .en = "Open file: search …" }, .default_key = "Strg+O", .scope = .global },
    .{ .cmd = .open_path, .lua_key = "open_path", .lua_de = "oeffnen_pfad", .name = .{ .de = "Datei öffnen: Pfad eintippen …", .en = "Open file: type a path …" }, .default_key = "", .palette_hint = .{ .de = "Strg+O, Tab", .en = "Ctrl+O, Tab" }, .scope = .global },
    .{ .cmd = .jump_dir, .lua_key = "jump_dir", .lua_de = "ordner_sprung", .name = .{ .de = "Ordner wechseln (zoxide) …", .en = "Switch folder (zoxide) …" }, .default_key = "Alt+Z", .scope = .global },
    .{ .cmd = .new_tab, .lua_key = "new_tab", .lua_de = "tab_neu", .name = .{ .de = "Tab: neu", .en = "Tab: new" }, .default_key = "Strg+N", .scope = .global },
    .{ .cmd = .close_tab, .lua_key = "close_tab", .lua_de = "tab_schliessen", .name = .{ .de = "Tab: schließen", .en = "Tab: close" }, .default_key = "Strg+W", .scope = .global },
    .{ .cmd = .next_tab, .lua_key = "next_tab", .lua_de = "tab_naechster", .name = .{ .de = "Tab: nächster", .en = "Tab: next" }, .default_key = "Strg+Bild ab", .fallback_key = "Strg+Tab", .scope = .global },
    .{ .cmd = .prev_tab, .lua_key = "prev_tab", .lua_de = "tab_vorheriger", .name = .{ .de = "Tab: vorheriger", .en = "Tab: previous" }, .default_key = "Strg+Bild auf", .fallback_key = "Strg+Umschalt+Tab", .scope = .global },
    .{ .cmd = .search, .lua_key = "search", .lua_de = "suchen", .name = .{ .de = "Suchen …", .en = "Find …" }, .default_key = "Strg+F", .scope = .text },
    .{ .cmd = .search_next, .lua_key = "search_next", .lua_de = "weitersuchen", .name = .{ .de = "Weitersuchen", .en = "Find next" }, .default_key = "F3", .scope = .text },
    .{ .cmd = .goto_line, .lua_key = "goto_line", .lua_de = "gehe_zu_zeile", .name = .{ .de = "Gehe zu Zeile …", .en = "Go to line …" }, .default_key = "Strg+G", .scope = .text },
    .{ .cmd = .replace, .lua_key = "replace", .lua_de = "ersetzen", .name = .{ .de = "Suchen und ersetzen …", .en = "Find and replace …" }, .default_key = "Strg+R", .scope = .text },
    .{ .cmd = .comment, .lua_key = "comment", .lua_de = "kommentar", .name = .{ .de = "Kommentar ein/aus", .en = "Toggle comment" }, .default_key = "Strg+K", .fallback_key = "Strg+/", .scope = .text },
    .{ .cmd = .duplicate_line, .lua_key = "duplicate_line", .lua_de = "zeile_verdoppeln", .name = .{ .de = "Zeile verdoppeln", .en = "Duplicate line" }, .default_key = "Strg+D", .scope = .text },
    .{ .cmd = .line_up, .lua_key = "line_up", .lua_de = "zeile_hoch", .name = .{ .de = "Zeile nach oben schieben", .en = "Move line up" }, .default_key = "Alt+Hoch", .scope = .text },
    .{ .cmd = .line_down, .lua_key = "line_down", .lua_de = "zeile_runter", .name = .{ .de = "Zeile nach unten schieben", .en = "Move line down" }, .default_key = "Alt+Runter", .scope = .text },
    .{ .cmd = .undo, .lua_key = "undo", .lua_de = "rueckgaengig", .name = .{ .de = "Rückgängig", .en = "Undo" }, .default_key = "Strg+Z", .scope = .text },
    .{ .cmd = .redo, .lua_key = "redo", .lua_de = "wiederholen", .name = .{ .de = "Wiederholen", .en = "Redo" }, .default_key = "Strg+Y", .fallback_key = "Strg+Umschalt+Z", .scope = .text },
    .{ .cmd = .select_all, .lua_key = "select_all", .lua_de = "alles_markieren", .name = .{ .de = "Alles markieren", .en = "Select all" }, .default_key = "Strg+A", .scope = .text },
    .{ .cmd = .copy, .lua_key = "copy", .lua_de = "kopieren", .name = .{ .de = "Kopieren", .en = "Copy" }, .default_key = "Strg+C", .scope = .text },
    .{ .cmd = .cut, .lua_key = "cut", .lua_de = "ausschneiden", .name = .{ .de = "Ausschneiden", .en = "Cut" }, .default_key = "Strg+X", .scope = .text },
    .{ .cmd = .paste, .lua_key = "paste", .lua_de = "einfuegen", .name = .{ .de = "Einfügen", .en = "Paste" }, .default_key = "Strg+V", .scope = .text },
    .{ .cmd = .doc_start, .lua_key = "doc_start", .lua_de = "dateianfang", .name = .{ .de = "Zum Dateianfang", .en = "Go to start of file" }, .default_key = "Strg+Pos1", .scope = .text },
    .{ .cmd = .doc_end, .lua_key = "doc_end", .lua_de = "dateiende", .name = .{ .de = "Zum Dateiende", .en = "Go to end of file" }, .default_key = "Strg+Ende", .scope = .text },
    .{ .cmd = .tree, .lua_key = "tree", .lua_de = "baum", .name = .{ .de = "Dateibaum: ein/aus", .en = "File tree: show/hide" }, .default_key = "Strg+B", .scope = .global },
    .{ .cmd = .tree_here, .lua_key = "tree_here", .lua_de = "baum_hier", .name = .{ .de = "Dateibaum: Ordner der aktuellen Datei zeigen", .en = "File tree: show folder of current file" }, .default_key = "", .scope = .global },
    .{ .cmd = .tree_hidden, .lua_key = "tree_hidden", .lua_de = "baum_versteckte", .name = .{ .de = "Dateibaum: Punkt-Dateien ein/aus", .en = "File tree: show/hide dotfiles" }, .default_key = ".", .scope = .tree },
    .{ .cmd = .tree_refresh, .lua_key = "tree_refresh", .lua_de = "baum_neu_lesen", .name = .{ .de = "Dateibaum: neu lesen", .en = "File tree: reload" }, .default_key = "F5", .scope = .tree },
    .{ .cmd = .tree_new_file, .lua_key = "tree_new_file", .lua_de = "baum_neue_datei", .name = .{ .de = "Dateibaum: neue Datei …", .en = "File tree: new file …" }, .default_key = "N", .scope = .tree },
    .{ .cmd = .tree_new_dir, .lua_key = "tree_new_dir", .lua_de = "baum_neuer_ordner", .name = .{ .de = "Dateibaum: neuer Ordner …", .en = "File tree: new folder …" }, .default_key = "O", .scope = .tree },
    .{ .cmd = .tree_rename, .lua_key = "tree_rename", .lua_de = "baum_umbenennen", .name = .{ .de = "Dateibaum: umbenennen …", .en = "File tree: rename …" }, .default_key = "F2", .fallback_key = "U", .scope = .tree },
    .{ .cmd = .tree_trash, .lua_key = "tree_trash", .lua_de = "baum_papierkorb", .name = .{ .de = "Dateibaum: in den Papierkorb legen …", .en = "File tree: move to trash …" }, .default_key = "Entf", .scope = .tree },
    .{ .cmd = .complete, .lua_key = "complete", .lua_de = "vervollstaendigen", .name = .{ .de = "Wort vervollständigen", .en = "Complete word" }, .default_key = "Strg+Leer", .fallback_key = "Alt+Leer", .scope = .text },
    .{ .cmd = .wrap, .lua_key = "wrap", .lua_de = "zeilenumbruch", .name = .{ .de = "Zeilenumbruch: ein/aus", .en = "Soft wrap: on/off" }, .default_key = "Alt+W", .scope = .global },
    .{ .cmd = .split, .lua_key = "split", .lua_de = "ansicht_teilen", .name = .{ .de = "Ansicht teilen: ein/aus", .en = "Split view: on/off" }, .default_key = "Alt+V", .scope = .global },
    .{ .cmd = .minimap, .lua_key = "minimap", .lua_de = "minimap", .name = .{ .de = "Minimap: ein/aus", .en = "Minimap: on/off" }, .default_key = "Alt+M", .scope = .global },
    .{ .cmd = .gear, .lua_key = "gear", .lua_de = "gear", .name = .{ .de = "Gear wechseln: Blade ⇄ Forge", .en = "Switch gear: Blade ⇄ Forge" }, .default_key = "Alt+G", .scope = .global },
    .{ .cmd = .hints, .lua_key = "hints", .lua_de = "hinweise", .name = .{ .de = "Hinweisleiste: ein/aus", .en = "Hint bar: on/off" }, .default_key = "F1", .scope = .global },
    .{ .cmd = .settings, .lua_key = "settings", .lua_de = "einstellungsseite", .name = .{ .de = "Einstellungen …", .en = "Settings …" }, .default_key = "", .scope = .global },
    .{ .cmd = .open_config, .lua_key = "open_config", .lua_de = "einstellungen", .name = .{ .de = "Einstellungen öffnen (init.lua)", .en = "Open settings file (init.lua)" }, .default_key = "", .scope = .global },
    .{ .cmd = .reload_config, .lua_key = "reload_config", .lua_de = "neu_laden", .name = .{ .de = "Einstellungen neu laden", .en = "Reload settings" }, .default_key = "", .scope = .global },
    .{ .cmd = .help, .lua_key = "help", .lua_de = "hilfe", .name = .{ .de = "Hilfe: alle Tasten kurz erklärt", .en = "Help: every key explained" }, .default_key = "Alt+H", .scope = .global },
    .{ .cmd = .menu, .lua_key = "menu", .lua_de = "menue", .name = .{ .de = "Hauptmenü öffnen", .en = "Open main menu" }, .default_key = "F10", .scope = .global },
    .{ .cmd = .about, .lua_key = "about", .lua_de = "ueber", .name = .{ .de = "Über iro", .en = "About iro" }, .default_key = "F9", .scope = .global },
    .{ .cmd = .quit, .lua_key = "quit", .lua_de = "beenden", .name = .{ .de = "Beenden", .en = "Quit" }, .default_key = "Strg+Q", .scope = .global },
};

pub const KeyBind = struct {
    codepoint: u21,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    /// How the key appears on screen, German and English.
    label: []const u8,
    label_en: []const u8 = "",
    owned: bool = false,

    pub fn deinit(self: KeyBind, gpa: Allocator) void {
        if (!self.owned) return;
        gpa.free(self.label);
        gpa.free(self.label_en);
    }

    pub fn labelIn(self: KeyBind, l: Lang) []const u8 {
        return if (l == .en) self.label_en else self.label;
    }

    pub fn matches(self: KeyBind, key: Key) bool {
        return key.matches(self.codepoint, .{
            .ctrl = self.ctrl,
            .alt = self.alt,
            .shift = self.shift,
        });
    }

    pub fn eqlKey(a: KeyBind, b: KeyBind) bool {
        return a.codepoint == b.codepoint and a.ctrl == b.ctrl and a.alt == b.alt and a.shift == b.shift;
    }

    /// Parses a key name such as "Strg+S", "Alt+Z", "Strg+Umschalt+S", "F12",
    /// "Strg+Bild ab". `null` for empty input (= key disabled).
    pub fn parse(gpa: Allocator, spec: []const u8) !?KeyBind {
        const trimmed = std.mem.trim(u8, spec, " \t");
        if (trimmed.len == 0) return null;

        var ctrl = false;
        var alt = false;
        var shift = false;
        var key_tok: []const u8 = "";

        var i: usize = 0;
        while (i <= trimmed.len) {
            const rest = trimmed[i..];
            const plus = std.mem.indexOfScalar(u8, rest, '+');
            if (plus) |p| {
                // A trailing "+" after "Strg++" means the plus key itself.
                if (p == 0 and i + 1 == trimmed.len) {
                    key_tok = "+";
                    break;
                }
                const mod = std.mem.trim(u8, rest[0..p], " \t");
                if (std.ascii.eqlIgnoreCase(mod, "strg") or std.ascii.eqlIgnoreCase(mod, "ctrl")) {
                    ctrl = true;
                } else if (std.ascii.eqlIgnoreCase(mod, "alt")) {
                    alt = true;
                } else if (std.ascii.eqlIgnoreCase(mod, "umschalt") or std.ascii.eqlIgnoreCase(mod, "shift")) {
                    shift = true;
                } else {
                    return error.InvalidKey;
                }
                i += p + 1;
            } else {
                key_tok = std.mem.trim(u8, rest, " \t");
                break;
            }
        }
        if (key_tok.len == 0) return error.InvalidKey;

        const cp = parseKeyName(key_tok) orelse return error.InvalidKey;
        const label = try formatLabel(gpa, .de, ctrl, alt, shift, cp, key_tok);
        errdefer gpa.free(label);
        const label_en = try formatLabel(gpa, .en, ctrl, alt, shift, cp, key_tok);
        return .{
            .codepoint = cp,
            .ctrl = ctrl,
            .alt = alt,
            .shift = shift,
            .label = label,
            .label_en = label_en,
            .owned = true,
        };
    }

    fn parseStatic(comptime spec: []const u8) ?KeyBind {
        if (spec.len == 0) return null;
        var ctrl = false;
        var alt = false;
        var shift = false;
        var rest: []const u8 = spec;
        while (std.mem.indexOfScalar(u8, rest, '+')) |p| {
            const mod = rest[0..p];
            if (std.ascii.eqlIgnoreCase(mod, "strg") or std.ascii.eqlIgnoreCase(mod, "ctrl")) {
                ctrl = true;
            } else if (std.ascii.eqlIgnoreCase(mod, "alt")) {
                alt = true;
            } else if (std.ascii.eqlIgnoreCase(mod, "umschalt") or std.ascii.eqlIgnoreCase(mod, "shift")) {
                shift = true;
            } else @compileError("Unbekannter Modifier in Vorgabe: " ++ spec);
            rest = rest[p + 1 ..];
        }
        const cp = parseKeyName(rest) orelse @compileError("Unbekannte Taste in Vorgabe: " ++ spec);
        return .{ .codepoint = cp, .ctrl = ctrl, .alt = alt, .shift = shift, .label = spec, .label_en = lang.keyLabelEnStatic(spec), .owned = false };
    }
};

/// Turns a pressed key into config text ("Strg+E"). `null`: this key cannot be
/// bound (e.g. a lone modifier).
pub fn labelForKey(gpa: Allocator, key: Key) Allocator.Error!?[]u8 {
    const cp = key.codepoint;
    var buf: [4]u8 = undefined;
    const raw: []const u8 = switch (cp) {
        Key.f1...Key.f12, Key.home, Key.end, Key.page_up, Key.page_down, Key.enter, Key.tab, Key.backspace, Key.delete, Key.insert, Key.escape, Key.space, Key.up, Key.down, Key.left, Key.right => "",
        '+' => "Plus",
        ',' => "Komma",
        '.' => "Punkt",
        else => blk: {
            // kitty's special keys (media keys, lone modifiers …) live in the
            // Unicode private use area and are unknown to the config.
            if (cp < 0x21 or cp == 0x7F or (cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0xF0000) return null;
            const n = std.unicode.utf8Encode(cp, &buf) catch return null;
            break :blk buf[0..n];
        },
    };
    // gewaehlt.lua always uses the German spelling, which the parser has always
    // known. It is then displayed in the selected language.
    const label = try formatLabel(gpa, .de, key.mods.ctrl, key.mods.alt, key.mods.shift, cp, raw);
    return label;
}

fn parseKeyName(tok: []const u8) ?u21 {
    const Named = struct { n: []const u8, cp: u21 };
    const table = [_]Named{
        .{ .n = "f1", .cp = Key.f1 },
        .{ .n = "f2", .cp = Key.f2 },
        .{ .n = "f3", .cp = Key.f3 },
        .{ .n = "f4", .cp = Key.f4 },
        .{ .n = "f5", .cp = Key.f5 },
        .{ .n = "f6", .cp = Key.f6 },
        .{ .n = "f7", .cp = Key.f7 },
        .{ .n = "f8", .cp = Key.f8 },
        .{ .n = "f9", .cp = Key.f9 },
        .{ .n = "f10", .cp = Key.f10 },
        .{ .n = "f11", .cp = Key.f11 },
        .{ .n = "f12", .cp = Key.f12 },
        .{ .n = "pos1", .cp = Key.home },
        .{ .n = "home", .cp = Key.home },
        .{ .n = "ende", .cp = Key.end },
        .{ .n = "end", .cp = Key.end },
        .{ .n = "bild auf", .cp = Key.page_up },
        .{ .n = "bild_auf", .cp = Key.page_up },
        .{ .n = "pageup", .cp = Key.page_up },
        .{ .n = "page_up", .cp = Key.page_up },
        .{ .n = "bild ab", .cp = Key.page_down },
        .{ .n = "bild_ab", .cp = Key.page_down },
        .{ .n = "pagedown", .cp = Key.page_down },
        .{ .n = "page_down", .cp = Key.page_down },
        .{ .n = "eingabe", .cp = Key.enter },
        .{ .n = "enter", .cp = Key.enter },
        .{ .n = "return", .cp = Key.enter },
        .{ .n = "tab", .cp = Key.tab },
        .{ .n = "ruecktaste", .cp = Key.backspace },
        .{ .n = "backspace", .cp = Key.backspace },
        .{ .n = "entf", .cp = Key.delete },
        .{ .n = "del", .cp = Key.delete },
        .{ .n = "delete", .cp = Key.delete },
        .{ .n = "einfg", .cp = Key.insert },
        .{ .n = "insert", .cp = Key.insert },
        .{ .n = "esc", .cp = Key.escape },
        .{ .n = "escape", .cp = Key.escape },
        .{ .n = "leertaste", .cp = Key.space },
        .{ .n = "leer", .cp = Key.space },
        .{ .n = "space", .cp = Key.space },
        .{ .n = "hoch", .cp = Key.up },
        .{ .n = "up", .cp = Key.up },
        .{ .n = "runter", .cp = Key.down },
        .{ .n = "down", .cp = Key.down },
        .{ .n = "links", .cp = Key.left },
        .{ .n = "left", .cp = Key.left },
        .{ .n = "rechts", .cp = Key.right },
        .{ .n = "right", .cp = Key.right },
        .{ .n = "komma", .cp = ',' },
        .{ .n = "comma", .cp = ',' },
        .{ .n = "punkt", .cp = '.' },
        .{ .n = "period", .cp = '.' },
        .{ .n = "plus", .cp = '+' },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(tok, entry.n)) return entry.cp;
    }
    if (std.mem.eql(u8, tok, "Rücktaste") or std.mem.eql(u8, tok, "rücktaste")) return Key.backspace;
    const cp_len = std.unicode.utf8ByteSequenceLength(tok[0]) catch return null;
    if (cp_len != tok.len) return null;
    const cp = std.unicode.utf8Decode(tok) catch return null;
    if (cp >= 'A' and cp <= 'Z') return cp + ('a' - 'A');
    return cp;
}

fn canonicalKeyToken(cp: u21, raw: []const u8, buf: []u8) []const u8 {
    return switch (cp) {
        Key.f1 => "F1",
        Key.f2 => "F2",
        Key.f3 => "F3",
        Key.f4 => "F4",
        Key.f5 => "F5",
        Key.f6 => "F6",
        Key.f7 => "F7",
        Key.f8 => "F8",
        Key.f9 => "F9",
        Key.f10 => "F10",
        Key.f11 => "F11",
        Key.f12 => "F12",
        Key.home => "Pos1",
        Key.end => "Ende",
        Key.page_up => "Bild auf",
        Key.page_down => "Bild ab",
        Key.enter => "Enter",
        Key.tab => "Tab",
        Key.backspace => "Rücktaste",
        Key.delete => "Entf",
        Key.insert => "Einfg",
        Key.escape => "Esc",
        Key.space => "Leer",
        Key.up => "Hoch",
        Key.down => "Runter",
        Key.left => "Links",
        Key.right => "Rechts",
        else => if (cp >= 'a' and cp <= 'z') blk: {
            buf[0] = @intCast(cp - ('a' - 'A'));
            break :blk buf[0..1];
        } else raw,
    };
}

fn formatLabel(gpa: Allocator, l: Lang, ctrl: bool, alt: bool, shift: bool, cp: u21, raw: []const u8) ![]u8 {
    var upper: [1]u8 = undefined;
    const de = canonicalKeyToken(cp, raw, &upper);
    const k = if (l == .en) lang.keyTokenEn(de) else de;
    return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{
        if (ctrl) (if (l == .en) "Ctrl+" else "Strg+") else "",
        if (alt) "Alt+" else "",
        if (shift) (if (l == .en) "Shift+" else "Umschalt+") else "",
        k,
    });
}

const cmd_count = cmd_specs.len;

pub const BindingSlot = struct {
    bind: ?KeyBind,
    fallback: ?KeyBind,
    overridden: bool = false,
};

fn defaultSlots() [cmd_count]BindingSlot {
    @setEvalBranchQuota(20_000);
    var slots: [cmd_count]BindingSlot = undefined;
    for (cmd_specs, 0..) |s, i| {
        slots[i] = .{
            .bind = KeyBind.parseStatic(s.default_key),
            .fallback = KeyBind.parseStatic(s.fallback_key),
        };
    }
    return slots;
}

/// A name in init.lua, English, plus the German one iro still understands (from
/// older versions, or for those who prefer German).
pub const Alias = struct { en: [:0]const u8, de: [:0]const u8 };

pub const setting_aliases = [_]Alias{
    .{ .en = "hints", .de = "hinweise" },
    .{ .en = "tab_width", .de = "tab_breite" },
    .{ .en = "spaces", .de = "leerzeichen" },
    .{ .en = "tree_on_start", .de = "baum_beim_start" },
    .{ .en = "dotfiles", .de = "punkt_dateien" },
    .{ .en = "start_screen", .de = "startseite" },
    .{ .en = "icons", .de = "symbole" },
    .{ .en = "indent_guides", .de = "einrueckhilfen" },
    .{ .en = "scrollbar", .de = "rollbalken" },
    .{ .en = "wrap", .de = "zeilenumbruch" },
    .{ .en = "animations", .de = "animationen" },
    .{ .en = "git_gutter", .de = "git_spalte" },
    .{ .en = "trailing_spaces", .de = "leerzeichen_am_ende" },
    .{ .en = "brackets", .de = "klammern" },
    .{ .en = "esc_menu", .de = "esc_menue" },
    .{ .en = "history", .de = "versionen" },
    .{ .en = "config_guard", .de = "fallschirm" },
    .{ .en = "config_guard", .de = "parachute" },
    .{ .en = "auto_gear", .de = "automatik" },
    .{ .en = "theme", .de = "thema" },
    .{ .en = "colors", .de = "farben" },
    .{ .en = "keys", .de = "tasten" },
    .{ .en = "language", .de = "sprache" },
};

pub const color_aliases = [_]Alias{
    .{ .en = "accent", .de = "akzent" },
    .{ .en = "key", .de = "tasten" },
    .{ .en = "warning", .de = "warnung" },
    .{ .en = "error", .de = "fehler" },
    .{ .en = "comment", .de = "kommentar" },
    .{ .en = "string", .de = "zeichenkette" },
    .{ .en = "number", .de = "zahl" },
    .{ .en = "keyword", .de = "befehlswort" },
    .{ .en = "property", .de = "schluessel" },
    .{ .en = "heading", .de = "ueberschrift" },
    .{ .en = "git_new", .de = "git_neu" },
    .{ .en = "git_changed", .de = "git_geaendert" },
    .{ .en = "git_removed", .de = "git_weg" },
    .{ .en = "cursorline", .de = "cursorzeile" },
    .{ .en = "selection", .de = "auswahl" },
};

/// German name of a setting or command → the English one. Everything else stays
/// as it is.
pub fn canonical(name: []const u8) []const u8 {
    for (setting_aliases) |a| {
        if (std.mem.eql(u8, name, a.de)) return a.en;
    }
    for (cmd_specs) |c| {
        if (std.mem.eql(u8, name, c.lua_de)) return c.lua_key;
    }
    return name;
}

/// All switches (true/false): Lua name and field in `Config`.
pub const BoolSetting = struct { lua: [:0]const u8, field: []const u8 };
pub const bool_settings = [_]BoolSetting{
    .{ .lua = "dotfiles", .field = "show_hidden" },
    .{ .lua = "tree_on_start", .field = "tree_on_start" },
    .{ .lua = "start_screen", .field = "start_screen" },
    .{ .lua = "icons", .field = "symbols" },
    .{ .lua = "indent_guides", .field = "indent_guides" },
    .{ .lua = "scrollbar", .field = "scrollbar" },
    .{ .lua = "minimap", .field = "minimap" },
    .{ .lua = "wrap", .field = "wrap" },
    .{ .lua = "animations", .field = "animations" },
    .{ .lua = "git_gutter", .field = "git_gutter" },
    .{ .lua = "trailing_spaces", .field = "show_trailing" },
    .{ .lua = "brackets", .field = "brackets" },
    .{ .lua = "esc_menu", .field = "esc_menu" },
    .{ .lua = "history", .field = "history" },
    .{ .lua = "config_guard", .field = "config_guard" },
    .{ .lua = "auto_gear", .field = "auto_gear" },
};

/// Settings for which iro remembers whether init.lua sets them itself.
pub const pin_names = blk: {
    var names: [bool_settings.len + 6][:0]const u8 = undefined;
    for (bool_settings, 0..) |b, i| names[i] = b.lua;
    names[bool_settings.len] = "theme";
    names[bool_settings.len + 1] = "tab_width";
    names[bool_settings.len + 2] = "spaces";
    names[bool_settings.len + 3] = "colors";
    names[bool_settings.len + 4] = "gear";
    names[bool_settings.len + 5] = "language";
    break :blk names;
};

/// iro's two gears. The keys are the same in both; only what is visible and
/// what runs in the background changes. Blade: just the text, no tree, no
/// minimap, no git. For configs. Forge: tree, minimap and git gutter. For
/// coding.
pub const Gear = enum { blade, forge };

pub const Config = struct {
    /// Language from the config. `null` means "auto": follow the system.
    language: ?Lang = null,
    /// The language everything currently appears in. Set by main.zig after
    /// every load (config or, for "auto", the system language).
    lang: Lang = .de,
    /// Gear at start. `null` means "auto": a single file starts in Blade,
    /// several files, a folder or nothing in Forge.
    gear: ?Gear = null,
    /// In Blade, automatically shift up to Forge when a project feature
    /// (file tree, second tab, split view, file search) is used.
    auto_gear: bool = true,
    /// `null`: the Lua config does not set `hints` (the state file applies then).
    hints_on: ?bool = null,
    tab_width: usize = 4,
    /// `null`: per-file detection stays active; `true`/`false`: force it.
    soft_tabs: ?bool = null,
    show_hidden: bool = true,
    tree_on_start: bool = false,
    start_screen: bool = true,
    /// Nerd Font icons in tree, tabs and status line.
    symbols: bool = true,
    /// Thin vertical lines in the indentation.
    indent_guides: bool = true,
    /// Narrow scrollbar on the right once the file is longer than the window.
    scrollbar: bool = true,
    /// Braille minimap on the right while there is enough room.
    minimap: bool = true,
    /// Wrap long lines at the window edge (Alt+W).
    wrap: bool = false,
    /// Smooth animations (tree slide, line pulse) with no idle load.
    animations: bool = true,
    /// Gutter next to the line numbers: what is new, changed or removed since the last
    /// commit.
    git_gutter: bool = true,
    /// Make trailing spaces visible.
    show_trailing: bool = true,
    /// Highlight the bracket at the cursor and its counterpart.
    brackets: bool = true,
    /// Esc in the text opens the main menu when there is nothing else to
    /// cancel.
    esc_menu: bool = true,
    /// Keep earlier versions of saved files (Alt+R brings them back).
    history: bool = true,
    /// Config Guard: check known system and dotfile configs before saving
    /// (fstab, sudoers, sshd_config, systemd units, shell scripts, JSON, Hyprland).
    config_guard: bool = true,
    theme: Theme = .{},
    /// Name of the selected theme (`theme`).
    theme_name: []const u8 = "terminal",
    slots: [cmd_count]BindingSlot = defaultSlots(),
    /// What init.lua sets itself (see `isPinned`, `keyPinned`).
    pinned: [pin_names.len]bool = @splat(false),
    pinned_keys: [cmd_count]bool = @splat(false),
    /// Which file `err_msg` comes from.
    err_src: []const u8 = "init.lua",
    err_msg: ?[]u8 = null,
    /// The same message in English.
    err_msg_en: ?[]u8 = null,
    /// True if the Lua file could not be executed at all (syntax or runtime error).
    fatal_lua: bool = false,

    pub fn deinit(self: *Config, gpa: Allocator) void {
        for (&self.slots) |*slot| {
            if (slot.bind) |b| b.deinit(gpa);
        }
        if (self.err_msg) |m| gpa.free(m);
        if (self.err_msg_en) |m| gpa.free(m);
        self.* = .{};
    }

    fn slotIndex(cmd: Cmd) usize {
        return @intFromEnum(cmd);
    }

    /// A command's key, labelled in the UI language.
    pub fn keyLabel(self: *const Config, cmd: Cmd) []const u8 {
        const idx = slotIndex(cmd);
        if (self.slots[idx].bind) |b| return b.labelIn(self.lang);
        const hint = cmd_specs[idx].palette_hint.in(self.lang);
        if (!self.slots[idx].overridden and hint.len > 0) return hint;
        return "";
    }

    /// Compact form for the hint bar (`Ctrl+S` → `^S`).
    pub fn shortKey(self: *const Config, arena: Allocator, cmd: Cmd) []const u8 {
        const lbl = self.keyLabel(cmd);
        if (lbl.len == 0) return "";
        for ([_][]const u8{ "Strg+Umschalt+", "Ctrl+Shift+" }) |pre| {
            if (std.mem.startsWith(u8, lbl, pre)) return std.fmt.allocPrint(arena, "^⇧{s}", .{lbl[pre.len..]}) catch lbl;
        }
        for ([_][]const u8{ "Strg+", "Ctrl+" }) |pre| {
            if (std.mem.startsWith(u8, lbl, pre)) return std.fmt.allocPrint(arena, "^{s}", .{lbl[pre.len..]}) catch lbl;
        }
        return lbl;
    }

    fn scopeActive(scope: Scope, in_tree: bool) bool {
        return switch (scope) {
            .global => true,
            .text => !in_tree,
            .tree => in_tree,
        };
    }

    fn isClaimed(self: *const Config, kb: KeyBind, in_tree: bool) bool {
        for (self.slots, 0..) |slot, i| {
            if (!scopeActive(cmd_specs[i].scope, in_tree)) continue;
            if (slot.bind) |b| {
                if (b.eqlKey(kb)) return true;
            }
        }
        return false;
    }

    /// Finds the command for the pressed key. Checks explicit bindings first (with
    /// Shift before those without), and only then default secondary keys.
    pub fn matchKey(self: *const Config, key: Key, in_tree: bool) ?Cmd {
        inline for (.{ true, false }) |want_shift| {
            for (self.slots, 0..) |slot, i| {
                if (!scopeActive(cmd_specs[i].scope, in_tree)) continue;
                if (slot.bind) |b| {
                    if (b.shift == want_shift and b.matches(key)) return cmd_specs[i].cmd;
                }
            }
        }
        inline for (.{ true, false }) |want_shift| {
            for (self.slots, 0..) |slot, i| {
                if (slot.overridden) continue;
                if (!scopeActive(cmd_specs[i].scope, in_tree)) continue;
                if (slot.fallback) |fb| {
                    if (fb.shift == want_shift and !self.isClaimed(fb, in_tree) and fb.matches(key)) {
                        return cmd_specs[i].cmd;
                    }
                }
            }
        }
        return null;
    }

    /// Records an error, in both languages at once.
    fn setErr(self: *Config, gpa: Allocator, comptime de: []const u8, comptime en: []const u8, args: anytype) void {
        if (self.err_msg != null) return; // keep the first, usually most helpful error
        self.err_msg = std.fmt.allocPrint(gpa, de, args) catch return;
        self.err_msg_en = std.fmt.allocPrint(gpa, en, args) catch null;
    }

    /// The error in the UI language.
    pub fn errText(self: *const Config) ?[]const u8 {
        if (self.lang == .en) if (self.err_msg_en) |m| return m;
        return self.err_msg;
    }

    fn setLuaErr(self: *Config, gpa: Allocator, L: *lua_State) void {
        var len: usize = 0;
        const ptr = lua_tolstring(L, -1, &len);
        const full = if (ptr) |p| p[0..len] else "";
        if (full.len == 0) return self.setErr(gpa, "unbekannter Lua-Fehler", "unknown Lua error", .{});
        // The leash's own message (see `stepHook`) exists in both languages.
        if (std.mem.indexOf(u8, full, too_long_de) != null) {
            return self.setErr(gpa, "abgebrochen: " ++ too_long_de, "aborted: the config takes too long (endless loop?)", .{});
        }
        for ([_][]const u8{ "init.lua:", "gewaehlt.lua:", "[string \"init.lua\"]:", "[string \"gewaehlt.lua\"]:" }) |prefix| {
            if (std.mem.startsWith(u8, full, prefix)) {
                return self.setErr(gpa, "Zeile {s}", "Line {s}", .{full[prefix.len..]});
            }
        }
        self.setErr(gpa, "{s}", "{s}", .{full});
    }

    /// Loads settings from Lua source. On errors it returns a safe config
    /// (defaults for faulty fields) and sets `err_msg`.
    pub fn loadFromSlice(gpa: Allocator, raw: []const u8) Allocator.Error!Config {
        return loadLayered(gpa, null, raw);
    }

    /// Two layers stacked: first `gewaehlt.lua` (what was chosen on the
    /// settings page), then `init.lua`. Whatever init.lua sets wins; whatever
    /// it leaves open comes from the lower layer. `fatal_lua` refers to
    /// init.lua only; a broken gewaehlt.lua is skipped and reported.
    pub fn loadLayered(gpa: Allocator, chosen: ?[]const u8, raw: ?[]const u8) Allocator.Error!Config {
        var cfg: Config = .{};
        errdefer cfg.deinit(gpa);
        if (chosen) |c| {
            try cfg.applyLayer(gpa, c, "@gewaehlt.lua", false);
            if (cfg.err_msg != null) cfg.err_src = "gewaehlt.lua";
            cfg.fatal_lua = false;
        }
        if (raw) |r| try cfg.applyLayer(gpa, r, "@init.lua", true);
        return cfg;
    }

    /// Runs one layer and takes over everything it sets. `pins = true`:
    /// remember what this layer sets (for the locks on the settings page).
    fn applyLayer(cfg: *Config, gpa: Allocator, raw: []const u8, chunk: [*:0]const u8, pins: bool) Allocator.Error!void {
        // The config runs on a leash: limited memory, limited steps, and only
        // the libraries a config needs.
        var mem: LuaMem = .{};
        const L = lua_newstate(luaAlloc, &mem) orelse return error.OutOfMemory;
        defer lua_close(L);
        openSafeLibs(L);
        lua_sethook(L, luaBudgetHook, LUA_MASKCOUNT, lua_step_chunk);

        if (luaL_loadbufferx(L, raw.ptr, raw.len, chunk, "t") != LUA_OK) {
            cfg.fatal_lua = true;
            cfg.setLuaErr(gpa, L);
            return;
        }
        if (lua_pcallk(L, 0, 0, 0, 0, null) != LUA_OK) {
            cfg.fatal_lua = true;
            cfg.setLuaErr(gpa, L);
            return;
        }
        // From here on everything is only read, and "raw": without metatables,
        // so no Lua code from the config can run during reading.
        lua_sethook(L, null, 0, 0);
        lua_settop(L, 0);
        _ = lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS); // sits at index 1
        // Map German names onto the English ones. Per layer, so a German init.lua
        // still wins against an English gewaehlt.lua.
        applyAliases(L);
        if (pins) cfg.recordPins(L);

        if (readGlobalBool(L, "hints")) |maybe| {
            if (maybe) |v| cfg.hints_on = v;
        } else |e| switch (e) {
            error.WrongType => cfg.setErr(gpa, "'hints' (hinweise) muss true oder false sein", "'hints' must be true or false", .{}),
        }
        if (readGlobalInt(L, "tab_width")) |maybe| {
            if (maybe) |n| {
                if (n >= 1 and n <= 16) {
                    cfg.tab_width = @intCast(n);
                } else {
                    cfg.setErr(gpa, "'tab_width' (tab_breite) muss zwischen 1 und 16 liegen", "'tab_width' must be between 1 and 16", .{});
                }
            }
        } else |e| switch (e) {
            error.WrongType => cfg.setErr(gpa, "'tab_width' (tab_breite) muss eine ganze Zahl sein", "'tab_width' must be a whole number", .{}),
        }
        if (readGlobalBool(L, "spaces")) |maybe| {
            if (maybe) |v| cfg.soft_tabs = v;
        } else |e| switch (e) {
            error.WrongType => cfg.setErr(gpa, "'spaces' (leerzeichen) muss true oder false sein", "'spaces' must be true or false", .{}),
        }
        cfg.readGear(gpa, L);
        cfg.readLanguage(gpa, L);
        inline for (bool_settings) |sw| {
            if (readGlobalBool(L, sw.lua.ptr)) |maybe| {
                if (maybe) |v| @field(cfg, sw.field) = v;
            } else |e| switch (e) {
                error.WrongType => cfg.setErr(gpa, "'{s}' muss true oder false sein", "'{s}' must be true or false", .{sw.lua}),
            }
        }

        // First the theme, then individual colours on top.
        cfg.readPreset(gpa, L);
        try cfg.readKeyTable(gpa, L);
        cfg.readColorTable(gpa, L);
    }

    /// What does this layer set itself? Only check whether something is there.
    fn recordPins(cfg: *Config, L: *lua_State) void {
        for (pin_names, 0..) |name, i| {
            cfg.pinned[i] = rawGlobal(L, name.ptr) != LUA_TNIL;
            luaPop(L, 1);
        }
        cfg.pinned_keys = @splat(false);
        if (rawGlobal(L, "keys") == LUA_TTABLE) {
            for (cmd_specs, 0..) |spec, i| {
                cfg.pinned_keys[i] = rawField(L, spec.lua_key.ptr) != LUA_TNIL;
                luaPop(L, 1);
            }
        }
        luaPop(L, 1);
    }

    /// Does init.lua set this itself? Then a click on the settings page has no
    /// effect.
    pub fn isPinned(self: *const Config, name: []const u8) bool {
        const want = canonical(name);
        for (pin_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, want)) return self.pinned[i];
        }
        return false;
    }

    pub fn keyPinned(self: *const Config, cmd: Cmd) bool {
        return self.pinned_keys[slotIndex(cmd)];
    }

    /// Switch (true/false) by Lua name, for the settings page.
    pub fn boolPtr(self: *Config, lua: []const u8) ?*bool {
        const want = canonical(lua);
        inline for (bool_settings) |sw| {
            if (std.mem.eql(u8, sw.lua, want)) return &@field(self, sw.field);
        }
        return null;
    }

    fn readKeyTable(self: *Config, gpa: Allocator, L: *lua_State) Allocator.Error!void {
        const tp = rawGlobal(L, "keys");
        defer luaPop(L, 1);
        if (tp == LUA_TNIL) return;
        if (tp != LUA_TTABLE) {
            self.setErr(gpa, "'keys' (tasten) muss eine Tabelle sein", "'keys' must be a table", .{});
            return;
        }
        for (cmd_specs, 0..) |spec, i| {
            const ft = rawField(L, spec.lua_key.ptr);
            defer luaPop(L, 1);
            if (ft == LUA_TNIL) continue;
            if (ft != LUA_TSTRING) {
                self.setErr(gpa, "Taste für '{s}' muss Text sein", "The key for '{s}' must be text", .{spec.lua_key});
                continue;
            }
            var len: usize = 0;
            const ptr = lua_tolstring(L, -1, &len) orelse continue;
            const val = ptr[0..len];
            const parsed = KeyBind.parse(gpa, val) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidKey => {
                    self.setErr(gpa, "Unbekannte Taste '{s}' für '{s}'", "Unknown key '{s}' for '{s}'", .{ val, spec.lua_key });
                    continue;
                },
            };
            if (self.slots[i].bind) |old| old.deinit(gpa);
            self.slots[i].bind = parsed;
            self.slots[i].overridden = true;
        }
        // Whoever binds a key gets it: a default that happens to sit on the
        // same key makes way.
        for (self.slots, 0..) |mine, i| {
            if (!mine.overridden) continue;
            const kb = mine.bind orelse continue;
            for (&self.slots, 0..) |*other, j| {
                if (i == j or other.overridden) continue;
                const ob = other.bind orelse continue;
                if (!ob.eqlKey(kb)) continue;
                const a = cmd_specs[i].scope;
                const b = cmd_specs[j].scope;
                if (a == .global or b == .global or a == b) other.bind = null;
            }
        }
    }

    /// `language = "auto"`, `"en"` or `"de"` (also `"english"`, `"deutsch"`).
    fn readLanguage(self: *Config, gpa: Allocator, L: *lua_State) void {
        const tp = rawGlobal(L, "language");
        defer luaPop(L, 1);
        if (tp == LUA_TNIL) return;
        const bad = "'language' muss \"auto\", \"en\" oder \"de\" sein";
        const bad_en = "'language' must be \"auto\", \"en\" or \"de\"";
        if (tp != LUA_TSTRING) return self.setErr(gpa, bad, bad_en, .{});
        var len: usize = 0;
        const ptr = lua_tolstring(L, -1, &len) orelse return;
        const name = std.mem.trim(u8, ptr[0..len], " \t");
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, "auto")) {
            self.language = null;
        } else if (eq(name, "en") or eq(name, "english") or eq(name, "englisch")) {
            self.language = .en;
        } else if (eq(name, "de") or eq(name, "deutsch") or eq(name, "german")) {
            self.language = .de;
        } else self.setErr(gpa, bad, bad_en, .{});
    }

    /// `gear = "auto"`, `"blade"` or `"forge"`.
    fn readGear(self: *Config, gpa: Allocator, L: *lua_State) void {
        const tp = rawGlobal(L, "gear");
        defer luaPop(L, 1);
        if (tp == LUA_TNIL) return;
        const bad = "'gear' muss \"auto\", \"blade\" oder \"forge\" sein";
        const bad_en = "'gear' must be \"auto\", \"blade\" or \"forge\"";
        if (tp != LUA_TSTRING) return self.setErr(gpa, bad, bad_en, .{});
        var len: usize = 0;
        const ptr = lua_tolstring(L, -1, &len) orelse return;
        const name = std.mem.trim(u8, ptr[0..len], " \t");
        if (std.ascii.eqlIgnoreCase(name, "auto")) {
            self.gear = null;
        } else if (std.ascii.eqlIgnoreCase(name, "blade")) {
            self.gear = .blade;
        } else if (std.ascii.eqlIgnoreCase(name, "forge")) {
            self.gear = .forge;
        } else self.setErr(gpa, bad, bad_en, .{});
    }

    fn readPreset(self: *Config, gpa: Allocator, L: *lua_State) void {
        const tp = rawGlobal(L, "theme");
        defer luaPop(L, 1);
        if (tp == LUA_TNIL) return;
        if (tp != LUA_TSTRING) return self.setErr(gpa, "'theme' (thema) muss ein Name in Anführungszeichen sein", "'theme' must be a name in quotes", .{});
        var len: usize = 0;
        const ptr = lua_tolstring(L, -1, &len) orelse return;
        const name = std.mem.trim(u8, ptr[0..len], " \t");
        for (presets) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, name)) {
                self.theme = p.theme;
                self.theme_name = p.name;
                return;
            }
        }
        self.setErr(gpa, "Unbekanntes Thema '{s}' (es gibt: " ++ preset_list ++ ")", "Unknown theme '{s}' (available: " ++ preset_list ++ ")", .{name});
    }

    fn readColorTable(self: *Config, gpa: Allocator, L: *lua_State) void {
        const tp = rawGlobal(L, "colors");
        defer luaPop(L, 1);
        if (tp == LUA_TNIL) return;
        if (tp != LUA_TTABLE) {
            self.setErr(gpa, "'colors' (farben) muss eine Tabelle sein", "'colors' must be a table", .{});
            return;
        }
        const Field = struct { name: [:0]const u8, ptr: *ColorSpec };
        const fields = [_]Field{
            .{ .name = "text", .ptr = &self.theme.text },
            .{ .name = "accent", .ptr = &self.theme.akzent },
            .{ .name = "key", .ptr = &self.theme.tasten },
            .{ .name = "warning", .ptr = &self.theme.warnung },
            .{ .name = "error", .ptr = &self.theme.fehler },
            .{ .name = "comment", .ptr = &self.theme.kommentar },
            .{ .name = "string", .ptr = &self.theme.zeichenkette },
            .{ .name = "number", .ptr = &self.theme.zahl },
            .{ .name = "keyword", .ptr = &self.theme.befehlswort },
            .{ .name = "property", .ptr = &self.theme.schluessel },
            .{ .name = "heading", .ptr = &self.theme.ueberschrift },
            .{ .name = "git_new", .ptr = &self.theme.git_neu },
            .{ .name = "git_changed", .ptr = &self.theme.git_geaendert },
            .{ .name = "git_removed", .ptr = &self.theme.git_weg },
        };
        for (fields) |f| {
            const ft = rawField(L, f.name.ptr);
            defer luaPop(L, 1);
            if (ft == LUA_TNIL) continue;
            if (parseLuaColor(L, ft)) |col| {
                f.ptr.* = col;
            } else {
                self.setErr(gpa, "Ungültige Farbe für '{s}' (erlaubt: 0..255 oder \"#RRGGBB\")", "Invalid color for '{s}' (allowed: 0..255 or \"#RRGGBB\")", .{f.name});
            }
        }
        const AutoField = struct { name: [:0]const u8, ptr: *AutoColor };
        for ([_]AutoField{
            .{ .name = "cursorline", .ptr = &self.theme.cursorzeile },
            .{ .name = "selection", .ptr = &self.theme.auswahl },
        }) |f| {
            const ft = rawField(L, f.name.ptr);
            defer luaPop(L, 1);
            if (ft == LUA_TNIL) continue;
            if (ft == LUA_TSTRING) {
                var len: usize = 0;
                const ptr = lua_tolstring(L, -1, &len) orelse continue;
                const word = std.mem.trim(u8, ptr[0..len], " \t");
                if (std.mem.eql(u8, word, "auto")) {
                    f.ptr.* = .auto;
                    continue;
                }
                if (std.mem.eql(u8, word, "off") or std.mem.eql(u8, word, "aus")) {
                    f.ptr.* = .off;
                    continue;
                }
            }
            if (parseLuaColor(L, ft)) |col| {
                f.ptr.* = .{ .color = col };
            } else {
                self.setErr(gpa, "Ungültige Farbe für '{s}' (erlaubt: \"auto\", \"aus\", 0..255 oder \"#RRGGBB\")", "Invalid color for '{s}' (allowed: \"auto\", \"off\", 0..255 or \"#RRGGBB\")", .{f.name});
            }
        }
    }
};

fn parseLuaColor(L: *lua_State, ft: c_int) ?ColorSpec {
    if (ft == LUA_TNUMBER and lua_isinteger(L, -1) != 0) {
        const n = lua_tointegerx(L, -1, null);
        if (n >= 0 and n <= 255) return .{ .index = @intCast(n) };
        return null;
    }
    if (ft == LUA_TSTRING) {
        var len: usize = 0;
        const ptr = lua_tolstring(L, -1, &len) orelse return null;
        const s = std.mem.trim(u8, ptr[0..len], " \t");
        if (std.mem.eql(u8, s, "standard")) return .default;
        if (s.len == 7 and s[0] == '#') {
            const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
            const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
            const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
            return .{ .rgb = .{ r, g, b } };
        }
        return null;
    }
    return null;
}

fn readGlobalBool(L: *lua_State, name: [*:0]const u8) error{WrongType}!?bool {
    const tp = rawGlobal(L, name);
    defer luaPop(L, 1);
    if (tp == LUA_TNIL) return null;
    if (tp != LUA_TBOOLEAN) return error.WrongType;
    return lua_toboolean(L, -1) != 0;
}

fn readGlobalInt(L: *lua_State, name: [*:0]const u8) error{WrongType}!?lua_Integer {
    const tp = rawGlobal(L, name);
    defer luaPop(L, 1);
    if (tp == LUA_TNIL) return null;
    if (tp != LUA_TNUMBER or lua_isinteger(L, -1) == 0) return error.WrongType;
    return lua_tointegerx(L, -1, null);
}

/// Template for a fresh `~/.config/iro/init.lua` if none exists yet, in the UI
/// language. The names are English in both.
pub fn defaultInitLua(l: Lang) []const u8 {
    return if (l == .en) default_init_lua_en else default_init_lua_de;
}

pub const default_init_lua_de =
    \\-- Einstellungen für iro.
    \\-- Speichern übernimmt sie sofort. Das meiste geht auch zum Anklicken:
    \\-- Esc → Einstellungen. Die Klicks landen in gewaehlt.lua, was in DIESER
    \\-- Datei steht, gewinnt. Die Namen sind englisch, die alten deutschen
    \\-- (tab_breite, thema, tasten …) versteht iro weiterhin.
    \\-- Zeilen mit -- davor zeigen nur den Standard. Erst ohne -- gilt der Wert,
    \\-- und die Einstellungsseite sperrt ihn dann (Schloss).
    \\
    \\-- Sprache der Oberfläche: "de", "en" oder "auto" (wie das System, LANG).
    \\-- language = "auto"
    \\
    \\-- Gear beim Start. "blade": nur der Text, schnell, für Configs.
    \\-- "forge": Baum, Minimap und Git-Spalte, zum Programmieren.
    \\-- "auto": eine Datei startet in Blade, mehrere oder ein Ordner in Forge. Alt+G wechselt jederzeit.
    \\-- gear = "auto"
    \\-- auto_gear = true      -- in Blade bei Baum, 2. Tab, geteilter Ansicht oder Dateisuche zu Forge hochschalten
    \\
    \\-- Hinweisleiste über der Statuszeile (weglassen = Wahl von F1 merken)
    \\-- hints = true
    \\
    \\-- Tab-Breite und Einrückung
    \\-- tab_width = 4
    \\-- spaces = true    -- true = Leerzeichen, false = echte Tabs (weglassen = pro Datei erkennen)
    \\
    \\-- Dateibaum beim Start gleich öffnen (nur in Forge) & Punkt-Dateien anzeigen
    \\-- tree_on_start = false
    \\-- dotfiles = true
    \\
    \\-- Startseite mit Logo, wenn iro ohne Datei startet
    \\-- start_screen = true
    \\
    \\-- Frühere Versionen jeder gespeicherten Datei aufheben (Alt+R holt sie zurück).
    \\-- Dateien, die nur du lesen darfst, und Schlüssel bekommen nie Kopien.
    \\-- history = true
    \\
    \\-- Config Guard: bekannte Configs (fstab, sudoers, sshd, systemd, Shell, JSON, Hyprland)
    \\-- beim Speichern prüfen und bei Fehlern warnen.
    \\-- config_guard = true
    \\
    \\-- Optik. Alles einzeln abschaltbar (false).
    \\-- icons = true           -- Nerd-Font-Symbole in Baum, Tabs und Statuszeile
    \\-- indent_guides = true   -- feine Linien in der Einrückung
    \\-- scrollbar = true       -- schmaler Balken rechts bei langen Dateien
    \\-- minimap = true         -- Braille-Minimap rechts bei langen Dateien (in Forge)
    \\-- wrap = false           -- lange Zeilen am Fensterrand umbrechen (Alt+W)
    \\-- animations = true      -- weiches Baum-Gleiten und Zeilen-Puls
    \\-- git_gutter = true      -- neben den Zeilennummern: neu, geändert, weg (in Forge)
    \\-- trailing_spaces = true -- überflüssige Leerzeichen am Zeilenende zeigen
    \\-- brackets = true        -- Klammer am Cursor und ihr Gegenstück hervorheben
    \\-- esc_menu = true        -- Esc holt das Hauptmenü (wenn nichts anderes aufzuheben ist)
    \\
    \\-- Fertiger Farbsatz. "terminal" nimmt die Farben deines Terminals und folgt
    \\-- damit dem Wallpaper. Sonst: "mohawk", "nord", "gruvbox", "catppuccin", "tokyonacht",
    \\-- "dracula", "rosepine", "kanagawa", "everforest", "onedark", "solarized", "monokai",
    \\-- "ayu", "synthwave" und die iro-eigenen Retro-Sätze "phosphor" (grün) und "bernstein" (amber).
    \\-- Am bequemsten durchprobieren: Esc → Einstellungen → Farbsatz, mit ←/→.
    \\-- theme = "terminal"
    \\
    \\-- Eigene Tastenkürzel. "Strg+S" und "Ctrl+S" gehen beide, "" schaltet ein Kürzel ab.
    \\-- Alle Namen stehen auf der Einstellungsseite, die Hilfe (Alt+H) zeigt die Belegung.
    \\keys = {
    \\    -- save = "Strg+S",
    \\    -- save_as = "F12",
    \\    -- open = "Strg+O",
    \\    -- tree = "Strg+B",
    \\    -- complete = "Strg+Leer",
    \\    -- wrap = "Alt+W",
    \\    -- split = "Alt+V",
    \\    -- minimap = "Alt+M",
    \\    -- gear = "Alt+G",
    \\    -- palette = "Strg+P",
    \\    -- open_config = "",           -- ohne Taste, z. B. "Strg+,"
    \\    -- reload_config = "",         -- ohne Taste, z. B. "F5"
    \\    -- replace = "Strg+R",
    \\    -- comment = "Strg+K",
    \\    -- duplicate_line = "Strg+D",
    \\    -- line_up = "Alt+Hoch",
    \\    -- line_down = "Alt+Runter",
    \\    -- help = "Alt+H",
    \\    -- menu = "F10",
    \\    -- about = "F9",
    \\}
    \\
    \\-- Farben: 0..255 (Terminal-Palette, folgt deinem Wallpaper) oder "#RRGGBB"
    \\colors = {
    \\    -- text = "standard",     -- normaler Text ("standard" = Schriftfarbe des Terminals)
    \\    -- accent = 6,
    \\    -- key = 3,               -- Tasten in Hinweisleiste und Menü
    \\    -- warning = 3,
    \\    -- error = 1,
    \\    -- comment = 8,
    \\    -- string = 11,
    \\    -- number = 3,
    \\    -- keyword = 5,
    \\    -- property = 7,          -- Schlüssel in Configs (links vom =)
    \\    -- heading = 6,
    \\    -- git_new = 2,
    \\    -- git_changed = 4,
    \\    -- git_removed = 1,
    \\    -- cursorline = "auto",   -- "auto" rechnet einen Hauch heller als der Hintergrund, "off" schaltet ab
    \\    -- selection = "auto",    -- "auto" mischt Akzent und Hintergrund, "off" kehrt die Farben um
    \\}
;

pub const default_init_lua_en =
    \\-- Settings for iro.
    \\-- Saving applies them right away. Most of this can also be clicked:
    \\-- Esc → Settings. The clicks go to gewaehlt.lua, and what's in THIS
    \\-- file wins.
    \\-- Lines starting with -- only show the default. Remove the -- and the
    \\-- value applies, and the settings page locks it (padlock).
    \\
    \\-- Interface language: "en", "de" or "auto" (like the system, LANG).
    \\-- language = "auto"
    \\
    \\-- Gear at startup. "blade": just the text, fast, for configs.
    \\-- "forge": tree, minimap and git gutter, for coding.
    \\-- "auto": a single file starts in Blade, several or a folder in Forge. Alt+G switches anytime.
    \\-- gear = "auto"
    \\-- auto_gear = true      -- in Blade, shift up to Forge on tree, 2nd tab, split view or file search
    \\
    \\-- Hint bar above the status bar (leave out = remember the F1 choice)
    \\-- hints = true
    \\
    \\-- Tab width and indentation
    \\-- tab_width = 4
    \\-- spaces = true    -- true = spaces, false = real tabs (leave out = detect per file)
    \\
    \\-- Open the file tree right at startup (Forge only) & show dotfiles
    \\-- tree_on_start = false
    \\-- dotfiles = true
    \\
    \\-- Start screen with the logo when iro starts without a file
    \\-- start_screen = true
    \\
    \\-- Keep earlier versions of every file you save (Alt+R brings them back).
    \\-- Files only you may read, and keys, never get copies.
    \\-- history = true
    \\
    \\-- Config Guard: check known configs (fstab, sudoers, sshd, systemd, shell, JSON, Hyprland)
    \\-- on save and warn before writing broken syntax.
    \\-- config_guard = true
    \\
    \\-- Looks. Each one can be switched off (false).
    \\-- icons = true           -- Nerd Font icons in the tree, tabs and status bar
    \\-- indent_guides = true   -- thin lines inside the indentation
    \\-- scrollbar = true       -- slim bar on the right for long files
    \\-- minimap = true         -- Braille minimap on the right for long files (in Forge)
    \\-- wrap = false           -- wrap long lines at the window edge (Alt+W)
    \\-- animations = true      -- smooth tree slide and line pulse
    \\-- git_gutter = true      -- next to the line numbers: new, changed, gone (in Forge)
    \\-- trailing_spaces = true -- show stray spaces at the end of lines
    \\-- brackets = true        -- highlight the bracket at the cursor and its partner
    \\-- esc_menu = true        -- Esc opens the main menu (when there's nothing else to cancel)
    \\
    \\-- Ready-made color scheme. "terminal" uses your terminal's colors and so
    \\-- follows your wallpaper. Others: "mohawk", "nord", "gruvbox", "catppuccin", "tokyonacht",
    \\-- "dracula", "rosepine", "kanagawa", "everforest", "onedark", "solarized", "monokai",
    \\-- "ayu", "synthwave" and iro's own retro schemes "phosphor" (green) and "bernstein" (amber).
    \\-- Easiest to try: Esc → Settings → Color scheme, with ←/→.
    \\-- theme = "terminal"
    \\
    \\-- Your own shortcuts. "Ctrl+S" and "Strg+S" both work, "" switches a shortcut off.
    \\-- Every name is on the settings page, the help (Alt+H) shows the bindings.
    \\keys = {
    \\    -- save = "Ctrl+S",
    \\    -- save_as = "F12",
    \\    -- open = "Ctrl+O",
    \\    -- tree = "Ctrl+B",
    \\    -- complete = "Ctrl+Space",
    \\    -- wrap = "Alt+W",
    \\    -- split = "Alt+V",
    \\    -- minimap = "Alt+M",
    \\    -- gear = "Alt+G",
    \\    -- palette = "Ctrl+P",
    \\    -- open_config = "",           -- no key by default, e.g. "Ctrl+,"
    \\    -- reload_config = "",         -- no key by default, e.g. "F5"
    \\    -- replace = "Ctrl+R",
    \\    -- comment = "Ctrl+K",
    \\    -- duplicate_line = "Ctrl+D",
    \\    -- line_up = "Alt+Up",
    \\    -- line_down = "Alt+Down",
    \\    -- help = "Alt+H",
    \\    -- menu = "F10",
    \\    -- about = "F9",
    \\}
    \\
    \\-- Colors: 0..255 (terminal palette, follows your wallpaper) or "#RRGGBB"
    \\colors = {
    \\    -- text = "standard",     -- normal text ("standard" = the terminal's text color)
    \\    -- accent = 6,
    \\    -- key = 3,               -- keys in the hint bar and menu
    \\    -- warning = 3,
    \\    -- error = 1,
    \\    -- comment = 8,
    \\    -- string = 11,
    \\    -- number = 3,
    \\    -- keyword = 5,
    \\    -- property = 7,          -- keys in configs (left of the =)
    \\    -- heading = 6,
    \\    -- git_new = 2,
    \\    -- git_changed = 4,
    \\    -- git_removed = 1,
    \\    -- cursorline = "auto",   -- "auto" goes a touch lighter than the background, "off" switches it off
    \\    -- selection = "auto",    -- "auto" mixes accent and background, "off" inverts the colors
    \\}
;

// ───────────── Lua 5.4 C API ─────────────

const lua_State = opaque {};
const lua_Integer = c_longlong;
const lua_KContext = isize;

const LUA_OK: c_int = 0;
const LUA_MULTRET: c_int = -1;
const LUA_TNIL: c_int = 0;
const LUA_TBOOLEAN: c_int = 1;
const LUA_TNUMBER: c_int = 3;
const LUA_TSTRING: c_int = 4;
const LUA_TTABLE: c_int = 5;

const LUA_REGISTRYINDEX: c_int = -1000000 - 1000;
const LUA_RIDX_GLOBALS: lua_Integer = 2;
const LUA_MASKCOUNT: c_int = 1 << 3;

const lua_CFunction = *const fn (L: *lua_State) callconv(.c) c_int;
const lua_Hook = *const fn (L: *lua_State, ar: ?*anyopaque) callconv(.c) void;
const lua_Alloc = *const fn (ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque;

extern "c" fn lua_newstate(f: lua_Alloc, ud: ?*anyopaque) ?*lua_State;
extern "c" fn lua_close(L: *lua_State) void;
extern "c" fn luaL_requiref(L: *lua_State, modname: [*:0]const u8, openf: lua_CFunction, glb: c_int) void;
extern "c" fn luaopen_base(L: *lua_State) c_int;
extern "c" fn luaopen_string(L: *lua_State) c_int;
extern "c" fn luaopen_table(L: *lua_State) c_int;
extern "c" fn luaopen_math(L: *lua_State) c_int;
extern "c" fn luaopen_utf8(L: *lua_State) c_int;
extern "c" fn luaopen_os(L: *lua_State) c_int;
extern "c" fn luaL_loadbufferx(L: *lua_State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
extern "c" fn lua_callk(L: *lua_State, nargs: c_int, nresults: c_int, ctx: lua_KContext, k: ?*const anyopaque) void;
extern "c" fn lua_pcallk(L: *lua_State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: lua_KContext, k: ?*const anyopaque) c_int;
extern "c" fn lua_sethook(L: *lua_State, func: ?lua_Hook, mask: c_int, count: c_int) void;
extern "c" fn luaL_error(L: *lua_State, fmt: [*:0]const u8, ...) c_int;
extern "c" fn lua_getglobal(L: *lua_State, name: [*:0]const u8) c_int;
extern "c" fn lua_setglobal(L: *lua_State, name: [*:0]const u8) void;
extern "c" fn lua_getfield(L: *lua_State, idx: c_int, k: [*:0]const u8) c_int;
extern "c" fn lua_setfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void;
extern "c" fn lua_pushnil(L: *lua_State) void;
extern "c" fn lua_pushinteger(L: *lua_State, n: lua_Integer) void;
extern "c" fn lua_pushstring(L: *lua_State, s: [*:0]const u8) ?[*:0]const u8;
extern "c" fn lua_pushvalue(L: *lua_State, idx: c_int) void;
extern "c" fn lua_pushcclosure(L: *lua_State, f: lua_CFunction, n: c_int) void;
extern "c" fn lua_rawget(L: *lua_State, idx: c_int) c_int;
extern "c" fn lua_rawset(L: *lua_State, idx: c_int) void;
extern "c" fn lua_gettop(L: *lua_State) c_int;
extern "c" fn lua_rawgeti(L: *lua_State, idx: c_int, n: lua_Integer) c_int;
extern "c" fn lua_type(L: *lua_State, idx: c_int) c_int;
extern "c" fn lua_tocfunction(L: *lua_State, idx: c_int) ?lua_CFunction;
extern "c" fn lua_toboolean(L: *lua_State, idx: c_int) c_int;
extern "c" fn lua_isinteger(L: *lua_State, idx: c_int) c_int;
extern "c" fn lua_tointegerx(L: *lua_State, idx: c_int, isnum: ?*c_int) lua_Integer;
extern "c" fn lua_tolstring(L: *lua_State, idx: c_int, len: ?*usize) ?[*]const u8;
extern "c" fn lua_settop(L: *lua_State, idx: c_int) void;
extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) void;

fn luaPop(L: *lua_State, n: c_int) void {
    lua_settop(L, -n - 1);
}

fn luaUpvalueIndex(i: c_int) c_int {
    return LUA_REGISTRYINDEX - i;
}

/// A config gets no more memory than this. A thousand times enough for any
/// honest `init.lua`, and it stops one that has lost its way.
const lua_mem_limit = 32 * 1024 * 1024;
/// After this many steps it's over (endless loop or runaway pattern). The VM
/// hook fires every `lua_step_chunk` instructions; pattern matching in C
/// charges its backtracking bound against the same budget.
const lua_step_chunk = 100_000;
const too_long_de = "die Config rechnet zu lange (Endlosschleife?)";
const lua_max_steps: u64 = 200 * lua_step_chunk; // 20 million steps

const LuaMem = struct {
    used: usize = 0,
    steps: u64 = 0,
};

fn luaAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const mem: *LuaMem = @ptrCast(@alignCast(ud.?));
    // For a new allocation, `osize` holds the object type, not a size.
    const old: usize = if (ptr == null) 0 else osize;
    if (nsize == 0) {
        free(ptr);
        mem.used -|= old;
        return null;
    }
    if (nsize > old and mem.used + (nsize - old) > lua_mem_limit) return null;
    const new = realloc(ptr, nsize) orelse return null;
    mem.used = mem.used - @min(mem.used, old) + nsize;
    return new;
}

fn chargeLuaSteps(L: *lua_State, n: u64) void {
    // The counter lives in the same block as the memory accounting.
    var ud: ?*anyopaque = null;
    _ = lua_getallocf(L, &ud);
    const mem: *LuaMem = @ptrCast(@alignCast(ud.?));
    mem.steps +|= n;
    if (mem.steps >= lua_max_steps) {
        _ = luaL_error(L, "abgebrochen: " ++ too_long_de);
    }
}

fn luaBudgetHook(L: *lua_State, _: ?*anyopaque) callconv(.c) void {
    chargeLuaSteps(L, lua_step_chunk);
}

extern "c" fn lua_getallocf(L: *lua_State, ud: *?*anyopaque) lua_Alloc;

/// Upper bound on the backtracking steps Lua's pattern matcher can take for a
/// subject of `s_len` bytes. Lua patterns have neither group quantifiers nor
/// alternation, so only `*`, `+`, `-` (up to `s_len + 1` branches each) and `?`
/// (up to 2 branches each) can multiply the work.
fn patternWork(s_len: usize, pat: []const u8, plain: bool) u64 {
    const n: u64 = s_len +| 1;
    const m: u64 = @max(pat.len, 1);
    if (plain) return n *| m;

    const anchored = pat.len > 0 and pat[0] == '^';
    var i: usize = if (anchored) 1 else 0;
    var work: u64 = if (anchored) m else n *| m;

    while (i < pat.len) {
        switch (pat[i]) {
            '%' => {
                if (i + 1 >= pat.len) break;
                switch (pat[i + 1]) {
                    'b' => {
                        work *|= n;
                        i = @min(i + 4, pat.len);
                        continue;
                    },
                    'f' => {
                        i += 2;
                        if (i < pat.len and pat[i] == '[') i = skipCharSet(pat, i);
                        continue;
                    },
                    else => i += 2,
                }
            },
            '[' => i = skipCharSet(pat, i),
            '(', ')' => {
                i += 1;
                continue;
            },
            else => i += 1,
        }
        if (i < pat.len) switch (pat[i]) {
            '*', '+', '-' => {
                work *|= n;
                i += 1;
            },
            '?' => {
                work *|= 2;
                i += 1;
            },
            else => {},
        };
    }
    return work;
}

fn skipCharSet(pat: []const u8, start: usize) usize {
    var i = start + 1;
    if (i < pat.len and pat[i] == '^') i += 1;
    // A `]` right at the start of the set is part of the set, not the end.
    if (i < pat.len and pat[i] == ']') i += 1;
    while (i < pat.len and pat[i] != ']') {
        if (pat[i] == '%' and i + 1 < pat.len) i += 2 else i += 1;
    }
    return if (i < pat.len) i + 1 else pat.len;
}

fn checkPatternArgs(L: *lua_State, is_find: bool) u64 {
    const top = lua_gettop(L);
    if (top < 2) return 1;
    const t1 = lua_type(L, 1);
    const t2 = lua_type(L, 2);
    if ((t1 != LUA_TSTRING and t1 != LUA_TNUMBER) or
        (t2 != LUA_TSTRING and t2 != LUA_TNUMBER)) return 1;
    var s_len: usize = 0;
    _ = lua_tolstring(L, 1, &s_len) orelse return 1;
    var p_len: usize = 0;
    const p_ptr = lua_tolstring(L, 2, &p_len) orelse return 1;
    const plain = is_find and top >= 4 and lua_toboolean(L, 4) != 0;
    const work = patternWork(s_len, p_ptr[0..p_len], plain);
    chargeLuaSteps(L, work);
    return work;
}

fn safeStrFind(L: *lua_State) callconv(.c) c_int {
    _ = checkPatternArgs(L, true);
    const orig = lua_tocfunction(L, luaUpvalueIndex(1)).?;
    return orig(L);
}

fn safeStrPattern(L: *lua_State) callconv(.c) c_int {
    _ = checkPatternArgs(L, false);
    const orig = lua_tocfunction(L, luaUpvalueIndex(1)).?;
    return orig(L);
}

fn safeGmatchIter(L: *lua_State) callconv(.c) c_int {
    const work: u64 = @intCast(lua_tointegerx(L, luaUpvalueIndex(2), null));
    chargeLuaSteps(L, work);
    lua_settop(L, 0);
    lua_pushvalue(L, luaUpvalueIndex(1));
    lua_callk(L, 0, LUA_MULTRET, 0, null);
    return lua_gettop(L);
}

fn safeStrGmatch(L: *lua_State) callconv(.c) c_int {
    const work = checkPatternArgs(L, false);
    const orig = lua_tocfunction(L, luaUpvalueIndex(1)).?;
    const nret = orig(L);
    if (nret != 1) return nret;
    lua_pushinteger(L, @intCast(@min(work, std.math.maxInt(lua_Integer))));
    lua_pushcclosure(L, safeGmatchIter, 2);
    return 1;
}

fn wrapStringFn(L: *lua_State, name: [*:0]const u8, wrapper: lua_CFunction) void {
    _ = lua_getfield(L, -1, name);
    lua_pushcclosure(L, wrapper, 1);
    lua_setfield(L, -2, name);
}

/// Opens only what a config needs: base functions, strings, tables, math and a
/// few harmless queries (environment variables, time). Starting programs,
/// touching files or loading code is not possible. `print` is gone too: it
/// would write straight into the terminal, past everything that cleans text up.
fn openSafeLibs(L: *lua_State) void {
    const Lib = struct { name: [*:0]const u8, open: lua_CFunction };
    const libs = [_]Lib{
        .{ .name = "_G", .open = luaopen_base },
        .{ .name = "string", .open = luaopen_string },
        .{ .name = "table", .open = luaopen_table },
        .{ .name = "math", .open = luaopen_math },
        .{ .name = "utf8", .open = luaopen_utf8 },
        .{ .name = "os", .open = luaopen_os },
    };
    for (libs) |lib| {
        luaL_requiref(L, lib.name, lib.open, 1);
        luaPop(L, 1);
    }
    for ([_][*:0]const u8{ "dofile", "loadfile", "load", "require", "collectgarbage", "print" }) |name| {
        lua_pushnil(L);
        lua_setglobal(L, name);
    }
    // Turns functions into bytecode. Useless without `load`, so it goes as well.
    // Pattern matching runs in C, where the VM instruction hook cannot see it,
    // so it is wrapped to count toward the step budget.
    _ = lua_getglobal(L, "string");
    lua_pushnil(L);
    lua_setfield(L, -2, "dump");
    wrapStringFn(L, "find", safeStrFind);
    wrapStringFn(L, "match", safeStrPattern);
    wrapStringFn(L, "gsub", safeStrPattern);
    wrapStringFn(L, "gmatch", safeStrGmatch);
    luaPop(L, 1);
    _ = lua_getglobal(L, "os");
    for ([_][*:0]const u8{ "execute", "remove", "rename", "exit", "tmpname", "setlocale" }) |name| {
        lua_pushnil(L);
        lua_setfield(L, -2, name);
    }
    luaPop(L, 1);
}

/// Reads a global variable while ignoring metatables. The globals table sits at
/// index 1 during reading. If the table at index `t` only has the German name,
/// the English one gets the same value. If both are set, the English one wins.
fn moveAlias(L: *lua_State, t: c_int, en: [*:0]const u8, de: [*:0]const u8) void {
    _ = lua_pushstring(L, en);
    const has_en = lua_rawget(L, t) != LUA_TNIL;
    luaPop(L, 1);
    if (has_en) return;
    _ = lua_pushstring(L, en);
    _ = lua_pushstring(L, de);
    if (lua_rawget(L, t) == LUA_TNIL) return luaPop(L, 2);
    lua_rawset(L, t); // en = value of de
}

/// Map all German names onto the English ones: top level, in `keys` and in `colors`.
fn applyAliases(L: *lua_State) void {
    for (setting_aliases) |a| moveAlias(L, 1, a.en, a.de);
    if (rawGlobal(L, "keys") == LUA_TTABLE) {
        const t = lua_gettop(L);
        for (cmd_specs) |c| moveAlias(L, t, c.lua_key, c.lua_de);
    }
    luaPop(L, 1);
    if (rawGlobal(L, "colors") == LUA_TTABLE) {
        const t = lua_gettop(L);
        for (color_aliases) |a| moveAlias(L, t, a.en, a.de);
    }
    luaPop(L, 1);
}

fn rawGlobal(L: *lua_State, name: [*:0]const u8) c_int {
    _ = lua_pushstring(L, name);
    return lua_rawget(L, 1);
}

/// Reads a field of the table on top of the stack, without metatables.
fn rawField(L: *lua_State, name: [*:0]const u8) c_int {
    _ = lua_pushstring(L, name);
    return lua_rawget(L, -2);
}

// ───────────── Tests ─────────────

test "default config and key bind parser" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(?bool, null), cfg.hints_on);
    try std.testing.expectEqual(@as(usize, 4), cfg.tab_width);
    try std.testing.expectEqualStrings("Strg+S", cfg.keyLabel(.save));
}

test "shortKey with arena without leak" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg: Config = .{};
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("^S", cfg.shortKey(arena, .save));
    try std.testing.expectEqualStrings("F1", cfg.shortKey(arena, .hints));
}

test "key parser understands German and English spellings" {
    const gpa = std.testing.allocator;

    const k1 = (try KeyBind.parse(gpa, "Strg+S")).?;
    defer k1.deinit(gpa);
    try std.testing.expectEqual(@as(u21, 's'), k1.codepoint);
    try std.testing.expect(k1.ctrl and !k1.alt and !k1.shift);
    try std.testing.expectEqualStrings("Strg+S", k1.label);

    const k2 = (try KeyBind.parse(gpa, "Ctrl+Shift+s")).?;
    defer k2.deinit(gpa);
    try std.testing.expectEqual(@as(u21, 's'), k2.codepoint);
    try std.testing.expect(k2.ctrl and k2.shift);
    try std.testing.expectEqualStrings("Strg+Umschalt+S", k2.label);

    const k3 = (try KeyBind.parse(gpa, "Alt+Z")).?;
    defer k3.deinit(gpa);
    try std.testing.expect(k3.matches(.{ .codepoint = 'z', .mods = .{ .alt = true } }));

    const k4 = (try KeyBind.parse(gpa, "Strg+Bild ab")).?;
    defer k4.deinit(gpa);
    try std.testing.expectEqual(Key.page_down, k4.codepoint);
    try std.testing.expectEqualStrings("Strg+Bild ab", k4.label);

    const k5 = (try KeyBind.parse(gpa, "F12")).?;
    defer k5.deinit(gpa);
    try std.testing.expectEqual(Key.f12, k5.codepoint);

    try std.testing.expect((try KeyBind.parse(gpa, "")) == null);
    try std.testing.expectError(error.InvalidKey, KeyBind.parse(gpa, "Quatsch+X"));
}

test "Lua config loads options, keys and colours" {
    const gpa = std.testing.allocator;
    const src =
        \\hinweise = false
        \\tab_breite = 2
        \\leerzeichen = false
        \\punkt_dateien = false
        \\baum_beim_start = true
        \\startseite = false
        \\tasten = {
        \\    baum = "Strg+D",
        \\    speichern = "",
        \\}
        \\farben = {
        \\    akzent = "#00E5FF",
        \\    tasten = 13,
        \\}
    ;
    var cfg = try Config.loadFromSlice(gpa, src);
    defer cfg.deinit(gpa);

    try std.testing.expect(cfg.err_msg == null);
    try std.testing.expect(!cfg.fatal_lua);
    try std.testing.expectEqual(@as(?bool, false), cfg.hints_on);
    try std.testing.expectEqual(@as(usize, 2), cfg.tab_width);
    try std.testing.expectEqual(@as(?bool, false), cfg.soft_tabs);
    try std.testing.expect(!cfg.show_hidden);
    try std.testing.expect(cfg.tree_on_start);
    try std.testing.expect(!cfg.start_screen);

    try std.testing.expectEqualStrings("Strg+D", cfg.keyLabel(.tree));
    try std.testing.expectEqualStrings("", cfg.keyLabel(.save));
    try std.testing.expectEqual(Cmd.tree, cfg.matchKey(.{ .codepoint = 'd', .mods = .{ .ctrl = true } }, false).?);
    try std.testing.expect(cfg.matchKey(.{ .codepoint = 'b', .mods = .{ .ctrl = true } }, false) == null);
    try std.testing.expect(cfg.matchKey(.{ .codepoint = 's', .mods = .{ .ctrl = true } }, false) == null);

    // Ctrl+D is "duplicate line" by default; the user's binding wins, and the
    // default no longer shows up in any bar.
    try std.testing.expectEqualStrings("", cfg.keyLabel(.duplicate_line));

    try std.testing.expectEqual(ColorSpec{ .rgb = .{ 0x00, 0xE5, 0xFF } }, cfg.theme.akzent);
    try std.testing.expectEqual(ColorSpec{ .index = 13 }, cfg.theme.tasten);
    try std.testing.expectEqual(ColorSpec{ .index = 5 }, cfg.theme.befehlswort);
}

test "broken Lua does not crash and reports errors" {
    const gpa = std.testing.allocator;
    var cfg = try Config.loadFromSlice(gpa, "tasten = {{{ kaputt");
    defer cfg.deinit(gpa);

    try std.testing.expect(cfg.fatal_lua);
    try std.testing.expect(cfg.err_msg != null);
    try std.testing.expect(std.mem.startsWith(u8, cfg.err_msg.?, "Zeile 1:"));
    try std.testing.expect(std.mem.startsWith(u8, cfg.err_msg_en.?, "Line 1:"));
    try std.testing.expectEqualStrings("Strg+S", cfg.keyLabel(.save));
}

test "invalid single values keep safe defaults and report errors" {
    const gpa = std.testing.allocator;
    var cfg = try Config.loadFromSlice(gpa,
        \\tab_breite = 99
        \\tasten = { baum = "Unbekannt+Z" }
        \\farben = { akzent = "kein-hex" }
    );
    defer cfg.deinit(gpa);

    try std.testing.expect(!cfg.fatal_lua);
    try std.testing.expect(cfg.err_msg != null);
    try std.testing.expectEqual(@as(usize, 4), cfg.tab_width);
    try std.testing.expectEqualStrings("Strg+B", cfg.keyLabel(.tree));
    try std.testing.expectEqual(ColorSpec{ .index = 6 }, cfg.theme.akzent);
    try std.testing.expect(cfg.start_screen);
}

test "gear: auto, blade, forge and nonsense" {
    const gpa = std.testing.allocator;
    var leer = try Config.loadFromSlice(gpa, "");
    defer leer.deinit(gpa);
    try std.testing.expectEqual(@as(?Gear, null), leer.gear);
    var blade = try Config.loadFromSlice(gpa, "gear = \" Blade \"");
    defer blade.deinit(gpa);
    try std.testing.expectEqual(@as(?Gear, .blade), blade.gear);
    try std.testing.expect(blade.err_msg == null);
    var forge = try Config.loadFromSlice(gpa, "gear = \"forge\"");
    defer forge.deinit(gpa);
    try std.testing.expectEqual(@as(?Gear, .forge), forge.gear);
    var auto = try Config.loadFromSlice(gpa, "gear = \"auto\"");
    defer auto.deinit(gpa);
    try std.testing.expectEqual(@as(?Gear, null), auto.gear);
    // Nonsense: a message, and it stays "auto".
    var quatsch = try Config.loadFromSlice(gpa, "gear = \"turbo\"");
    defer quatsch.deinit(gpa);
    try std.testing.expect(quatsch.err_msg != null);
    try std.testing.expectEqual(@as(?Gear, null), quatsch.gear);
    var zahl = try Config.loadFromSlice(gpa, "gear = 3");
    defer zahl.deinit(gpa);
    try std.testing.expect(zahl.err_msg != null);
    // Alt+G is free and belongs to the gear switch.
    try std.testing.expectEqualStrings("Alt+G", leer.keyLabel(.gear));
    try std.testing.expect(leer.auto_gear);
    var no_auto = try Config.loadFromSlice(gpa, "automatik = false");
    defer no_auto.deinit(gpa);
    try std.testing.expect(!no_auto.auto_gear);
}

test "English names, German understood, init.lua wins even in German" {
    const gpa = std.testing.allocator;
    // Lower layer English (how iro writes gewaehlt.lua now), upper layer German
    // (like older init.lua files): German must win.
    var cfg = try Config.loadLayered(gpa,
        \\tab_width = 8
        \\theme = "nord"
        \\keys = { save = "Strg+E" }
    ,
        \\tab_breite = 2
        \\thema = "gruvbox"
        \\tasten = { speichern = "Strg+W" }
        \\farben = { akzent = "#112233" }
        \\minimap = false
    );
    defer cfg.deinit(gpa);
    try std.testing.expect(cfg.err_msg == null);
    try std.testing.expectEqual(@as(usize, 2), cfg.tab_width);
    try std.testing.expectEqualStrings("gruvbox", cfg.theme_name);
    try std.testing.expectEqualStrings("Strg+W", cfg.keyLabel(.save));
    try std.testing.expectEqual(ColorSpec{ .rgb = .{ 0x11, 0x22, 0x33 } }, cfg.theme.akzent);
    try std.testing.expect(cfg.isPinned("theme") and cfg.isPinned("thema") and cfg.isPinned("tab_width"));
    try std.testing.expect(cfg.keyPinned(.save));

    // Both in one file: the English name applies.
    var both = try Config.loadFromSlice(gpa, "tab_width = 3\ntab_breite = 5\nicons = false\ncolors = { accent = 4 }");
    defer both.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), both.tab_width);
    try std.testing.expect(!both.symbols);
    try std.testing.expectEqual(ColorSpec{ .index = 4 }, both.theme.akzent);
    try std.testing.expectEqualStrings("theme", canonical("thema"));
    try std.testing.expectEqualStrings("save", canonical("speichern"));
    try std.testing.expectEqualStrings("wrap", canonical("wrap"));
}

test "language and English key names" {
    const gpa = std.testing.allocator;
    var cfg = try Config.loadFromSlice(gpa, "language = \"English\"\ntasten = { speichern = \"Strg+Umschalt+Entf\" }");
    defer cfg.deinit(gpa);
    try std.testing.expect(cfg.err_msg == null);
    try std.testing.expectEqual(@as(?Lang, .en), cfg.language);
    cfg.lang = .en;
    try std.testing.expectEqualStrings("Ctrl+Shift+Del", cfg.keyLabel(.save));
    try std.testing.expectEqualStrings("Ctrl+PgDn", cfg.keyLabel(.next_tab));
    try std.testing.expectEqualStrings("Ctrl+O, Tab", cfg.keyLabel(.open_path));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("^Q", cfg.shortKey(arena.allocator(), .quit));
    cfg.lang = .de;
    try std.testing.expectEqualStrings("Strg+Umschalt+Entf", cfg.keyLabel(.save));
    var quatsch = try Config.loadFromSlice(gpa, "language = \"klingonisch\"");
    defer quatsch.deinit(gpa);
    try std.testing.expect(quatsch.err_msg != null);
}

test "config on a leash: endless loop, metatables, blocked functions" {
    const gpa = std.testing.allocator;
    {
        var cfg = try Config.loadFromSlice(gpa, "while true do end");
        defer cfg.deinit(gpa);
        try std.testing.expect(cfg.fatal_lua);
        try std.testing.expect(std.mem.indexOf(u8, cfg.err_msg.?, "zu lange") != null);
    }
    {
        // Used to be a hard abort: an error in a metatable while reading.
        var cfg = try Config.loadFromSlice(gpa,
            \\tasten = setmetatable({}, { __index = function() error("boom") end })
            \\farben = setmetatable({}, { __index = function() error("boom") end })
            \\setmetatable(_G, { __index = function() error("boom") end })
        );
        defer cfg.deinit(gpa);
        try std.testing.expect(!cfg.fatal_lua);
        try std.testing.expectEqualStrings("Strg+S", cfg.keyLabel(.save));
    }
    {
        var cfg = try Config.loadFromSlice(gpa, "local s = ('x'):rep(2^31)");
        defer cfg.deinit(gpa);
        try std.testing.expect(cfg.fatal_lua);
    }
    inline for (.{
        "os.execute('true')",
        "io.open('/etc/passwd')",
        "require('os')",
        "dofile('/etc/passwd')",
        "load('return 1')",
        "print('\x1b[2J')",
        "string.dump(function() end)",
    }) |src| {
        var cfg = try Config.loadFromSlice(gpa, src);
        defer cfg.deinit(gpa);
        try std.testing.expect(cfg.fatal_lua);
    }
    // Pathological pattern matching in C counts toward the step budget too.
    inline for (.{
        "('a'):rep(100):find('a*a*a*a*a*a*a*a*b')",
        "('a'):rep(100):match('a*a*a*a*a*a*a*a*b')",
        "('a'):rep(100):gsub('a*a*a*a*a*a*a*a*b', '')",
        "for _ in ('a'):rep(100):gmatch('a*a*a*a*a*a*a*a*b') do end",
        "local f = ('a'):rep(1500):gmatch('a*b'); for _ = 1, 10 do f() end",
    }) |src| {
        var cfg = try Config.loadFromSlice(gpa, src);
        defer cfg.deinit(gpa);
        try std.testing.expect(cfg.fatal_lua);
        try std.testing.expect(std.mem.indexOf(u8, cfg.err_msg.?, "zu lange") != null);
    }
    {
        // Harmless things stay allowed, including normal pattern matching and plain search.
        var cfg = try Config.loadFromSlice(gpa,
            \\local heim = os.getenv("HOME") or ""
            \\local s = ("  mohawk  "):match("^%s*(.-)%s*$")
            \\if s:find("a*a*a*a*a*a*a*a*b", 1, true) == nil and s:gsub("o", "o") == "mohawk" then
            \\    theme = s
            \\end
            \\local n = 0
            \\for w in ("eins zwei"):gmatch("%S+") do n = n + #w end
            \\tab_breite = math.max(2, string.len("ab"), n - 6)
        );
        defer cfg.deinit(gpa);
        try std.testing.expect(cfg.err_msg == null);
        try std.testing.expectEqual(@as(usize, 2), cfg.tab_width);
        try std.testing.expectEqualStrings("mohawk", cfg.theme_name);
    }
}

test "theme, switches and automatic colours" {
    const gpa = std.testing.allocator;
    var cfg = try Config.loadFromSlice(gpa,
        \\thema = "Nord"
        \\symbole = false
        \\git_spalte = false
        \\farben = { zahl = 3, cursorzeile = "aus", auswahl = "#223344" }
    );
    defer cfg.deinit(gpa);
    try std.testing.expect(cfg.err_msg == null);
    try std.testing.expect(!cfg.symbols and !cfg.git_gutter and cfg.scrollbar);
    try std.testing.expectEqual(ColorSpec{ .rgb = .{ 0x88, 0xC0, 0xD0 } }, cfg.theme.akzent);
    // An individual colour beats the theme.
    try std.testing.expectEqual(ColorSpec{ .index = 3 }, cfg.theme.zahl);
    try std.testing.expectEqual(AutoColor.off, cfg.theme.cursorzeile);
    try std.testing.expectEqual(AutoColor{ .color = .{ .rgb = .{ 0x22, 0x33, 0x44 } } }, cfg.theme.auswahl);

    var bad = try Config.loadFromSlice(gpa, "thema = \"gibtsnicht\"");
    defer bad.deinit(gpa);
    try std.testing.expect(bad.err_msg != null);
    try std.testing.expectEqual(ColorSpec{ .index = 6 }, bad.theme.akzent);

    // The bundled template must itself be error-free.
    for ([_]Lang{ .de, .en }) |l| {
        var tpl = try Config.loadFromSlice(gpa, defaultInitLua(l));
        defer tpl.deinit(gpa);
        try std.testing.expect(tpl.err_msg == null);
        try std.testing.expect(tpl.minimap and tpl.symbols and tpl.tab_width == 4);
        // Merely creating init.lua must not lock any setting ... (The empty
        // `colors = {}` table counts as set, but no settings item shows colors.)
        for (tpl.pinned, pin_names) |p, name| {
            if (!std.mem.eql(u8, name, "colors")) try std.testing.expect(!p);
        }
        for (tpl.pinned_keys) |p| try std.testing.expect(!p);
        // ... nor overrule what was clicked on the settings page before.
        var clicked = try Config.loadLayered(gpa, "minimap = false\ntab_width = 2\n", defaultInitLua(l));
        defer clicked.deinit(gpa);
        try std.testing.expect(!clicked.minimap and clicked.tab_width == 2);
    }

    var rice = try Config.loadFromSlice(gpa,
        \\minimap = false
        \\animationen = false
        \\zeilenumbruch = true
    );
    defer rice.deinit(gpa);
    try std.testing.expect(rice.err_msg == null);
    try std.testing.expect(!rice.minimap and !rice.animations and rice.wrap);
}
