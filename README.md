<div align="center">

<img src="src/logo.png" alt="iro logo" width="220">

# iro

**Instant · Riced · Operator**

*A modeless terminal editor that looks good, stays out of your way and never loses your work.*

![Status](https://img.shields.io/badge/status-early%20alpha-orange)
![Zig](https://img.shields.io/badge/Zig-0.17-f7a41d?logo=zig&logoColor=white)
![Lua](https://img.shields.io/badge/config-Lua%205.4-2c2d72?logo=lua&logoColor=white)
![Platform](https://img.shields.io/badge/platform-Linux-informational?logo=linux&logoColor=white)
![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)

**English** · [Deutsch](README.de.md)

</div>

<!-- TODO: demo GIF goes here -->

> **Early alpha.** iro is young, moves fast and is used daily on exactly one Arch
> laptop so far. It has a test suite, but no track record yet. For configs that
> can lock you out of your own machine, keep your old editor within reach until
> iro has earned your trust.

## What is iro?

iro is a terminal editor for people who want **micro's simplicity** with the
**comfort of a modern GUI editor**, and who care how their terminal looks.

You open a file and type. There are no modes to learn and no plugin manager to
feed. Ctrl+S saves, Ctrl+Q quits, the mouse just works, and everything else is
one keystroke or one menu away.

*The name:* **色** (*iro*) is Japanese for “colour, style”, a fitting word for a riced editor.

### What iro is not

iro is not trying to replace Neovim, Helix or Emacs. If you live inside a
carefully tuned modal setup with forty plugins, keep it. You have earned it.
iro aims at the space between *“nano, but I'm sad”* and *“I'm configuring my
editor instead of using it.”*

## Why iro?

### ⚙️ Two gears, same keys

Most editing is one of two jobs, so iro has two gears:

| | Gear | Motto | What you get |
|---|---|---|---|
| ✂️ | **Blade** | *Get in. Cut. Get out.* | **Config edit mode: simple and fast.** Just the text, nothing running in the background. Perfect for a quick fix to `hyprland.conf` or `/etc/fstab`. |
| ⚒️ | **Forge** | *Heat up. Hammer. Ship it.* | File tree, minimap, git gutter, project-wide file search. For actually writing code. |

iro **picks the gear for you**: open a file and you land in Blade, open a folder
(or nothing at all) and you land in Forge. Alt+G switches at any time, and the
keys never change between gears.

### 🎨 Riced by default, quiet when it matters

- **Follows your wallpaper.** iro reads the terminal's own palette, so when your
  wallpaper tool recolours the terminal, iro recolours with it. Live.
- **17 built-in themes** if you prefer a fixed look, including two retro ones
  (green phosphor and amber CRT).
- Cursor line, git gutter, indent guides, bracket pairs, a **Braille minimap**,
  smooth little animations and Nerd Font icons.
- **Idle means idle.** No redraws, no busy loops, just a wallpaper sync every
  ten seconds.
- Everything can be switched off individually. Tasteful is the point, not a
  fairground.

### 🛟 Paranoid about your data

- **Atomic saves:** write to a temporary file, sync, then rename. A crash mid-save
  leaves the old file intact. Permissions, owner and group, ACLs, hard links and
  symlinks survive.
- **Crash recovery:** unsaved work, even in tabs without a file name, is backed
  up every two seconds and offered back after a crash or a closed terminal.
- **Changed on disk?** iro tells you before it overwrites someone else's edit.
- “Save as” never silently replaces an existing file.

### 🔒 Secure by design

- **Trojan Source detection:** invisible characters that flip the reading
  direction or hide text are shown as red markers.
- Control characters in file names and contents never reach your terminal raw.
- The Lua config runs **on a leash**: it can compute and read environment
  variables, but cannot start programs, touch files or load code. It is only ever
  read from iro's own config folder, never from a project you just cloned.
- Always built in Zig's safe mode, with runtime checks left on.

### ⚡ Small and fast

- **About 2 MB** stripped binary, logo included. Runtime dependencies: libc and Lua.
- **About 7 MB of RAM** with a 4,000-line source file open.
- **File search across ~350,000 files in 40–75 ms** (warm cache), indexed in the
  background on all cores, with typo tolerance. `hyprlnad` still finds `hyprland.lua`.

### 🔋 Batteries included, no plugins

iro deliberately has **no plugin system and no extensions**. What it does, it does
out of the box, and it all ships, gets tested and breaks together. The upside:
nothing to install, nothing to update, no config archaeology after a year away.

## Features at a glance

- **Editing:** word-wise undo/redo, find and replace, word completion, soft wrap,
  toggle comment, indent/outdent, duplicate and move lines, multiple tabs, split view.
- **Navigation:** clickable file tree with create/rename/trash, command palette with
  fuzzy search, project-aware file search (Ctrl+O, press again for your whole
  home), folder jumps via zoxide.
- **Syntax colours for 28 languages,** from Shell, Hyprland and kitty configs to
  Zig, Rust, C/C++, Python, Go, JS/TS, Lua, Nix and Markdown.
- **Point-and-click settings page** (Esc → Settings) with live theme preview, or
  plain Lua in `init.lua` if you prefer text.
- **Built-in help** (Alt+H) and a hint bar that shows the keys that matter right now.
- **English and German UI,** following your system language.

## Installation

You need **Zig 0.17.x** (pinned on purpose) and **Lua 5.4**.

```sh
git clone https://github.com/mantantis/iro.git
cd iro
zig build --prefix ~/.local    # installs ~/.local/bin/iro
```

On Arch there is also a `PKGBUILD`: `makepkg -si`.

Optional at runtime: `wl-clipboard` (system clipboard), `glib2` (trash),
`zoxide` (Alt+Z), `git` (git gutter), a Nerd Font (icons).
iro looks its best in **kitty** (images, colours, extra keys); other terminals get a
plainer look with full functionality.

## Keys

| Key | Action |
|---|---|
| Ctrl+S / F12 | save / save as |
| Ctrl+O / Ctrl+P / Alt+Z | find file / command palette / folder from zoxide |
| Ctrl+B | file tree (inside: N new file, O new folder, F2 rename, Del trash) |
| Ctrl+F / F3 / Ctrl+R | find / find next / find and replace |
| Ctrl+K / Ctrl+D | toggle comment / duplicate line |
| Alt+Up / Alt+Down | move line |
| Ctrl+Z / Ctrl+Y | undo / redo |
| Ctrl+Space | complete word |
| Alt+G | switch gear: Blade ⇄ Forge |
| Alt+W / Alt+V | soft wrap / split view |
| Ctrl+N / Ctrl+W / Alt+1…9 | new tab / close tab / jump to tab |
| Esc / F10 | main menu |
| Alt+H | help: every key and symbol explained |
| F9 | about iro (watch it decrypt itself) |

Every key can be remapped.

## Configuration

```lua
-- ~/.config/iro/init.lua
gear = "auto"               -- "blade", "forge" or "auto"
theme = "terminal"          -- follow the terminal palette, or e.g. "nord", "phosphor"
tab_width = 4
minimap = true
keys = { tree = "Ctrl+E", replace = "Ctrl+H" }
colors = { accent = "#00E5FF" }
```

No `init.lua` yet? Ctrl+P → “Open settings file” creates a commented one.
Changes apply on save.

## Roadmap

- **Config parachute:** before saving a system config, iro checks it with the tool
  that knows best (`visudo -c`, `sshd -t`, `findmnt --verify`, `hyprctl configerrors`
  and friends), and can roll a risky change back automatically if you don't confirm
  it. Because nobody should need a live USB stick to fix a typo.
- **A more comfortable Forge:** search across file contents and more of what you
  need to code all day without leaving the terminal.

## Building and testing

```sh
zig build                      # build zig-out/bin/iro
zig build test                 # unit tests
tests/e2e.sh                   # end-to-end run in tmux (~4 minutes)
```

## Credits

Idea & design: **Mausmann**. Built with AI (Claude Code & Antigravity).
Terminal rendering by [libvaxis](https://github.com/rockorager/libvaxis).

## License

`Copyright (C) 2026 Mausmann` · [GNU GPL v3.0 or later](LICENSE), with additional
terms under section 7 (see [`NOTICE.md`](NOTICE.md)).

Free as in freedom: read it, bend it, share it. Forks get their own name, keep
the credits and tip their hat to the original: “Based on iro by Mausmann”.
