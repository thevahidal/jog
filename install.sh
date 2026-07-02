#!/bin/sh
# jog installer for macOS and Linux.
#   curl -fsSL https://raw.githubusercontent.com/thevahidal/jog/master/install.sh | sh
#
# Downloads the right prebuilt binary from the latest GitHub release. Override the
# install dir with JOG_INSTALL_DIR (default ~/.local/bin).
set -eu

REPO="thevahidal/jog"

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
    Darwin) o="macos" ;;
    Linux)  o="linux" ;;
    *) echo "jog: unsupported OS '$os'. On Windows, use WSL or install.ps1." >&2; exit 1 ;;
esac

case "$arch" in
    arm64|aarch64) a="aarch64" ;;
    x86_64|amd64)  a="x86_64" ;;
    *) echo "jog: unsupported architecture '$arch'." >&2; exit 1 ;;
esac

asset="jog-${a}-${o}"
url="https://github.com/${REPO}/releases/latest/download/${asset}"
dir="${JOG_INSTALL_DIR:-$HOME/.local/bin}"

echo "jog: downloading ${asset}…"
mkdir -p "$dir"
if ! curl -fSL "$url" -o "$dir/jog"; then
    echo "jog: download failed. No release yet? Build from source with: zig build" >&2
    exit 1
fi
chmod +x "$dir/jog"

echo "jog: installed to $dir/jog"
case ":$PATH:" in
    *":$dir:"*) ;;
    *) echo "jog: add it to your PATH →  export PATH=\"$dir:\$PATH\"" ;;
esac
echo "jog: run 'jog' to get started (and 'jog shell-init zsh' for the cd pop-up)."
