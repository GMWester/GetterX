#!/bin/sh
# GetterX installer for Linux and macOS.
#   curl -fsSL https://github.com/gmwester/GetterX/releases/latest/download/getterx-install.sh | sh
# Choose "install" (normal) or "portable" (everything in one folder).
# Non-interactive: sh getterx-install.sh --install   |   sh getterx-install.sh --portable DIR
# 32-bit (x86 / ARM) and RISC-V systems get "GetterX Lite" (same features, runs in
# your web browser). Force Lite anywhere with GETTERX_LITE=1.
set -eu

REPO="gmwester/GetterX"
BASE="https://github.com/$REPO/releases/latest/download"
OS=$(uname -s)
ARCH=$(uname -m)

say() { printf '%s\n' "$*"; }
die() { say "Error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required"; }
need curl

MODE=""; DEST=""
case "${1:-}" in
  --install) MODE=install ;;
  --portable) MODE=portable; DEST="${2:-}" ;;
esac

if [ -z "$MODE" ]; then
  say "GetterX installer"
  say "  1) Install   (normal installation for your user)"
  say "  2) Portable  (one folder with the app, its settings and downloads)"
  printf 'Choose 1 or 2: '
  read -r choice </dev/tty
  case "$choice" in 2) MODE=portable ;; *) MODE=install ;; esac
fi
if [ "$MODE" = portable ] && [ -z "$DEST" ]; then
  printf 'Portable folder [%s]: ' "$HOME/GetterX-Portable"
  read -r DEST </dev/tty || true
  [ -n "$DEST" ] || DEST="$HOME/GetterX-Portable"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch() { # name -> $TMP/name, verified against the release's SHA256SUMS
  say "Downloading $1 ..."
  curl -fL --proto '=https' --tlsv1.2 -o "$TMP/$1" "$BASE/$1"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"
  expected=$(grep "  $1\$" "$TMP/SHA256SUMS" | cut -d' ' -f1)
  [ -n "$expected" ] || die "no checksum published for $1"
  if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$TMP/$1" | cut -d' ' -f1)
  else actual=$(shasum -a 256 "$TMP/$1" | cut -d' ' -f1); fi
  [ "$expected" = "$actual" ] || die "checksum mismatch for $1"
}

install_lite() { # $1 = asset name of the GetterX Lite build
  fetch "$1"
  case "$1" in
    *.tar.gz) mkdir -p "$TMP/l"; tar -xzf "$TMP/$1" -C "$TMP/l"; SRC="$TMP/l/GetterX-Lite" ;;
    *) mkdir -p "$TMP/l/GetterX-Lite"; cp "$TMP/$1" "$TMP/l/GetterX-Lite/getterx-cli"; chmod +x "$TMP/l/GetterX-Lite/getterx-cli"; SRC="$TMP/l/GetterX-Lite" ;;
  esac
  if [ "$MODE" = portable ]; then
    mkdir -p "$DEST"; cp -a "$SRC/." "$DEST/"; printf 'portable\n' > "$DEST/portable.txt"
    say "GetterX Lite (portable) is in $DEST. Start it with: $DEST/getterx-cli   (opens in your browser)"
  else
    TARGET="$HOME/.local/opt/GetterX-Lite"; mkdir -p "$TARGET" "$HOME/.local/bin"
    cp -a "$SRC/." "$TARGET/"; ln -sf "$TARGET/getterx-cli" "$HOME/.local/bin/getterx-cli"
    say "GetterX Lite installed. Start it with: getterx-cli   (opens in your browser)"
  fi
  say "GetterX Lite is the browser-based version for systems the desktop app does not support."
}

if [ "$OS" = Linux ]; then
  case "$ARCH" in
    x86_64|amd64) A=x64 ;;
    aarch64|arm64) A=arm64 ;;
    armv7*|armv6*|armhf|arm) install_lite getterx-cli-linux-arm; exit 0 ;;
    riscv64) install_lite getterx-cli-linux-riscv64; exit 0 ;;
    i386|i486|i586|i686|x86) install_lite GetterX-Lite-linux-x86.tar.gz; exit 0 ;;
    *) die "no build for $ARCH" ;;
  esac
  if [ "${GETTERX_LITE:-0}" = 1 ]; then install_lite "getterx-cli-linux-$A"; exit 0; fi
  fetch "GetterX-linux-$A-portable.tar.gz"
  mkdir -p "$TMP/x"; tar -xzf "$TMP/GetterX-linux-$A-portable.tar.gz" -C "$TMP/x"
  if [ "$MODE" = portable ]; then
    mkdir -p "$DEST"; cp -a "$TMP/x/GetterX/." "$DEST/"
    say "Portable GetterX is in $DEST  - run $DEST/getterx"
  else
    TARGET="$HOME/.local/opt/GetterX"
    mkdir -p "$TARGET" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
    cp -a "$TMP/x/GetterX/." "$TARGET/"
    rm -f "$TARGET/portable.txt"
    ln -sf "$TARGET/getterx" "$HOME/.local/bin/getterx"
    ln -sf "$TARGET/getterx-cli" "$HOME/.local/bin/getterx-cli"
    cp "$TARGET/data/flutter_assets/assets/icon.png" "$HOME/.local/share/icons/hicolor/256x256/apps/getterx.png" 2>/dev/null || true
    cat > "$HOME/.local/share/applications/getterx.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=GetterX
Comment=Automatic downloads from GitHub, Modrinth, CurseForge, itch.io and more
Exec=$TARGET/getterx
Icon=getterx
Categories=Utility;Network;
Terminal=false
DESK
    say "GetterX installed to $TARGET (menu entry + ~/.local/bin/getterx)"
  fi
elif [ "$OS" = Darwin ]; then
  MAJOR=$(sw_vers -productVersion | cut -d. -f1); MINOR=$(sw_vers -productVersion | cut -d. -f2)
  if [ "${GETTERX_LITE:-0}" = 1 ] || { [ "$MAJOR" -eq 10 ] && [ "$MINOR" -lt 15 ]; }; then
    case "$ARCH" in arm64) install_lite getterx-cli-macos-arm64 ;; *) install_lite getterx-cli-macos-x64 ;; esac
    exit 0
  fi
  if [ "$MODE" = portable ]; then
    fetch GetterX-macos-portable.zip
    mkdir -p "$DEST"; ditto -x -k "$TMP/GetterX-macos-portable.zip" "$TMP/x"
    ditto "$TMP/x/GetterX" "$DEST"
    say "Portable GetterX is in $DEST"
  else
    fetch GetterX-macos.zip
    ditto -x -k "$TMP/GetterX-macos.zip" "$TMP/x"
    TARGET=/Applications; [ -w "$TARGET" ] || TARGET="$HOME/Applications"
    mkdir -p "$TARGET"; rm -rf "$TARGET/GetterX.app"; ditto "$TMP/x/GetterX.app" "$TARGET/GetterX.app"
    say "GetterX installed to $TARGET/GetterX.app"
  fi
  say "The app is not notarized by Apple: on first launch right-click it and choose Open."
else
  die "unsupported system $OS (use the Windows installer or the Android/iOS packages)"
fi
