# Contributing to iro

Thanks for taking the time. iro is a hobby project with a single maintainer,
so a few ground rules keep things smooth for both of us.

## Before you write code

- **Bugs:** open an issue with `iro --version`, your terminal, the steps to
  reproduce, and what you expected instead.
- **Security issues** do not belong in public issues. See [SECURITY.md](SECURITY.md).
- **Features and larger changes:** open an issue first. iro is opinionated
  (batteries included, no plugins), and it is cheaper to agree on an idea than
  to throw away a finished pull request.
- **Platform:** iro is built for kitty on Wayland. Fixes for other terminals
  and X11 are welcome, but that is where it gets tested.

## Setup

You need **Zig 0.17.x** (`build.zig` refuses anything else; CI uses 0.17.1)
and **Lua 5.4** with `pkg-config`. The end-to-end suite additionally needs
`tmux`, `gio` (from glib2) and a `de_DE.UTF-8` locale.

```sh
# Arch
sudo pacman -S --needed zig lua54 pkgconf tmux glib2

# Debian / Ubuntu (Zig from https://ziglang.org/download/)
sudo apt install liblua5.4-dev pkg-config tmux libglib2.0-bin
```

## Build and test

```sh
zig build                      # build zig-out/bin/iro
zig build test                 # unit tests
zig build && tests/e2e.sh      # end-to-end run in tmux (a few minutes)
```

- `tests/e2e.sh` tests `zig-out/bin/iro`, so always build first.
  `zig build --prefix ~/.local` does not update that binary.
- It runs on its own tmux server (`-L irotest`) with a throwaway config and
  state folder, and exits non-zero if any check fails.
- `IRO=/path/to/iro tests/e2e.sh` runs it against another binary, which is
  handy for proving that a new check fails on the old code.
- `iro --search-probe FOLDER [WORD]` indexes a folder like the file search does
  and prints the time, the file count and the top matches for `WORD`.

Both suites run in CI on every pull request and have to pass.

## Pull requests

- Fork, branch, and open the pull request against `main`. Only the maintainer
  merges, and nobody pushes to `main` directly.
- One fix or feature per pull request. It lands as a single squashed commit.
- Title in English, short and imperative: "Fix …", "Add …", "Keep …".
- A fix comes with a test that fails without it, unit or end-to-end.
- User-visible changes get an entry under `[Unreleased]` in
  [CHANGELOG.md](CHANGELOG.md), written for users, not as a commit log.
- Every UI text needs both languages, `.{ .de = …, .en = … }` (see
  `src/lang.zig`). If your German is shaky, say so and it gets polished in review.
- Match the surrounding style and do not reformat code you did not touch.
  Comments are in English. New source files start with the same SPDX and
  copyright header as the existing ones.

## License

By submitting a pull request you agree that your contribution is licensed under
the GNU GPL v3.0 or later, with the additional terms in [NOTICE.md](NOTICE.md).
