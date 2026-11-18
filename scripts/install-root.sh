#!/usr/bin/bash
set -euo pipefail
# Privileged installer. Usage: install-root.sh <tarball> <build-id>
# Intended to be run via pkexec.

TARBALL=${1:?tarball required}
BUILD_ID=${2:?build-id required}
STAGE=$(mktemp -d /tmp/antigravity-stage.XXXXXX)
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

ICON_SIZES=(16 24 32 48 64 128 256 512)

tar -xzf "$TARBALL" -C "$STAGE"
SRC=$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | head -n1)
test -n "$SRC"
test -x "$SRC/antigravity"

rm -rf /opt/antigravity
mv "$SRC" /opt/antigravity
chmod 755 /opt/antigravity/antigravity

if [ -f /opt/antigravity/chrome-sandbox ]; then
  chown root:root /opt/antigravity/chrome-sandbox
  chmod 4755 /opt/antigravity/chrome-sandbox
fi

printf '%s\n' "$BUILD_ID" >/opt/antigravity/.build-id

mkdir -p /usr/local/bin
ln -sfn /opt/antigravity/antigravity /usr/local/bin/antigravity

mkdir -p /usr/local/share/applications
cat >/usr/local/share/applications/antigravity.desktop <<'DESK'
[Desktop Entry]
Version=1.0
Type=Application
Name=Antigravity
GenericName=AI Agent Workbench
Comment=Google Antigravity
Exec=/opt/antigravity/antigravity %U
Icon=antigravity
Terminal=false
StartupNotify=true
StartupWMClass=Antigravity
Categories=Development;IDE;
Keywords=antigravity;google;ai;agent;gemini;
MimeType=x-scheme-handler/antigravity;
DESK

ICON_SRC=""
for candidate in \
  /opt/antigravity/antigravity.png \
  /opt/antigravity/resources/app/resources/linux/code.png \
  /opt/antigravity/resources/app/resources/linux/antigravity.png; do
  if [ -f "$candidate" ]; then
    ICON_SRC=$candidate
    break
  fi
done

if [ -n "$ICON_SRC" ]; then
  RESIZE_CMD=""
  if command -v magick >/dev/null 2>&1; then
    RESIZE_CMD="magick"
  elif command -v convert >/dev/null 2>&1; then
    RESIZE_CMD="convert"
  fi

  for size in "${ICON_SIZES[@]}"; do
    dest_dir=/usr/local/share/icons/hicolor/${size}x${size}/apps
    mkdir -p "$dest_dir"
    dest="$dest_dir/antigravity.png"
    if [ -n "$RESIZE_CMD" ]; then
      # Always resize to the target slot size (never drop a 512px file into 256x256).
      "$RESIZE_CMD" "$ICON_SRC" -resize "${size}x${size}" "$dest"
    else
      # Fallback without ImageMagick: only exact-size copy when source matches.
      # For other sizes, copy the source anyway so an icon exists (best-effort).
      cp -f "$ICON_SRC" "$dest"
    fi
  done
else
  echo "warning: no icon source found under /opt/antigravity; skipping icon install" >&2
fi

# Refresh desktop / icon caches (best-effort; GNOME, KDE, XFCE).
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/local/share/applications >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/local/share/icons/hicolor >/dev/null 2>&1 || true
fi
if command -v xdg-desktop-menu >/dev/null 2>&1; then
  xdg-desktop-menu forceupdate >/dev/null 2>&1 || true
fi
if command -v kbuildsycoca6 >/dev/null 2>&1; then
  kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
  kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
fi

echo "Installed build $BUILD_ID -> /opt/antigravity"
