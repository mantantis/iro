// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Generates the text of the built-in help page (`Alt+H`).
//!
//! The text is built fresh from the current configuration every time it opens,
//! so it always shows the key bindings actually in effect.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const Cmd = config.Cmd;
const Text = @import("lang.zig").Text;

pub fn generate(arena: Allocator, cfg: *const config.Config) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const l = cfg.lang;
    const none: Text = .{ .de = "", .en = "" };
    const Line = struct {
        /// Command whose current key goes first ...
        cmd: ?Cmd = null,
        /// ... or a fixed key.
        key: Text = none,
        say: Text,
    };
    const Section = struct { head: Text, intro: Text = none, lines: []const Line };
    const sections = [_]Section{
        .{ .head = .{ .de = "Das Wichtigste zuerst", .en = "The essentials" }, .intro = .{
            .de = "iro hat keine Modi. Was du tippst, steht da. Du kannst nichts kaputt machen:\nRückgängig geht immer, und gespeichert wird erst, wenn du es sagst.",
            .en = "iro has no modes. What you type is what you get. You can't break anything:\nUndo always works, and nothing is saved until you say so.",
        }, .lines = &.{
            .{ .cmd = .save, .say = .{ .de = "Speichern.", .en = "Save." } },
            .{ .cmd = .quit, .say = .{ .de = "Beenden. Bei ungespeicherten Änderungen fragt iro erst nach.", .en = "Quit. With unsaved changes, iro asks first." } },
            .{ .cmd = .undo, .say = .{ .de = "Rückgängig. Nimmt den letzten Schritt zurück, beliebig oft.", .en = "Undo. Takes back the last step, as often as you like." } },
            .{ .cmd = .redo, .say = .{ .de = "Wiederholen, falls du einmal zu oft rückgängig gemacht hast.", .en = "Redo, in case you undid one step too many." } },
            .{ .cmd = .palette, .say = .{ .de = "Befehlspalette: alle Befehle zum Suchen. Wenn dir eine Taste nicht einfällt, steht sie hier.", .en = "Command palette: every command, searchable. If you forget a key, it's listed here." } },
            .{ .cmd = .help, .say = .{ .de = "Diese Hilfe.", .en = "This help." } },
            .{ .key = .{ .de = "Esc", .en = "Esc" }, .say = .{ .de = "Hauptmenü mit den wichtigsten Befehlen, wenn gerade nichts aufzuheben ist. Buchstabe, Pfeile oder Maus wählen.", .en = "Main menu with the key commands, when there is nothing else to cancel. Pick with a letter, the arrows or the mouse." } },
            .{ .cmd = .menu, .say = .{ .de = "Hauptmenü, auch wenn Esc gerade etwas anderes zu tun hat.", .en = "Main menu, even when Esc has something else to do." } },
            .{ .cmd = .about, .say = .{ .de = "Über iro: Version, Autor und ein kleiner Effekt.", .en = "About iro: version, author and a little effect." } },
        } },
        .{ .head = .{ .de = "Zwei Gears: Blade und Forge", .en = "Two gears: Blade and Forge" }, .intro = .{
            .de = "Die Tasten sind in beiden Gears gleich. Es ändert sich nur, was du siehst und was im Hintergrund läuft.\nEine Datei startet in Blade, ein Ordner oder gar nichts in Forge.",
            .en = "The keys are the same in both gears. Only what you see and what runs in the background changes.\nA file starts in Blade, a folder or nothing at all starts in Forge.",
        }, .lines = &.{
            .{ .cmd = .gear, .say = .{ .de = "Gear wechseln. Unten links in der Statuszeile steht, in welchem du gerade bist.", .en = "Switch gear. The bottom left of the status bar shows which one you're in." } },
            .{ .key = .{ .de = "Blade", .en = "Blade" }, .say = .{ .de = "Get in. Cut. Get out. Nur der Text. Kein Baum, keine Minimap, kein Git im Hintergrund. Für Configs.", .en = "Get in. Cut. Get out. Just the text. No tree, no minimap, no git in the background. For configs." } },
            .{ .key = .{ .de = "Forge", .en = "Forge" }, .say = .{ .de = "Heat up. Hammer. Ship it. Dateibaum, Minimap und Git-Spalte. Zum Programmieren.", .en = "Heat up. Hammer. Ship it. File tree, minimap and git gutter. For coding." } },
            .{ .key = .{ .de = "gear = …", .en = "gear = …" }, .say = .{ .de = "Gear beim Start in der init.lua festlegen: \"auto\", \"blade\" oder \"forge\". Auch über Esc → Einstellungen.", .en = "Set the startup gear in init.lua: \"auto\", \"blade\" or \"forge\". Also via Esc → Settings." } },
        } },
        .{ .head = .{ .de = "Dateien", .en = "Files" }, .lines = &.{
            .{ .cmd = .open, .say = .{ .de = "Datei suchen und öffnen. Ein paar Buchstaben des Namens reichen.", .en = "Find and open a file. A few letters of its name are enough." } },
            .{ .cmd = .save_as, .say = .{ .de = "Unter neuem Namen speichern. Gibt es die Datei schon, fragt iro nach.", .en = "Save under a new name. If the file already exists, iro asks." } },
            .{ .cmd = .history, .say = .{ .de = "Frühere Versionen dieser Datei, die letzten 20. Enter holt eine zurück in den Text, Strg+Z macht das rückgängig.", .en = "Earlier versions of this file, the last 20. Enter brings one back into the text, Ctrl+Z undoes that." } },
            .{ .cmd = .jump_dir, .say = .{ .de = "In einen Ordner springen, den du oft benutzt (zoxide).", .en = "Jump to a folder you use often (zoxide)." } },
            .{ .cmd = .tree, .say = .{ .de = "Dateibaum links zeigen. Nochmal drücken blendet ihn aus, Esc führt zurück in den Text.", .en = "Show the file tree on the left. Press again to hide it, Esc takes you back to the text." } },
            .{ .key = .{ .de = "im Baum", .en = "in the tree" }, .say = .{ .de = "N neue Datei, O neuer Ordner, F2 umbenennen, Entf in den Papierkorb (nichts wird endgültig gelöscht).", .en = "N new file, O new folder, F2 rename, Del moves to the trash (nothing is deleted for good)." } },
        } },
        .{ .head = .{ .de = "Tabs", .en = "Tabs" }, .intro = .{ .de = "Jede offene Datei ist ein Tab. Die Leiste oben erscheint ab der zweiten Datei.", .en = "Every open file is a tab. The bar at the top appears from the second file on." }, .lines = &.{
            .{ .cmd = .new_tab, .say = .{ .de = "Neuer, leerer Tab.", .en = "New, empty tab." } },
            .{ .cmd = .close_tab, .say = .{ .de = "Tab schließen.", .en = "Close the tab." } },
            .{ .cmd = .next_tab, .say = .{ .de = "Zum nächsten Tab.", .en = "To the next tab." } },
            .{ .cmd = .prev_tab, .say = .{ .de = "Zum vorherigen Tab.", .en = "To the previous tab." } },
            .{ .key = .{ .de = "Alt+1 … 9", .en = "Alt+1 … 9" }, .say = .{ .de = "Direkt zum ersten bis neunten Tab.", .en = "Straight to the first to ninth tab." } },
        } },
        .{ .head = .{ .de = "Suchen und Ersetzen", .en = "Find and replace" }, .lines = &.{
            .{ .cmd = .search, .say = .{ .de = "Suchen. iro springt schon beim Tippen zum ersten Treffer und unterstreicht alle anderen.", .en = "Find. iro jumps to the first match while you type and underlines all the others." } },
            .{ .cmd = .search_next, .say = .{ .de = "Zum nächsten Treffer. Esc nimmt die Unterstreichung wieder weg.", .en = "To the next match. Esc removes the underlining again." } },
            .{ .cmd = .replace, .say = .{ .de = "Suchen und ersetzen. Beispiel: überall „kitty“ durch „ghostty“ tauschen. iro fragt bei jeder Stelle: J ja, N nein, A alle übrigen.", .en = "Find and replace. Example: swap \"kitty\" for \"ghostty\" everywhere. iro asks at every match: Y yes, N no, A all the rest." } },
            .{ .cmd = .goto_line, .say = .{ .de = "Zu einer Zeilennummer springen, etwa aus einer Fehlermeldung.", .en = "Jump to a line number, say from an error message." } },
        } },
        .{ .head = .{ .de = "Zeilen bearbeiten", .en = "Editing lines" }, .intro = .{ .de = "Diese vier sparen beim Basteln an Configs die meiste Tipparbeit.", .en = "These four save the most typing when you tinker with configs." }, .lines = &.{
            .{ .cmd = .comment, .say = .{ .de = "Kommentar ein/aus. Schaltet eine Zeile (oder alle markierten) ab, ohne sie zu löschen. Nochmal drücken schaltet sie wieder an.", .en = "Toggle comment. Switches a line (or all selected ones) off without deleting it. Press again to switch it back on." } },
            .{ .cmd = .duplicate_line, .say = .{ .de = "Zeile verdoppeln. Gut für ähnliche Einträge oder als Sicherheitskopie vor einer Änderung.", .en = "Duplicate the line. Handy for similar entries or as a backup before a change." } },
            .{ .cmd = .line_up, .say = .{ .de = "Zeile eine Zeile nach oben schieben.", .en = "Move the line up by one." } },
            .{ .cmd = .line_down, .say = .{ .de = "Zeile eine Zeile nach unten schieben.", .en = "Move the line down by one." } },
            .{ .key = .{ .de = "Tab", .en = "Tab" }, .say = .{ .de = "Einrücken. Sind mehrere Zeilen markiert, rücken alle zusammen ein.", .en = "Indent. With several lines selected, they all move together." } },
            .{ .key = .{ .de = "Shift+Tab", .en = "Shift+Tab" }, .say = .{ .de = "Ausrücken, also eine Stufe Einrückung wegnehmen.", .en = "Outdent, i.e. remove one level of indentation." } },
            .{ .cmd = .complete, .say = .{ .de = "Angefangenes Wort aus dem Text oder den Sprach-Befehlen ergänzen.", .en = "Complete a started word from the text or the language's keywords." } },
        } },
        .{ .head = .{ .de = "Markieren, Kopieren, Einfügen", .en = "Select, copy, paste" }, .lines = &.{
            .{ .key = .{ .de = "Shift+Pfeile", .en = "Shift+Arrows" }, .say = .{ .de = "Markieren. Mit der Maus: ziehen, Doppelklick nimmt das Wort, Dreifachklick die Zeile.", .en = "Select. With the mouse: drag, double-click takes the word, triple-click the line." } },
            .{ .cmd = .select_all, .say = .{ .de = "Alles markieren.", .en = "Select all." } },
            .{ .cmd = .copy, .say = .{ .de = "Kopieren. Ohne Markierung: die ganze Zeile.", .en = "Copy. Without a selection: the whole line." } },
            .{ .cmd = .cut, .say = .{ .de = "Ausschneiden. Ohne Markierung: die ganze Zeile.", .en = "Cut. Without a selection: the whole line." } },
            .{ .cmd = .paste, .say = .{ .de = "Einfügen. Markierter Text wird dabei ersetzt.", .en = "Paste. Selected text gets replaced." } },
            .{ .key = .{ .de = "Strg+Pfeile", .en = "Ctrl+Arrows" }, .say = .{ .de = "Wortweise springen. Strg+Rücktaste und Strg+Entf löschen wortweise.", .en = "Jump word by word. Ctrl+Backspace and Ctrl+Del delete word by word." } },
        } },
        .{ .head = .{ .de = "Was die Zeichen im Text bedeuten", .en = "What the marks in the text mean" }, .intro = .{ .de = "iro zeigt ein paar Dinge an, die man sonst übersieht.", .en = "iro shows a few things you would otherwise miss." }, .lines = &.{
            .{ .key = .{ .de = "▎ am Rand", .en = "▎ at the edge" }, .say = .{ .de = "Diese Zeile ist seit dem letzten Git-Commit neu oder geändert.", .en = "This line is new or changed since the last git commit." } },
            .{ .key = .{ .de = "▔ oder ▁", .en = "▔ or ▁" }, .say = .{ .de = "Hier wurde seit dem letzten Commit etwas gelöscht.", .en = "Something was deleted here since the last commit." } },
            .{ .key = .{ .de = "· am Ende", .en = "· at the end" }, .say = .{ .de = "Überflüssige Leerzeichen am Zeilenende.", .en = "Stray spaces at the end of the line." } },
            .{ .key = .{ .de = "· im Text", .en = "· in the text" }, .say = .{ .de = "Ein Steuerzeichen, das eigentlich nicht in eine Textdatei gehört.", .en = "A control character that doesn't really belong in a text file." } },
            .{ .key = .{ .de = "▪ in Rot", .en = "▪ in red" }, .say = .{ .de = "Ein unsichtbares Zeichen, das Text anders aussehen lässt, als er ist. In fremdem Code misstrauisch werden.", .en = "An invisible character that makes text look different from what it is. Be suspicious in other people's code." } },
            .{ .key = .{ .de = "▏ Linien", .en = "▏ lines" }, .say = .{ .de = "Einrückhilfen: zeigen, wie tief eine Zeile eingerückt ist.", .en = "Indent guides: show how deep a line is indented." } },
            .{ .key = .{ .de = "● am Namen", .en = "● by the name" }, .say = .{ .de = "Die Datei hat ungespeicherte Änderungen.", .en = "The file has unsaved changes." } },
            .{ .key = .{ .de = "⠿ rechts", .en = "⠿ on the right" }, .say = .{ .de = "Minimap: zeigt die ganze Datei im Überblick. Anklicken oder ziehen springt dorthin.", .en = "Minimap: the whole file at a glance. Click or drag to jump there." } },
            .{ .key = .{ .de = "▐ rechts", .en = "▐ on the right" }, .say = .{ .de = "Rollbalken: zeigt, wo in der Datei du bist. Anklicken springt dorthin.", .en = "Scrollbar: shows where you are in the file. Click to jump there." } },
        } },
        .{ .head = .{ .de = "Einstellungen und Aussehen", .en = "Settings and looks" }, .intro = .{ .de = "Alles steht in einer Datei, ~/.config/iro/init.lua. Jede Zeile dort ist erklärt.", .en = "Everything lives in one file, ~/.config/iro/init.lua. Every line in it is explained." }, .lines = &.{
            .{ .cmd = .settings, .say = .{ .de = "Einstellungsseite zum Anklicken: Aussehen, Bedienung und alle Tasten (Enter, dann die neue Taste drücken). Auch über Esc → Einstellungen.", .en = "A settings page to click through: looks, behavior and every key (Enter, then press the new key). Also via Esc → Settings." } },
            .{ .cmd = .open_config, .say = .{ .de = "Die init.lua von Hand bearbeiten. Speichern übernimmt sie sofort, und was dort steht, gewinnt gegen die Klicks.", .en = "Edit init.lua by hand. Saving applies it right away, and what's in there beats the clicks." } },
            .{ .cmd = .reload_config, .say = .{ .de = "Einstellungen neu laden, falls du sie außerhalb von iro geändert hast.", .en = "Reload the settings in case you changed them outside of iro." } },
            .{ .cmd = .wrap, .say = .{ .de = "Lange Zeilen am rechten Fensterrand umbrechen (mit ↪ in der Nummeranspalte).", .en = "Wrap long lines at the right window edge (marked ↪ in the line numbers)." } },
            .{ .cmd = .split, .say = .{ .de = "Fenster vertikal teilen (zweite Ansicht rechts; Alt+Links/Rechts wechselt die Seite).", .en = "Split the window vertically (second view on the right; Alt+Left/Right switches sides)." } },
            .{ .cmd = .minimap, .say = .{ .de = "Minimap rechts aus- und einschalten.", .en = "Turn the minimap on the right on and off." } },
            .{ .cmd = .hints, .say = .{ .de = "Hinweisleiste unten aus- und einschalten.", .en = "Turn the hint bar at the bottom on and off." } },
            .{ .key = .{ .de = "language = …", .en = "language = …" }, .say = .{ .de = "Sprache: \"de\", \"en\" oder \"auto\" (wie das System). Auch über Esc → Einstellungen → Sprache · Language.", .en = "Language: \"en\", \"de\" or \"auto\" (like the system). Also via Esc → Settings → Language · Sprache." } },
            .{ .key = .{ .de = "theme = …", .en = "theme = …" }, .say = .{
                .de = "Fertige Farbsätze: terminal (folgt dem Wallpaper), mohawk, nord, gruvbox, catppuccin, tokyonacht, dracula, rosepine, kanagawa, everforest, onedark, solarized, monokai, ayu, synthwave und die Retro-Sätze phosphor und bernstein. Am schnellsten durchprobiert über Esc → Einstellungen → Farbsatz.",
                .en = "Ready-made color schemes: terminal (follows your wallpaper), mohawk, nord, gruvbox, catppuccin, tokyonacht, dracula, rosepine, kanagawa, everforest, onedark, solarized, monokai, ayu, synthwave and the retro schemes phosphor and bernstein. Quickest to try via Esc → Settings → Color scheme.",
            } },
            .{ .key = .{ .de = "keys = …", .en = "keys = …" }, .say = .{ .de = "Jede Taste auf dieser Seite lässt sich umbelegen. Diese Hilfe zeigt immer die aktuelle Belegung. Die alten deutschen Namen (tasten, thema, tab_breite …) gehen weiterhin.", .en = "Every key on this page can be rebound. This help always shows the current bindings." } },
        } },
        .{ .head = .{ .de = "Wenn etwas schiefgeht", .en = "When something goes wrong" }, .lines = &.{
            .{ .key = .{ .de = "Absturz", .en = "Crash" }, .say = .{ .de = "iro sichert spätestens zwei Sekunden nach jeder Änderung. Beim nächsten Start bietet es den ungespeicherten Stand an, auch für Text ohne Dateinamen.", .en = "iro backs up within two seconds of every change. On the next start it offers the unsaved state, even for text without a file name." } },
            .{ .key = .{ .de = "Fremde Änderung", .en = "Outside change" }, .say = .{ .de = "Ändert ein anderes Programm die Datei, lädt iro sie neu, sobald du zurückkommst, solange du nichts Ungespeichertes hast. Sonst warnt es, und beim Speichern kannst du überschreiben oder laden: Dein Stand bleibt per Strg+Z erreichbar.", .en = "If another program changes the file, iro reloads it when you come back, as long as nothing is unsaved. Otherwise it warns you, and on saving you can overwrite or load: your text stays one Ctrl+Z away." } },
            .{ .key = .{ .de = "Doppelt offen", .en = "Open twice" }, .say = .{ .de = "Hat schon ein anderes iro die Datei offen, öffnet das zweite sie nur zum Lesen und nennt die PID des ersten. So überschreibt keins die Arbeit des anderen.", .en = "If another iro already has the file open, the second one opens it read-only and names the first one's PID. That way neither overwrites the other's work." } },
            .{ .key = .{ .de = "Fehler in init.lua", .en = "Error in init.lua" }, .say = .{ .de = "iro startet trotzdem und nennt unten die Zeile mit dem Fehler.", .en = "iro starts anyway and names the line with the error at the bottom." } },
        } },
    };

    try out.appendSlice(arena, if (l == .en)
        "# iro – Help\n\n> Welcome. You don't need to memorize any of this: the hint bar at the bottom\n> always shows the keys that make sense right now.\n"
    else
        "# iro – Hilfe\n\n> Willkommen. Du musst dir nichts davon merken: unten in der Hinweisleiste\n> stehen immer die Tasten, die gerade sinnvoll sind.\n");
    for (sections) |sec| {
        try out.appendSlice(arena, "\n## ");
        try out.appendSlice(arena, sec.head.in(l));
        try out.appendSlice(arena, "\n\n");
        const intro = sec.intro.in(l);
        if (intro.len > 0) {
            try out.appendSlice(arena, intro);
            try out.appendSlice(arena, "\n\n");
        }
        for (sec.lines) |ln| {
            var key = ln.key.in(l);
            if (ln.cmd) |c| {
                key = cfg.keyLabel(c);
                if (key.len == 0) key = if (l == .en) "(no key)" else "(keine Taste)";
            }
            try out.appendSlice(arena, "  ");
            try out.appendSlice(arena, key);
            // Pad by visible characters, not bytes (multi-byte characters).
            const shown = std.unicode.utf8CountCodepoints(key) catch key.len;
            const col = 20;
            try out.appendNTimes(arena, ' ', if (shown < col) col - shown else 2);
            try out.appendSlice(arena, ln.say.in(l));
            try out.append(arena, '\n');
        }
    }
    try out.appendSlice(arena, if (l == .en)
        "\n## About iro\n\niro (色 · Instant · Riced · Operator) — designed by Mausmann.\nFree software under the GNU GPL v3 (or later); commercial license on request.\n"
    else
        "\n## Über iro\n\niro (色 · Instant · Riced · Operator) — entwickelt von Mausmann.\nFreie Software unter der GNU GPL v3 (oder neuer); kommerzielle Lizenz auf Anfrage.\n");
    return out.items;
}

test "help page uses active bindings and explains the minimap" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var cfg = try config.Config.loadFromSlice(gpa, "tasten = { speichern = \"Strg+E\", minimap = \"\" }");
    defer cfg.deinit(gpa);

    const txt = try generate(arena_state.allocator(), &cfg);
    try std.testing.expect(std.mem.indexOf(u8, txt, "# iro – Hilfe") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "Strg+E") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "(keine Taste)") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "⠿ rechts") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "Mausmann") != null);

    cfg.lang = .en;
    const en = try generate(arena_state.allocator(), &cfg);
    try std.testing.expect(std.mem.indexOf(u8, en, "# iro – Help") != null);
    try std.testing.expect(std.mem.indexOf(u8, en, "Ctrl+E") != null);
    try std.testing.expect(std.mem.indexOf(u8, en, "(no key)") != null);
    try std.testing.expect(std.mem.indexOf(u8, en, "Two gears: Blade and Forge") != null);
}
