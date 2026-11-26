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
chmod 644 /usr/local/share/applications/antigravity.desktop

extract_icon_from_asar() {
  local asar=$1 out=$2
  [ -f "$asar" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$asar" "$out" <<'PY'
import json, os, struct, sys

asar_path, out_path = sys.argv[1], sys.argv[2]
with open(asar_path, "rb") as f:
    prefix = f.read(16)
    if len(prefix) < 16:
        sys.exit(1)
    _, header_pickle_size, _, json_size = struct.unpack_from("<4I", prefix, 0)
    header = json.loads(f.read(json_size).decode("utf-8"))
    data_base = 8 + header_pickle_size

    candidates = [
        ("icon.png",),
        ("resources", "icon.png"),
        ("assets", "icon.png"),
    ]
    meta = None
    rel_parts = None
    for parts in candidates:
        node = header
        for part in parts:
            node = node.get("files", {}).get(part) if isinstance(node, dict) else None
            if node is None:
                break
        if isinstance(node, dict) and "size" in node:
            meta = node
            rel_parts = parts
            break

    if meta is None:
        sys.exit(1)

    if meta.get("unpacked"):
        unpacked = os.path.join(asar_path + ".unpacked", *rel_parts)
        with open(unpacked, "rb") as uf:
            data = uf.read()
    else:
        f.seek(data_base + int(meta["offset"]))
        data = f.read(int(meta["size"]))

if not data.startswith(b"\x89PNG\r\n\x1a\n"):
    sys.exit(1)

with open(out_path, "wb") as out:
    out.write(data)
PY
}

resize_icon_with_pil() {
  local src=$1 size=$2 dest=$3
  python3 - "$src" "$size" "$dest" <<'PY'
import sys
from PIL import Image

src, size, dest = sys.argv[1], int(sys.argv[2]), sys.argv[3]
resample = getattr(getattr(Image, "Resampling", Image), "LANCZOS")
with Image.open(src) as img:
    img.resize((size, size), resample).save(dest, format="PNG")
PY
}

ICON_SRC=""
for candidate in \
  /opt/antigravity/antigravity.png \
  /opt/antigravity/resources/app/resources/linux/antigravity.png \
  /opt/antigravity/resources/app/resources/linux/code.png; do
  if [ -f "$candidate" ]; then
    ICON_SRC=$candidate
    break
  fi
done

if [ -z "$ICON_SRC" ]; then
  if extract_icon_from_asar /opt/antigravity/resources/app.asar "$STAGE/icon.png"; then
    ICON_SRC="$STAGE/icon.png"
  fi
fi

if [ -n "$ICON_SRC" ]; then
  RESIZE_MODE="copy"
  if command -v magick >/dev/null 2>&1; then
    RESIZE_MODE="magick"
  elif command -v convert >/dev/null 2>&1; then
    RESIZE_MODE="convert"
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL.Image' >/dev/null 2>&1; then
    RESIZE_MODE="pil"
  fi

  for size in "${ICON_SIZES[@]}"; do
    dest_dir=/usr/local/share/icons/hicolor/${size}x${size}/apps
    mkdir -p "$dest_dir"
    dest="$dest_dir/antigravity.png"
    case "$RESIZE_MODE" in
      magick|convert)
        # Always resize to the target slot size (never drop a 512px file into 256x256).
        "$RESIZE_MODE" "$ICON_SRC" -resize "${size}x${size}" "$dest"
        ;;
      pil)
        resize_icon_with_pil "$ICON_SRC" "$size" "$dest"
        ;;
      *)
        # Fallback without ImageMagick or Pillow: copy the source so an icon exists.
        cp -f "$ICON_SRC" "$dest"
        ;;
    esac
    chmod 644 "$dest"
  done
else
  echo "warning: no icon source found under /opt/antigravity (or resources/app.asar); skipping icon install" >&2
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
