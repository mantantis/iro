# Changelog

All notable changes to iro are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and iro uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Config Guard: validates known configs (`fstab`, `sudoers`, `sshd_config`,
  `systemd` units, shell scripts, JSON) before saving and checks Hyprland
  configs via `hyprctl configerrors` right after saving (`config_guard = false`
  disables it).
- Automatic gear shifting: opening the file tree, a second tab, split view or
  file search in Blade shifts up to Forge (`auto_gear = false` disables it).
- Local history of earlier file versions: the last 20 per file, Alt+R brings one back.
- A file already open in another iro opens read-only and names that iro's PID.
- Files changed by another program reload when you return to iro, if the tab has
  no unsaved changes. Otherwise iro warns, and the overwrite question can load the
  file from disk instead.

### Changed
- Command palette, file search, version history and word completion now share
  the same card styling (tinted background, title bar, accent selection marker
  and mouse hover) as the main menu and settings page.
- Saving keeps owner, group, ACLs and hard links intact.
- iro only wakes up when there is work to do.
- External helpers (`git`, `wl-paste`, `gio`, `zoxide`) time out after two
  seconds so a stuck clipboard or dead mount cannot freeze iro.

### Security
- The config sandbox no longer offers `print` and `string.dump`.
- Pattern matching in `init.lua` (`string.find`, `match`, `gmatch`, `gsub`) now
  counts toward the step limit.
