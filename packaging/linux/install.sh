#!/bin/sh
# Installs gitbello for the current user: the app, its launcher and the
# `gitbello` command. `./install.sh --uninstall` removes it.
set -e
here=$(cd "$(dirname "$0")" && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
app=$data/gitbello/gitbello.x86_64
bin=$HOME/.local/bin/gitbello
desktop=$data/applications/gitbello.desktop
icon=$data/icons/hicolor/scalable/apps/gitbello.svg

if [ "$1" = "--uninstall" ]; then
	rm -rf "$data/gitbello"
	rm -f "$bin" "$desktop" "$icon"
else
	install -Dm755 "$here/gitbello.x86_64" "$app"
	# The native library goes next to the app, where it looks for it
	install -Dm755 "$here/libgitbello_gdext.so" "$(dirname "$app")/libgitbello_gdext.so"
	mkdir -p "$(dirname "$bin")"
	ln -sf "$app" "$bin"
	install -Dm644 "$here/gitbello.svg" "$icon"
	mkdir -p "$(dirname "$desktop")"
	sed "s|^Exec=gitbello|Exec=\"$app\"|" "$here/gitbello.desktop" > "$desktop"
fi

update-desktop-database "$data/applications" >/dev/null 2>&1 || true
gtk-update-icon-cache -q "$data/icons/hicolor" >/dev/null 2>&1 || true
if [ "$1" = "--uninstall" ]; then
	echo "gitbello was removed."
else
	echo "gitbello was installed. Run ./install.sh --uninstall to remove it."
	command -v git >/dev/null 2>&1 \
		|| echo "gitbello needs git 2.40 or newer: install it with your package manager."
fi
