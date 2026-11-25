# Changelog

All notable changes to iro are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and iro uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Config Guard: validates known configs (`fstab`, `sudoers`, `sshd_config`,
  `systemd` units, shell scripts, JSON, and JSONC with comments as in VS Code
  settings, `tsconfig.json` or Waybar) before saving and checks Hyprland
  configs via `hyprctl configerrors` once Hyprland has reloaded them
  (`config_guard = false` disables it). Works for copies opened through
  `sudoedit` and `visudo` too.
- Automatic gear shifting: opening the file tree, a second tab, split view or
  file search in Blade shifts up to Forge (`auto_gear = false` disables it).
- Local history of earlier file versions: the last 20 per file, Alt+R brings one back.
- A file already open in another iro opens read-only and names that iro's PID,
  also when it is opened through a symlink.
- Files changed by another program reload when you return to iro, if the tab has
  no unsaved changes. Otherwise iro warns, and the overwrite question can load the
  file from disk instead.
- Closing the terminal window, logging out or `killall iro` (SIGHUP, SIGTERM)
  backs up unsaved changes at once and restores the terminal. The next start
  offers to recover them.

### Changed
- A file opened through a symlink keeps the link's name in the tab and title,
  wherever it was opened from. Lock and "already open" checks still treat link
  and target as one file.
- Command palette, file search, version history and word completion now share
  the same card styling (tinted background, title bar, accent selection marker
  and mouse hover) as the main menu and settings page.
- Saving keeps owner, group, mode, ACLs, hard links and symlinks intact, even a
  symlink to a file that does not exist yet.
- iro only wakes up when there is work to do.
- External helpers (`git`, `wl-paste`, `gio`, `zoxide`) time out after two
  seconds so a stuck clipboard or dead mount cannot freeze iro.

### Security
- Crash-recovery backups of secrets (keys, owner-only files, `sudoedit`
  copies) are kept in RAM (`$XDG_RUNTIME_DIR`) instead of on disk.
- Secret detection for history and backups ignores case (`.ENV`, `server.KEY`)
  and follows symlinks to the real file.
- The config sandbox no longer offers `print` and `string.dump`.
- Pattern matching in `init.lua` (`string.find`, `match`, `gmatch`, `gsub`) now
  counts toward the step limit.
- `init.lua` can no longer hang iro: metatables with `__gc` are refused, and a
  config that keeps catching the step limit with `pcall` is stopped.
