#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.
# End-to-end test: starts iro in a detached tmux session, presses keys and
# checks the screen and the file. Takes about four minutes.
#
# zig build && tests/e2e.sh
#
# Runs on its own tmux server (-L irotest) and never touches other sessions.
# Recovery files go to a throwaway folder, not ~/.local/state.
set -u
# IRO=/path/to/iro tests/e2e.sh tests a different binary (e.g. a copy).
IRO="${IRO:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/iro}"
E="$(mktemp -d)"; export XDG_STATE_HOME="$E/state" XDG_CONFIG_HOME="$E/config"
# Backups of secrets go to the runtime folder; keep them out of the real one.
export XDG_RUNTIME_DIR="$E/run"; mkdir -m 700 "$XDG_RUNTIME_DIR"
# For the trash test: a folder on the same disk as the home directory (/tmp has
# no trash) with its own throwaway trash.
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}"
T="$(mktemp -d -p "${XDG_CACHE_HOME:-$HOME/.cache}" iro-probelauf.XXXXXX)"
trap 'tmux -L irotest kill-server 2>/dev/null; rm -rf "$E" "$T"' EXIT
fails=0
# The checks expect the German UI regardless of system settings (CI runs in
# English). A separate section checks English.
export LANG=de_DE.UTF-8; unset LC_ALL LC_MESSAGES

t()      { tmux -L irotest "$@"; }
start()  { t kill-server 2>/dev/null; sleep 0.4; t new-session -d -x 90 -y 10 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' ${EXTRA_ENV:-} '$IRO' '$1'; sleep 60"; sleep 2.2; }
keys()   { t send-keys "$@"; sleep 0.15; }
lit()    { t send-keys -l "$1"; sleep 0.15; }
screen() { t capture-pane -p; }
ok()     { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; screen | sed 's/^/        | /'; fails=$((fails+1)); fi; }

F="$E/probe.txt"

echo "Typing and saving"
start "$F"
lit 'Hallo Welt'; keys Enter; lit '  eingerückt äöü 🦅'; keys Enter; lit 'drei'
ok "Indentation kept"      '[ "$(screen | sed -n 3p)" = "  3   drei" ]'
ok "Marked as modified"    'screen | tail -1 | grep -q "probe.txt ●"'
keys C-s; sleep 0.3
ok "Message after saving" 'screen | tail -1 | grep -q "Gespeichert"'
ok "File content matches"         '[ "$(cat "$F")" = "$(printf "Hallo Welt\n  eingerückt äöü 🦅\n  drei")" ]'

echo "Search, replace by typing, undo"
keys C-f; lit 'welt'; keys Escape; lit 'X'
ok "Match was replaced"      '[ "$(screen | sed -n 1p)" = "  1 Hallo X" ]'
keys C-z
ok "Undo restores"     '[ "$(screen | sed -n 1p)" = "  1 Hallo Welt" ]'
ok "No longer modified"        '! screen | tail -1 | grep -q "●"'

echo "Quitting with unsaved changes"
keys C-g; lit '3'; keys Enter; keys End; lit ' NEU'; keys C-q
ok "Prompt appears"        'screen | tail -1 | grep -qF "[V]erwerfen"'
# Answered in capitals, as the prompt shows it (Shift / Caps Lock).
keys V; sleep 0.4
ok "Capital letter answers the prompt" '[ "$(t display -p "#{pane_current_command}")" = "sleep" ]'
ok "Discarded, file unchanged" '[ "$(tail -1 "$F")" = "  drei" ]'

echo "Save as (F12)"
start "$F"; keys F12
ok "Input line appears"     'screen | tail -1 | grep -q "Speichern als: .*probe.txt"'
keys C-BSpace 2>/dev/null; for i in $(seq 1 120); do t send-keys BSpace; done; sleep 0.3
lit "$E/kopie.txt"; keys Enter; sleep 0.3
ok "Copy was created"       'cmp -s "$F" "$E/kopie.txt"'
ok "Name in the bar changed" 'screen | tail -1 | grep -q "kopie.txt"'
keys C-q; sleep 0.3

echo "Hard kill and recovery"
start "$F"; keys C-End; lit ' UNGESICHERT'; sleep 4.5
# Only kill the iro of this test session, never another one.
pkill -9 -P "$(t list-panes -F '#{pane_pid}')" -x iro; sleep 0.3
ok "Original intact after kill" '[ "$(tail -1 "$F")" = "  drei" ]'
start "$F"
ok "Backup is offered"   'screen | tail -1 | grep -qF "[W]iederherstellen"'
keys w; keys C-s; keys C-q; sleep 0.4
ok "Change is back"        '[ "$(tail -1 "$F")" = "  drei UNGESICHERT" ]'
ok "Backup cleaned up"       '[ -z "$(ls "$XDG_STATE_HOME/iro/swap" 2>/dev/null)" ]'

echo "Undo after recovery selects nothing"
start "$F"; keys C-End; lit ' WEG'; sleep 4.5
pkill -9 -P "$(t list-panes -F '#{pane_pid}')" -x iro; sleep 0.3
start "$F"; keys w; keys C-z; lit 'Q'
ok "The next key after undo does not replace the whole file" '[ "$(screen | sed -n 1p)" = "  1 QHallo Welt" ]'
keys C-q; sleep 0.2; keys v; sleep 0.4

echo "SIGTERM and SIGHUP back up at once and leave cleanly"
before="$(cat "$F")"
# Well inside the two seconds before the regular backup.
start "$F"; keys C-End; lit ' PERTERM'; sleep 0.3
pkill -TERM -P "$(t list-panes -F '#{pane_pid}')" -x iro; sleep 0.8
ok "SIGTERM ends iro and leaves the alternate screen" '[ "$(t display -p "#{pane_current_command}")" = "sleep" ] && [ "$(t display -p "#{alternate_on}")" = "0" ]'
ok "SIGTERM backed up the last change" 'grep -rq "PERTERM" "$XDG_STATE_HOME/iro/swap"'
start "$F"
ok "Backup is offered after SIGTERM" 'screen | tail -1 | grep -qF "[W]iederherstellen"'
keys v; sleep 0.2; keys C-End; lit ' PERHUP'; sleep 0.3
# Closing the terminal window sends SIGHUP.
t kill-server; sleep 0.8
ok "SIGHUP backed up the last change" 'grep -rq "PERHUP" "$XDG_STATE_HOME/iro/swap"'
start "$F"; keys v; sleep 0.2; keys C-q; sleep 0.3
ok "File untouched, backups gone" '[ "$(cat "$F")" = "$before" ] && [ -z "$(ls "$XDG_STATE_HOME/iro/swap" 2>/dev/null)" ]'

echo "Symlinks keep their name"
mkdir -p "$E/repo"; printf 'inhalt\n' > "$E/repo/echt.conf"; ln -s "$E/repo/echt.conf" "$E/link.conf"
start "$E/link.conf"
ok "Tab shows the name of the link" 'screen | tail -1 | grep -q "link.conf" && ! screen | tail -1 | grep -q "echt.conf"'
keys End; lit ' neu'; keys C-s; sleep 0.3; keys C-q; sleep 0.3
ok "Saving writes through the link" '[ -L "$E/link.conf" ] && [ "$(cat "$E/repo/echt.conf")" = "inhalt neu" ]'
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 90 -y 10 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO' '$E/link.conf' '$E/repo/echt.conf'; sleep 60"; sleep 2.2
# With two tabs, the first line would be the tab bar.
ok "Link and target on the command line give one tab" '[ "$(screen | sed -n 1p)" = "  1 inhalt neu" ]'
keys C-q; sleep 0.3

echo "Ctrl+X without selection cuts the line"
start "$F"; keys Down; keys Right; keys C-x
ok "Line gone, next one moves up" '[ "$(screen | sed -n 2p)" = "  2   drei UNGESICHERT" ]'
ok "Message in the bar"           'screen | tail -1 | grep -q "Zeile ausgeschnitten"'
keys C-z
ok "Undo brings the line back"      'screen | sed -n 2p | grep -q "eingerückt"'
keys C-q; sleep 0.3

echo "Pasting (bracketed paste)"
P="$E/paste.txt"; printf 'oben\n' > "$P"
paste() { t set-buffer -- "$1"; t paste-buffer -p -r; sleep 0.4; }
start "$P"; keys C-End
paste $'\neins\r\nzwei\rdrei'
ok "CRLF and CR become single line breaks" '[ "$(screen | sed -n 2p)" = "  2 eins" ] && [ "$(screen | sed -n 3p)" = "  3 zwei" ] && [ "$(screen | sed -n 4p)" = "  4 drei" ]'
keys C-s; sleep 0.3
keys Escape; sleep 0.3; paste 'HINTER DEM MENÜ'; keys Escape; sleep 0.3
ok "Nothing lands behind the open menu" '! screen | grep -q "HINTER DEM MENÜ" && ! screen | tail -1 | grep -q "●"'
keys C-b; sleep 0.4; paste 'HINTER DEM BAUM'
ok "Nothing lands behind the focused tree" '! screen | grep -q "HINTER DEM BAUM" && screen | tail -1 | grep -q "Einfügen geht nur im Text"'
keys C-q; sleep 0.3

echo "File tree (Ctrl+B)"
mkdir -p "$E/baum/unter"
printf 'eins\n' > "$E/baum/a.txt"; printf 'zwei\n' > "$E/baum/b.txt"; printf 'tief\n' > "$E/baum/unter/c.txt"
start "$E/baum/a.txt"; keys C-b
ok "Tree appears with folder name" 'screen | sed -n 1p | grep -q "↑ baum .*│ *1 eins"'
ok "Folder comes before files"   'screen | sed -n 2p | grep -q "▸ .*unter" && screen | sed -n 3p | grep -q "a.txt"'
keys Down; keys Enter; sleep 0.3
ok "Enter opens the file in a new tab" 'screen | sed -n 1p | grep -q "a.txt .*b.txt" && screen | sed -n 2p | grep -q "1 zwei"'
keys C-b; keys Home; keys Enter
ok "Folder expands"              'screen | sed -n 3p | grep -q "▾ .*unter" && screen | sed -n 4p | grep -q "c.txt"'
keys Down; keys Enter; sleep 0.3
ok "File from subfolder open"    'screen | sed -n 2p | grep -q "1 tief"'
lit 'X'; keys C-b; keys Down; keys Enter; sleep 0.3
ok "Already open file: switch without prompt" 'screen | sed -n 2p | grep -q "1 eins" && screen | sed -n 1p | grep -q "c.txt ●"'
keys C-b; keys C-b
ok "Ctrl+B in the tree hides it" '! screen | grep -q "│"'
keys C-q
ok "Quitting asks about the modified tab" 'screen | tail -1 | grep -q "Änderungen in c.txt"'
keys v; sleep 0.4
ok "Discarded, file unchanged"   '[ "$(cat "$E/baum/unter/c.txt")" = "tief" ]'
start "$E/baum"
ok "Starting with a folder shows the tree" 'screen | sed -n 1p | grep -q "↑ baum" && screen | tail -1 | grep -q "unbenannt"'
keys BSpace
ok "Backspace goes up one level" 'screen | grep -q "▸ .*baum"'
keys C-q; sleep 0.3

echo "Tabs"
# Two files at once: the quoting trick passes both to iro.
start "$E/baum/a.txt' '$E/baum/b.txt"
ok "Two files, two tabs"        'screen | sed -n 1p | grep -q "a.txt .*b.txt" && screen | sed -n 2p | grep -q "1 eins"'
keys M-2
ok "Alt+2 jumps to the second tab"  'screen | sed -n 2p | grep -q "1 zwei"'
keys C-PPage
ok "Ctrl+PgUp switches back"  'screen | sed -n 2p | grep -q "1 eins"'
keys C-n
ok "Ctrl+N: new empty tab"       'screen | sed -n 1p | grep -q "a.txt .*unbenannt .*b.txt"'
keys C-o; lit "$E/baum/unter/c.txt"; keys Enter; sleep 0.3
ok "Ctrl+O replaces the empty tab"  'screen | sed -n 1p | grep -q "a.txt .*c.txt .*b.txt" && screen | sed -n 2p | grep -q "1 tief"'
lit 'Y'; keys C-w
ok "Ctrl+W asks when modified"    'screen | tail -1 | grep -q "Änderungen in c.txt"'
keys v; sleep 0.3
ok "Tab closed, file unchanged"      '! screen | sed -n 1p | grep -q "c.txt" && [ "$(cat "$E/baum/unter/c.txt")" = "tief" ]'
keys M-1; lit 'A'; keys M-2; lit 'B'; keys C-q
ok "Quitting asks tab by tab"      'screen | tail -1 | grep -q "Änderungen in b.txt"'
keys s; sleep 0.4
ok "Then the next tab"         'screen | tail -1 | grep -q "Änderungen in a.txt"'
keys v; sleep 0.5
ok "b saved, a discarded"     '[ "$(cat "$E/baum/b.txt")" = "Bzwei" ] && [ "$(cat "$E/baum/a.txt")" = "eins" ]'
ok "No backups left"        '[ -z "$(ls "$XDG_STATE_HOME/iro/swap" 2>/dev/null)" ]'

echo "Hint bar (F1)"
hints() { screen | tail -2 | head -1; }
start "$E/baum/a.txt"
ok "Hints in the text"               'hints | grep -q "\^S  Speichern" && hints | grep -q "F1  Hinweise aus"'
keys S-Right
ok "Different hints with a selection" 'hints | grep -q "\^C  Kopieren" && ! hints | grep -q "Speichern"'
keys Escape; sleep 0.3; keys C-b
ok "Different hints in the tree"        'hints | grep -q "Enter  Öffnen" && hints | grep -q "Neue Datei"'
keys Down; keys Enter; sleep 0.3
ok "With two tabs: tab keys"      'hints | grep -q "Tab wechseln"'
keys F1
ok "F1 hides the bar"      '! screen | grep -q "Speichern" && screen | tail -1 | grep -q "Hinweise aus"'
keys C-q; sleep 0.3
start "$E/baum/a.txt"
ok "The choice is remembered"          '! screen | grep -q "Hinweise aus"'
keys F1
ok "F1 brings it back"             'hints | grep -q "\^S  Speichern"'
keys C-q; sleep 0.3

echo "Command palette (Ctrl+P)"
start "$E/baum/a.txt' '$E/baum/b.txt"
keys C-p
ok "Palette appears"              'screen | grep -q "Befehl suchen" && screen | grep -q "Datei speichern .*Strg+S"'
lit 'gz'
ok "Fuzzy search finds"         'screen | sed -n 5p | grep -q "Gehe zu Zeile"'
keys Enter
ok "Enter runs the command"     'screen | tail -1 | grep -q "Gehe zu Zeile:" && ! screen | grep -q "Befehl suchen"'
keys Escape; sleep 0.3
keys C-p; lit 'b.txt'; keys Enter; sleep 0.3
ok "Palette jumps to an open tab" 'screen | sed -n 2p | grep -q "1 Bzwei"'
keys C-p; lit 'qqqq'
ok "Nothing found"                'screen | grep -q "Nichts gefunden"'
keys Escape; sleep 0.3
ok "Esc closes the palette"       '! screen | grep -q "Nichts gefunden" && screen | sed -n 2p | grep -q "1 Bzwei"'
keys C-p; lit 'tab neu'; keys Enter
ok "Command 'Tab: new'"              'screen | sed -n 1p | grep -q "unbenannt"'
keys C-q; sleep 0.3

echo "File search (Ctrl+O) and completion (Tab)"
start "$E/baum/a.txt"
keys C-o
ok "Search box lists the files"   'screen | grep -q "Datei suchen in .*baum" && screen | grep -q "unter/c.txt"'
lit 'ctx'
ok "Fuzzy search across paths"     'screen | sed -n 5p | grep -q "unter/c.txt" && screen | grep -q "1 von 3"'
keys Enter; sleep 0.3
ok "Enter opens the match"       'screen | sed -n 2p | grep -q "1 tief"'
keys C-o; keys Tab
ok "Tab switches to path input"  'screen | tail -1 | grep -q "Öffnen: .*/baum/$"'
keys Tab
ok "Several matches are shown" 'screen | tail -1 | grep -q "a.txt  b.txt  unter/"'
lit 'un'; keys Tab
ok "Unique folder gets a slash" 'screen | tail -1 | grep -q "Öffnen: .*/baum/unter/$"'
keys Tab
ok "Single file is completed"     'screen | tail -1 | grep -q "/baum/unter/c.txt"'
keys Escape; sleep 0.3
keys C-o; lit '/'
ok "Slash means a path"  'screen | tail -1 | grep -q "Öffnen: /$"'
keys Escape; sleep 0.3; keys C-q; sleep 0.3

echo "Managing files in the tree (N, O, F2, Del)"
mkdir -p "$T/proj/sub"; printf 'ix\n' > "$T/proj/x.txt"
EXTRA_ENV="XDG_DATA_HOME='$T/data'"
start "$T/proj"
keys n
ok "N in the selected folder"          'screen | tail -1 | grep -q "Neue Datei in sub/:"'
keys Escape; sleep 0.3; keys Down; keys n
ok "N next to the selected file"    'screen | tail -1 | grep -q "Neue Datei in proj/:"'
lit 'x.txt'; keys Enter
ok "Existing file stays intact"   'screen | tail -1 | grep -q "gibt es schon" && [ "$(cat "$T/proj/x.txt")" = "ix" ]'
for i in 1 2 3 4 5; do t send-keys BSpace; done; sleep 0.2
lit 'neu.txt'; keys Enter; sleep 0.3
ok "New file created and open"  '[ -f "$T/proj/neu.txt" ] && screen | tail -1 | grep -q "iro .*neu.txt"'
lit 'inhalt'; keys C-b; keys F2
ok "Rename suggests the name" 'screen | tail -1 | grep -q "Umbenennen in: neu.txt"'
for i in 1 2 3 4 5 6 7; do t send-keys BSpace; done; sleep 0.2
lit 'alt.txt'; keys Enter; sleep 0.3
ok "Renamed, tab follows"    '[ -f "$T/proj/alt.txt" ] && [ ! -e "$T/proj/neu.txt" ] && screen | tail -1 | grep -q "Umbenannt in alt.txt"'
keys C-s; sleep 0.3
ok "Save (also from the tree) under the new name" '[ "$(cat "$T/proj/alt.txt")" = "inhalt" ] && [ ! -e "$T/proj/neu.txt" ]'
keys o; lit 'ordner'; keys Enter; sleep 0.3
ok "New folder created"          '[ -d "$T/proj/ordner" ] && screen | grep -q "▸ .*ordner"'
keys DC
ok "Trash asks first"          'screen | tail -1 | grep -q "ordner in den Papierkorb legen"'
keys n
ok "No leaves everything as is"        '[ -d "$T/proj/ordner" ]'
keys DC; keys j; sleep 0.8
ok "Folder is in the trash"     '[ ! -e "$T/proj/ordner" ] && [ -d "$T/data/Trash/files/ordner" ]'
keys Home; keys Down; keys DC; keys j; sleep 0.8
ok "File in the trash, tab closed"    '[ ! -e "$T/proj/alt.txt" ] && [ -f "$T/data/Trash/files/alt.txt" ] && screen | tail -1 | grep -q "alt.txt liegt im Papierkorb"'
keys C-q; sleep 0.3
EXTRA_ENV=""

echo "Save as: an existing file is never silently replaced"
printf 'WICHTIG\n' > "$E/wichtig.txt"; printf 'neu\n' > "$E/neu.txt"
start "$E/neu.txt"; keys F12
for i in $(seq 1 120); do t send-keys BSpace; done; sleep 0.3
lit "$E/wichtig.txt"; keys Enter
ok "Prompt appears"            'screen | tail -1 | grep -q "wichtig.txt gibt es schon. Ersetzen?"'
keys n
ok "No keeps both files intact"  '[ "$(cat "$E/wichtig.txt")" = "WICHTIG" ] && screen | tail -1 | grep -q "iro .*neu.txt"'
keys F12; for i in $(seq 1 120); do t send-keys BSpace; done; sleep 0.3
lit "$E/wichtig.txt"; keys Enter; keys j; sleep 0.3
ok "Yes replaces and switches the name" '[ "$(cat "$E/wichtig.txt")" = "neu" ] && screen | tail -1 | grep -q "wichtig.txt"'
keys C-q; sleep 0.3

echo "Find and replace (Ctrl+R)"
printf 'rot und rot\nblau\nrot rot\n' > "$E/farben.txt"
start "$E/farben.txt"; keys C-r; lit 'rot'; keys Enter
ok "Asks for the replacement"          'screen | tail -1 | grep -q "„rot“ ersetzen durch:"'
lit 'grün'; keys Enter
ok "Asks at the first match"    'screen | tail -1 | grep -qF "[J]a  [N]ein  [A]lle"'
keys j; keys n; keys j
ok "Yes, no, yes"                   '[ "$(screen | sed -n 1p)" = "  1 grün und rot" ] && [ "$(screen | sed -n 3p)" = "  3 grün rot" ]'
keys a
ok "All replaces the rest"          '[ "$(screen | sed -n 3p)" = "  3 grün grün" ] && screen | tail -1 | grep -q "3 Stellen ersetzt"'
ok "Skipped match stays"    '[ "$(screen | sed -n 1p)" = "  1 grün und rot" ]'
keys C-q; sleep 0.2; keys v; sleep 0.3

echo "Editing lines: indent, comment, duplicate, move"
printf 'eins\nzwei\ndrei\n' > "$E/zeilen.sh"
start "$E/zeilen.sh"; keys S-Down; keys S-Down; keys Tab
ok "Tab indents selected lines" '[ "$(screen | sed -n 1p)" = "  1     eins" ] && [ "$(screen | sed -n 2p)" = "  2     zwei" ] && [ "$(screen | sed -n 3p)" = "  3 drei" ]'
keys BTab
ok "Shift+Tab outdents again"     '[ "$(screen | sed -n 1p)" = "  1 eins" ] && [ "$(screen | sed -n 2p)" = "  2 zwei" ]'
keys C-k
ok "Ctrl+K comments out"         '[ "$(screen | sed -n 1p)" = "  1 # eins" ] && [ "$(screen | sed -n 2p)" = "  2 # zwei" ]'
keys C-k; keys Escape; sleep 0.3
ok "Again: comment removed"         '[ "$(screen | sed -n 1p)" = "  1 eins" ]'
keys C-Home; keys C-d
ok "Ctrl+D duplicates the line"    '[ "$(screen | sed -n 2p)" = "  2 eins" ] && [ "$(screen | sed -n 3p)" = "  3 zwei" ]'
keys C-End; keys M-Up; keys M-Up
ok "Alt+Up moves the line"     '[ "$(screen | sed -n 2p)" = "  2 drei" ]'
keys C-q; sleep 0.2; keys v; sleep 0.3

echo "Security: file name with control characters, private backups"
BOESE="$E/$(printf 'b\303\266\033]2;GEKAPERT\007se.txt')"
printf 'TOKEN=geheim\n' > "$BOESE"; chmod 600 "$BOESE"
start "$BOESE"
ok "Title contains no control characters" '[ "$(t display -p "#{pane_title}")" = "iro – bö?]2;GEKAPERT?se.txt" ]'
lit 'X'; sleep 4.5
ok "Backup of a secret stays in RAM, owner-only" '[ "$(stat -c %a "$XDG_RUNTIME_DIR"/iro/swap/*.swap)" = "600" ] && [ "$(stat -c %a "$XDG_RUNTIME_DIR/iro/swap")" = "700" ]'
ok "No copy of the secret on disk" '! grep -rqs geheim "$XDG_STATE_HOME/iro"'
keys C-s; sleep 0.3
ok "Protected file stays protected" '[ "$(stat -c %a "$BOESE")" = "600" ] && [ "$(cat "$BOESE")" = "XTOKEN=geheim" ]'
keys C-q; sleep 0.3
printf 'a\033[31mb \302\233c \342\200\256d\n' > "$E/unsichtbar.txt"
start "$E/unsichtbar.txt"
ok "Control and invisible characters are made visible" '[ "$(screen | sed -n 1p)" = "  1 a·[31mb ·c ▪d" ]'
keys C-q; sleep 0.3

echo "Unnamed text survives a crash"
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 90 -y 10 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO'; sleep 60"; sleep 2.2
lit 'Notiz ohne Namen'; sleep 4.5
pkill -9 -P "$(t list-panes -F '#{pane_pid}')" -x iro; sleep 0.3
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 90 -y 10 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO'; sleep 60"; sleep 2.2
ok "Text is back after restart" '[ "$(screen | sed -n 1p)" = "  1 Notiz ohne Namen" ] && screen | tail -1 | grep -q "unbenannt ●"'
ok "And is reported"              'screen | tail -1 | grep -q "aus der letzten Sitzung ist wieder da"'
keys C-q; sleep 0.2; keys v; sleep 0.4
ok "Discard means: backup gone" '[ -z "$(ls "$XDG_STATE_HOME/iro/swap" 2>/dev/null)" ]'

echo "Lua config (init.lua)"
mkdir -p "$XDG_CONFIG_HOME/iro"
cat > "$XDG_CONFIG_HOME/iro/init.lua" <<'LUA'
hinweise = false
tab_breite = 2
LUA
start "$E/baum/a.txt"
ok "Hint bar off via config" '! screen | grep -q "Hinweise aus"'
keys Tab
ok "Tab width 2 from init.lua"  '[ "$(screen | sed -n 1p)" = "  1   eins" ]'
keys C-q; sleep 0.2; keys v; sleep 0.3

cat > "$XDG_CONFIG_HOME/iro/init.lua" <<'LUA'
hinweise = true
tasten = { baum = "Strg+D", suchen = "", rueckgaengig = "" }
LUA
start "$E/baum/a.txt"
ok "Hint bar shows the new shortcut" 'hints | grep -q "\^D  Baum" && ! hints | grep -q "Suchen"'
keys C-d; sleep 0.3
ok "Custom shortcut Ctrl+D opens the tree" 'screen | grep -q "▸ .*unter"'
keys Escape; keys C-q; sleep 0.3

cat > "$XDG_CONFIG_HOME/iro/init.lua" <<'LUA'
tasten = { kaputt
LUA
start "$E/baum/a.txt"
ok "Broken init.lua reports an error" 'screen | tail -1 | grep -q "init.lua:"'
keys C-q; sleep 0.3

cat > "$XDG_CONFIG_HOME/iro/init.lua" <<LUA
os.execute("touch '$E/LUA_LIEF'")
LUA
start "$E/baum/a.txt"
ok "init.lua may not start programs" '[ ! -e "$E/LUA_LIEF" ] && screen | tail -1 | grep -q "init.lua:"'
keys C-q; sleep 0.3
cat > "$XDG_CONFIG_HOME/iro/init.lua" <<'LUA'
while true do end
LUA
start "$E/baum/a.txt"; sleep 1
ok "Endless loop does not hang iro" 'screen | tail -1 | grep -q "rechnet zu lange" && screen | sed -n 1p | grep -q "1 eins"'
keys C-q; sleep 0.3
rm -f "$XDG_CONFIG_HOME/iro/init.lua"

echo "Start screen"
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 90 -y 20 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO'; sleep 60"
sleep 2.2
ok "Start screen appears without a file" 'screen | grep -q "IRO" && screen | grep -q "Mausmann" && screen | grep -q "Tippe einfach los"'
lit 'Hallo'
ok "Typing hides the start screen" '[ "$(screen | sed -n 1p)" = "  1 Hallo" ] && ! screen | grep -q "Tippe einfach los"'
keys C-q; sleep 0.2; keys v; sleep 0.3

echo "Help page (Alt+H)"
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 100 -y 24 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO'; sleep 60"
sleep 2.2
ok "Start screen mentions the help"     'screen | grep -q "Alt+H .*Hilfe: alles kurz erklärt"'
keys M-h; sleep 0.3
ok "Alt+H opens the help"         'screen | sed -n 1p | grep -q "# iro – Hilfe" && screen | grep -q "Strg+S  *Speichern." && screen | tail -1 | grep -q "iro .*Hilfe"'
lit 'ZZZQ'; keys Enter; keys BSpace; keys DC; keys C-x; keys C-d; keys C-k; keys Tab
ok "Help cannot be modified" 'screen | sed -n 1p | grep -q "^ *1 # iro – Hilfe" && ! screen | grep -q "ZZZQ" && ! screen | tail -1 | grep -q "●" && screen | tail -1 | grep -q "nur zum Lesen"'
keys C-f; lit 'speichern'; keys Enter; keys Escape; sleep 0.3
ok "Searching in the help still works" 'screen | tail -1 | grep -q "Zeile [0-9]*, Spalte" && ! screen | tail -1 | grep -q "●"'
keys C-q; sleep 0.4
ok "Help closes without a prompt"  '! t list-panes -F "#{pane_current_command}" | grep -q iro'
cat > "$XDG_CONFIG_HOME/iro/init.lua" <<'LUA'
tasten = { speichern = "Strg+E", hilfe = "F9" }
LUA
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 100 -y 24 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO'; sleep 60"
sleep 2.2; keys F9; sleep 0.3
ok "Help shows the custom binding" 'screen | grep -q "Strg+E  *Speichern."'
keys C-q; sleep 0.3
rm -f "$XDG_CONFIG_HOME/iro/init.lua"

echo "Gears (Alt+G) and minimap (Alt+M)"
seq 1 30 | sed 's/.*/Zeile & mit Inhalt für die Minimap/' > "$E/minimap.txt"
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 100 -y 20 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO' '$E/minimap.txt'; sleep 60"
sleep 2.2
ok "A file starts in Blade"     'screen | tail -1 | grep -q "BLADE"'
ok "Blade: no minimap"            '! screen | grep -q "⣿"'
keys M-g; sleep 0.5
ok "Alt+G switches to Forge"        'screen | tail -1 | grep -q "FORGE" && screen | tail -1 | grep -q "Hammer. Ship it."'
ok "Forge: tree is there"              '[ "$(screen | grep -c minimap.txt)" -ge 2 ]'
lit 'X'
ok "Forge: typing goes to the text"    'screen | grep -q "XZeile 1 mit"'
keys C-z
ok "Braille minimap visible for a long file" 'screen | grep -q "⣿⣿⣿"'
keys M-m; sleep 0.3
ok "Message after switching off" 'screen | tail -1 | grep -q "Minimap ausgeblendet"'
ok "Braille minimap hidden" '! screen | grep -q "⠀" && ! screen | grep -q "⣿"'
keys M-m; sleep 0.3
ok "Message after switching on" 'screen | tail -1 | grep -q "Minimap eingeblendet"'
ok "Braille minimap visible again" 'screen | grep -q "⣿⣿⣿"'
keys M-g; sleep 0.5
ok "Back in Blade"                 'screen | tail -1 | grep -q "BLADE" && screen | tail -1 | grep -q "Cut. Get out."'
ok "Blade: tree and minimap gone"     '! screen | grep -q "⣿" && [ "$(screen | grep -c minimap.txt)" -eq 1 ]'
keys M-m; sleep 0.3
ok "Blade: Alt+M still brings it"  'screen | grep -q "⣿⣿⣿" && screen | tail -1 | grep -q "Minimap eingeblendet"'
keys C-q; sleep 0.3
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 100 -y 20 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO' --forge '$E/minimap.txt'; sleep 60"
sleep 2.2
ok "--forge beats the automatic choice"   'screen | tail -1 | grep -q "FORGE" && screen | grep -q "⣿⣿⣿"'
keys C-q; sleep 0.3
start "$E"
ok "A folder starts in Forge"     'screen | tail -1 | grep -q "FORGE"'
keys C-q; sleep 0.3
start "$E/minimap.txt"
keys C-b; sleep 0.3
ok "Ctrl+B in Blade shifts up to Forge" 'screen | tail -1 | grep -q "FORGE" && screen | tail -1 | grep -q "Forge — Alt+G zurück" && screen | grep -q "⣿⣿⣿"'
keys M-g; sleep 0.3
keys C-n; sleep 0.3
ok "Second tab in Blade shifts up to Forge" 'screen | tail -1 | grep -q "FORGE" && screen | tail -1 | grep -q "Forge — Alt+G zurück"'
keys C-q; sleep 0.3
mkdir -p "$XDG_CONFIG_HOME/iro"; printf 'auto_gear = false\n' > "$XDG_CONFIG_HOME/iro/init.lua"
start "$E/minimap.txt"
keys C-b; sleep 0.3
ok "auto_gear = false stays in Blade" 'screen | tail -1 | grep -q "BLADE" && ! screen | grep -q "⣿⣿⣿"'
keys C-q; sleep 0.3
rm -f "$XDG_CONFIG_HOME/iro/init.lua"

echo "Language: English via LANG, German via config"
EXTRA_ENV="LANG=en_US.UTF-8" start "$E/minimap.txt"
ok "LANG=en: status line in English"   'screen | tail -1 | grep -q "Ln 1, Col 1"'
keys C-s; sleep 0.3
ok "LANG=en: save message"        'screen | tail -1 | grep -q "Saved: minimap.txt (30 lines)"'
keys M-h; sleep 0.5
ok "LANG=en: help in English"         'screen | grep -q "iro – Help" && screen | tail -1 | grep -q "Help"'
keys C-w; sleep 0.3
keys F10; sleep 0.3
ok "LANG=en: menu in English"          'screen | grep -q "Switch gear" && screen | grep -q "Ctrl+N"'
keys Escape; lit 'x'; keys C-q; sleep 0.3
ok "LANG=en: prompt in English"     'screen | tail -1 | grep -qF "[S]ave  [D]iscard  [C]ancel"'
keys v; sleep 0.3
ok "V discards nothing in English"  'screen | tail -1 | grep -qF "[D]iscard"'
keys c; sleep 0.3
ok "C cancels"                     '! screen | tail -1 | grep -qF "[D]iscard"'
keys C-q; sleep 0.2; keys d; sleep 0.5
ok "D discards, file unchanged"   '[ "$(head -1 "$E/minimap.txt")" = "Zeile 1 mit Inhalt für die Minimap" ]'
mkdir -p "$XDG_CONFIG_HOME/iro"; printf 'language = "de"\n' > "$XDG_CONFIG_HOME/iro/init.lua"
EXTRA_ENV="LANG=en_US.UTF-8" start "$E/minimap.txt"
ok "language = de beats LANG"      'screen | tail -1 | grep -q "Zeile 1, Spalte 1"'
keys C-q; sleep 0.3
rm -f "$XDG_CONFIG_HOME/iro/init.lua"

echo "Word completion (Alt+Space), soft wrap (Alt+W), split view (Alt+V)"
start "$E/comp.txt"
lit 'fensterbreite alpha_eins alpha_zwei'; keys Enter; lit 'fenst'; keys M-Space; sleep 0.25
ok "Unique completion applies at once" 'screen | sed -n 2p | grep -q "fensterbreite"'
lit ' alpha_'; keys M-Space; sleep 0.25
ok "Popup appears for several matches" 'screen | grep -q "alpha_eins" && screen | grep -q "alpha_zwei"'
keys Down; keys Enter; sleep 0.2
ok "Second suggestion taken with Enter" 'screen | sed -n 2p | grep -q "fensterbreite alpha_zwei"'
keys C-q; sleep 0.2; keys v; sleep 0.3

python3 -c 'print("Langzeile_" + ("wort_" * 25))' > "$E/wrap.txt"
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 80 -y 16 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO' '$E/wrap.txt'; sleep 60"
sleep 2.2
keys M-w; sleep 0.25
ok "Soft wrap on via Alt+W" 'screen | tail -1 | grep -q "Zeilenumbruch eingeschaltet"'
ok "Wrap marker ↪ visible" 'screen | grep -q "↪"'
keys M-w; sleep 0.25
ok "Soft wrap off via Alt+W" 'screen | tail -1 | grep -q "Zeilenumbruch ausgeschaltet"'
ok "Wrap marker ↪ gone again" '! screen | grep -q "↪"'
keys M-v; sleep 0.25
ok "Split view on via Alt+V" 'screen | tail -1 | grep -q "Ansicht geteilt"'
ok "Vertical separator visible" 'screen | grep -q "│"'
keys M-Right; sleep 0.25
ok "Alt+Right switches to the right side" 'screen | tail -1 | grep -q "Rechte Ansicht"'
keys M-v; sleep 0.25
ok "Split view closed again" 'screen | tail -1 | grep -q "Geteilte Ansicht geschlossen"'
keys C-q; sleep 0.3

cat > "$XDG_CONFIG_HOME/iro/init.lua" <<'LUA'
startseite = false
LUA
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 90 -y 20 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO'; sleep 60"
sleep 2.2
ok "Start screen can be disabled in init.lua" '! screen | grep -q "Tippe einfach los" && screen | sed -n 1p | grep -qE "^ *1 *$"'
keys C-q; sleep 0.3
rm -f "$XDG_CONFIG_HOME/iro/init.lua"

echo "Main menu (Esc) and About (F9)"
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 90 -y 24 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO' '$E/baum/a.txt'; sleep 60"
sleep 2.2
keys Escape; sleep 0.3
ok "Esc opens the main menu"        'screen | grep -q "色 IRO" && screen | grep -q "Neue Datei .*Strg+N" && screen | grep -q "Beenden .*Strg+Q"'
ok "Signature in the menu"                'screen | grep -q "♥ Mausmann"'
ok "Hints match the menu"        'screen | grep -q "Buchstabe  Direkt wählen"'
keys Escape; sleep 0.3
ok "Esc closes the menu again"    '! screen | grep -q "色 IRO"'
keys S-Right; keys Escape; sleep 0.3
ok "Esc clears the selection first" '! screen | grep -q "色 IRO"'
keys Escape; sleep 0.3; keys Down; keys Down; keys Up; keys Enter; sleep 0.3
ok "Arrows and Enter run the entry"     'screen | grep -q "Datei suchen in .*baum" && ! screen | grep -q "色 IRO"'
keys Escape; sleep 0.3; keys Escape; sleep 0.3; keys h; sleep 0.3
ok "Letter selects directly (H)"      'screen | grep -q "# iro – Hilfe"'
keys C-w; sleep 0.3
keys F9; sleep 0.25
ok "F9: text still encrypted"     'screen | grep -q "Über iro" && ! screen | grep -q "Gebaut mit KI (Claude Code & Antigravity)"'
sleep 1.5
ok "F9: text settles afterwards"           'screen | grep -q "色  I R O" && screen | grep -q "Gebaut mit KI (Claude Code & Antigravity)" && screen | grep -q "ko-fi.com/mausmann"'
keys x; sleep 0.3
ok "Key closes About"         '! screen | grep -q "Über iro" && screen | sed -n 1p | grep -q "1 eins"'
keys F9; sleep 0.1; keys x; sleep 0.2
ok "First key shows everything at once"  'screen | grep -q "Gebaut mit KI (Claude Code & Antigravity)"'
keys x; sleep 0.2; keys C-q; sleep 0.3
cat > "$XDG_CONFIG_HOME/iro/init.lua" <<'LUA'
esc_menue = false
LUA
start "$E/baum/a.txt"
keys Escape; sleep 0.3
ok "esc_menu = false: Esc stays quiet" '! screen | grep -q "Neue Datei"'
keys F10; sleep 0.3
ok "F10 still opens the menu"      'screen | grep -q "Neue Datei"'
keys F10; sleep 0.2; keys C-q; sleep 0.3
rm -f "$XDG_CONFIG_HOME/iro/init.lua"

echo "Saving init.lua reloads at once"
printf 'hinweise = true\n' > "$XDG_CONFIG_HOME/iro/init.lua"
start "$XDG_CONFIG_HOME/iro/init.lua"
ok "Before: search in the hints"   'hints | grep -q "Suchen"'
keys C-End; keys Enter; lit 'tasten = { suchen = "" }'; keys C-s; sleep 0.4
ok "Message: applied at once"        'screen | tail -1 | grep -q "sofort übernommen"'
ok "Effect without reloading"             '! hints | grep -q "Suchen"'
keys End; lit ' kaputt'; keys C-s; sleep 0.4
ok "Error stays a message"        'screen | tail -1 | grep -q "init.lua:" && ! hints | grep -q "Suchen"'
keys C-z; keys C-s; keys C-q; sleep 0.3
rm -f "$XDG_CONFIG_HOME/iro/init.lua"

echo "Settings page (Esc → Settings)"
G="$XDG_CONFIG_HOME/iro/gewaehlt.lua"
printf 'minimap = true\n' > "$XDG_CONFIG_HOME/iro/init.lua"
t kill-server 2>/dev/null; sleep 0.4
t new-session -d -x 100 -y 34 "env XDG_STATE_HOME='$XDG_STATE_HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$IRO' '$E/baum/a.txt'; sleep 60"
sleep 2.2
keys Escape; keys e; sleep 0.2
ok "Page with headings and values"  'screen | grep -q "Einstellungen" && screen | grep -q "Aussehen" && screen | grep -q "Farbsatz .*‹ terminal ›"'
ok "Lock for a value from init.lua"    'screen | grep -q "Minimap .*init.lua"'
keys Right; sleep 0.2
ok "Theme switches and is remembered" 'screen | grep -q "‹ mohawk ›" && grep -q "theme = \"mohawk\"" "$G"'
keys Down; keys Down; keys Down; keys Down; keys Enter
ok "Pinned value explains itself"   'screen | tail -1 | grep -q "legt deine init.lua fest" && ! grep -q minimap "$G"'
keys Down; keys Enter; sleep 0.2
ok "Switch writes and takes effect"      'grep -q "wrap = true" "$G" && screen | grep -q "Zeilenumbruch .*● an"'
keys DC; sleep 0.2
ok "Del: back to the default"         '! grep -q wrap "$G" && screen | grep -q "Zeilenumbruch .*○ aus"'
keys End; keys Up; keys Up; keys Up; keys Up; keys Enter
ok "Waits for the new key"        'screen | grep -q "drück eine Taste"'
keys F7; sleep 0.2
ok "New key accepted"            'screen | grep -q "Hilfe: alle Tasten kurz erklärt .*F7" && grep -q "help = \"F7\"" "$G"'
keys Escape; sleep 0.2; keys F7; sleep 0.3
ok "New key works at once"          'screen | grep -q "# iro – Hilfe"'
keys C-q; sleep 0.3
start "$E/baum/a.txt"
keys F7; sleep 0.3
ok "Still there after restart"            'screen | grep -q "# iro – Hilfe"'
keys C-q; sleep 0.3
printf 'tasten = { hilfe = "F8" }\n' > "$XDG_CONFIG_HOME/iro/init.lua"
start "$E/baum/a.txt"
keys F7; sleep 0.3
ok "init.lua beats the clicks" '! screen | grep -q "# iro – Hilfe"'
keys F8; sleep 0.3
ok "init.lua key applies"              'screen | grep -q "# iro – Hilfe"'
keys C-q; sleep 0.3
rm -f "$XDG_CONFIG_HOME/iro/init.lua" "$G"

echo "File search: project, whole home, typos, recently opened"
H="$T/heim"
mkdir -p "$H/proj/.git" "$H/proj/src/tief" "$H/.config/hypr" "$H/Dokumente/Rechnungen" "$H/proj/node_modules/kram"
printf 'x\n' > "$H/proj/src/tief/main.zig"; printf 'y\n' > "$H/proj/README.md"
printf 'h\n' > "$H/.config/hypr/hyprland.lua"; printf 'r\n' > "$H/Dokumente/Rechnungen/rechnung_2024.txt"
printf 'm\n' > "$H/proj/node_modules/kram/index.js"
EXTRA_ENV="HOME='$H'"
start "$H/proj/README.md"
keys C-o; sleep 0.3
ok "Project via the git root"    'screen | grep -q "Datei suchen in Projekt proj" && screen | grep -q "src/tief/main.zig" && ! screen | grep -q "hyprland"'
ok "Junk folder stays out"     '! screen | grep -q "node_modules"'
keys C-o; sleep 0.5
ok "Ctrl+O: whole home"            'screen | grep -q "deinem ganzen Home" && screen | grep -q "hyprland.lua"'
lit 'hyprlnad'; sleep 0.3
ok "Typo forgiven (≈)"       'screen | grep -q "≈" && screen | sed -n 5p | grep -q ".config/hypr/hyprland.lua"'
keys Enter; sleep 0.3
ok "Match opened"               'screen | tail -1 | grep -q "hyprland.lua"'
ok "Recent list remembered"          'grep -q "/.config/hypr/hyprland.lua" "$XDG_STATE_HOME/iro/zuletzt"'
keys C-o; sleep 0.3
ok "Recently opened comes first"  'screen | sed -n 5p | grep -q "hypr/hyprland.lua"'
lit 'rechnung'; sleep 0.3
ok "Search in Dokumente"             'screen | sed -n 5p | grep -q "Dokumente/Rechnungen/rechnung_2024.txt"'
keys Escape; keys C-q; sleep 0.3
EXTRA_ENV=""

echo "Config Guard (pre-save validation)"
printf '{"ok": true}\n' > "$E/check.json"
start "$E/check.json"
keys End; lit ' kaputt'; keys C-s; sleep 0.3
ok "Broken JSON triggers Config Guard prompt" 'screen | tail -1 | grep -q "Config Guard (JSON)" && screen | tail -1 | grep -qF "[J]a, trotzdem"'
keys n; sleep 0.2
ok "No cancels save, disk file intact" '[ "$(cat "$E/check.json")" = "{\"ok\": true}" ]'
keys C-s; sleep 0.3; keys j; sleep 0.3
ok "Yes saves anyway when confirmed" 'grep -q "kaputt" "$E/check.json"'
keys C-q; sleep 0.3

printf '#!/bin/sh\nif true; then echo ok; fi\n' > "$E/check.sh"
start "$E/check.sh"
keys Down; keys End; keys BSpace; keys BSpace; keys BSpace; keys C-s; sleep 0.3
ok "Broken shell script triggers Config Guard" 'screen | tail -1 | grep -q "Config Guard (sh)"'
keys n; sleep 0.2; keys C-q; sleep 0.2; keys v; sleep 0.3

# No false alarms: comments in JSONC files, a mount point that does not exist
# yet (systemd creates it), and systemd versions without --recursive-errors.
printf '{\n  "compilerOptions": {\n    "strict": true,\n  },\n}\n' > "$E/tsconfig.json"
start "$E/tsconfig.json"
keys Down; keys End; lit ' // comment'; keys C-s; sleep 0.3
ok "tsconfig.json with comments saves without prompt" 'grep -q "// comment" "$E/tsconfig.json" && screen | tail -1 | grep -q "Gespeichert"'
keys C-q; sleep 0.3

printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "$E/fstab"
start "$E/fstab"
keys End; keys Enter; lit 'tmpfs /mnt/iro-neu-angelegt tmpfs defaults 0 0'; keys C-s; sleep 0.5
ok "fstab with a new mount point saves without prompt" 'grep -q "iro-neu-angelegt" "$E/fstab" && screen | tail -1 | grep -q "Gespeichert"'
keys C-q; sleep 0.3

mkdir -p "$E/oldsystemd"
cat > "$E/oldsystemd/systemd-analyze" <<'EOS'
#!/bin/sh
# Like systemd 249: no --recursive-errors.
for a in "$@"; do case "$a" in --recursive-errors*) echo "systemd-analyze: unrecognized option '$a'" >&2; exit 1;; esac; done
exit 0
EOS
chmod +x "$E/oldsystemd/systemd-analyze"
printf '[Service]\nExecStart=/usr/bin/true\n' > "$E/probe.service"
EXTRA_ENV="PATH='$E/oldsystemd:$PATH'"
start "$E/probe.service"
keys Down; keys End; keys Enter; lit '# x'; keys C-s; sleep 0.5
ok "Older systemd-analyze does not block saving units" 'grep -q "# x" "$E/probe.service" && screen | tail -1 | grep -q "Gespeichert"'
keys C-q; sleep 0.3
EXTRA_ENV=""

mkdir -p "$XDG_CONFIG_HOME/iro"; printf 'config_guard = false\n' > "$XDG_CONFIG_HOME/iro/init.lua"
printf '{"ok": true}\n' > "$E/check2.json"
start "$E/check2.json"
keys End; lit ' kaputt'; keys C-s; sleep 0.3
ok "config_guard = false saves without prompt" 'grep -q "kaputt" "$E/check2.json" && screen | tail -1 | grep -q "Gespeichert"'
keys C-q; sleep 0.3
rm -f "$XDG_CONFIG_HOME/iro/init.lua"

echo
if [ "$fails" -eq 0 ]; then echo "All checks passed."; else echo "$fails check(s) failed."; exit 1; fi
