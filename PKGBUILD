# Build and install from this folder:  makepkg -si
pkgname=iro
pkgver=0.3.0
pkgrel=1
pkgdesc="A modeless terminal editor that looks good and never loses your work"
arch=('x86_64')
url="https://github.com/mantantis/iro"
license=('GPL-3.0-or-later')
depends=('lua54' 'glibc')
makedepends=('zig>=0.17' 'zig<0.18')
optdepends=('wl-clipboard: system clipboard'
            'glib2: trash in the file tree'
            'zoxide: folder jumps with Alt+Z'
            'git: git gutter'
            'ttf-jetbrains-mono-nerd: icons'
            'kitty: logo on the start screen')

build() {
    cd "$startdir"
    zig build
}

check() {
    cd "$startdir"
    zig build test
}

package() {
    cd "$startdir"
    install -Dm755 zig-out/bin/iro "$pkgdir/usr/bin/iro"
    install -Dm644 README.md "$pkgdir/usr/share/doc/iro/README.md"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
    install -Dm644 NOTICE.md "$pkgdir/usr/share/licenses/$pkgname/NOTICE.md"
}
