#!/usr/bin/bash
# Shared helpers for install.sh and update-core.sh.
# Sourced, not executed.

_COMMON_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Prefer caller-provided roots; otherwise derive from this file (scripts/).
SCRIPT_DIR=${SCRIPT_DIR:-$_COMMON_DIR}
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$_COMMON_DIR/.." && pwd)}

DOWNLOAD_PAGE='https://antigravity.google/download/'
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/antigravity"
INSTALL_ROOT_HELPER="$_COMMON_DIR/install-root.sh"
CURL_UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
CLI_INSTALL_URL='https://antigravity.google/cli/install.sh'
PLUGIN_NAME='agy-linux-live-update'

detect_rel_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64) printf '%s\n' linux-x64 ;;
    aarch64|arm64) printf '%s\n' linux-arm ;;
    *)
      echo "Unsupported arch: $arch" >&2
      return 1
      ;;
  esac
}

REL_ARCH=${REL_ARCH:-$(detect_rel_arch)}

curl_get() {
  curl -fsSL -A "$CURL_UA" "$@"
}

installed_app_version() {
  python3 - <<'PY' 2>/dev/null || true
import struct, json, sys
p = "/opt/antigravity/resources/app.asar"
try:
    with open(p, "rb") as f:
        raw = f.read()
except FileNotFoundError:
    sys.exit(0)
chunk = raw[16:]
depth = 0
in_str = esc = False
end = None
for i, c in enumerate(chunk):
    ch = chr(c)
    if in_str:
        if esc:
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == '"':
            in_str = False
        continue
    if ch == '"':
        in_str = True
    elif ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
header = json.loads(chunk[:end].decode())
base = 16 + struct.unpack_from("<I", raw, 12)[0]
meta = header["files"]["package.json"]
data = raw[base + int(meta["offset"]) : base + int(meta["offset"]) + int(meta["size"])]
print(json.loads(data)["version"])
PY
}

installed_build_id() {
  if [ -f /opt/antigravity/.build-id ]; then
    tr -d '\n' </opt/antigravity/.build-id
  fi
}

latest_from_download_page() {
  local html build url
  html=$(curl_get "$DOWNLOAD_PAGE")
  build=$(printf '%s' "$html" | grep -oE "antigravity-hub/[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/${REL_ARCH}/Antigravity\.tar\.gz" | head -n1 | cut -d/ -f2)
  if [ -z "$build" ]; then
    echo "Could not parse latest App build from download page" >&2
    return 1
  fi
  url="https://storage.googleapis.com/antigravity-public/antigravity-hub/${build}/${REL_ARCH}/Antigravity.tar.gz"
  printf '%s %s\n' "$build" "$url"
}

installed_cli_version() {
  if command -v agy >/dev/null 2>&1; then
    agy --version 2>/dev/null | head -n1 | tr -d '\r'
  fi
}

latest_cli_version() {
  curl_get "$DOWNLOAD_PAGE" | python3 -c '
import sys, re
html = sys.stdin.read()
m = re.search(r"title=\"View Antigravity CLI Changelog\">v(\d+\.\d+\.\d+)", html)
print(m.group(1) if m else "")
'
}

version_gt() {
  python3 - "$1" "$2" <<'PY'
import sys

def parse(v: str):
    return tuple(int(x) for x in v.split(".")[:3])

a, b = sys.argv[1], sys.argv[2]
try:
    sys.exit(0 if parse(a) > parse(b) else 1)
except Exception:
    sys.exit(1)
PY
}

download_app_tarball() {
  local build=$1 url=$2
  local tarball="$CACHE_DIR/Antigravity-${build}.tar.gz"
  mkdir -p "$CACHE_DIR"
  echo "Downloading $url" >&2
  curl -fL -A "$CURL_UA" --progress-bar -o "$tarball.partial" "$url"
  mv "$tarball.partial" "$tarball"
  printf '%s\n' "$tarball"
}

install_app_from_tarball() {
  local tarball=$1 build=$2
  if ! command -v pkexec >/dev/null 2>&1; then
    echo "pkexec not found; cannot install system-wide to /opt" >&2
    return 1
  fi
  # Stop running app before replacing /opt (best-effort).
  pkill -f '/opt/antigravity/antigravity' 2>/dev/null || true
  sleep 1
  pkexec "$INSTALL_ROOT_HELPER" "$tarball" "$build"
}

install_official_cli() {
  curl -fsSL "$CLI_INSTALL_URL" | bash
}

install_this_plugin() {
  if ! command -v agy >/dev/null 2>&1; then
    echo "agy not found; install CLI first (pass --cli) then re-run with --plugin" >&2
    return 1
  fi
  agy plugin validate --strict "$PLUGIN_ROOT"
  # Replace any previous plugin id.
  agy plugin uninstall linux-updater >/dev/null 2>&1 || true
  agy plugin uninstall "$PLUGIN_NAME" >/dev/null 2>&1 || true
  agy plugin install "$PLUGIN_ROOT"
  enable_sidecar_config
}

enable_sidecar_config() {
  mkdir -p "$HOME/.gemini/config"
  python3 - <<'PY'
import json
from pathlib import Path

p = Path.home() / ".gemini/config/config.json"
cfg = {}
if p.exists():
    try:
        cfg = json.loads(p.read_text() or "{}")
    except json.JSONDecodeError:
        cfg = {}
sidecars = cfg.setdefault("sidecars", {})
# Migrate old key if present.
old = sidecars.pop("linux-updater/updater", None)
key = "agy-linux-live-update/updater"
entry = sidecars.get(key) or {}
if isinstance(old, dict):
    for k, v in old.items():
        entry.setdefault(k, v)
entry["enabled"] = True
sidecars[key] = entry
p.write_text(json.dumps(cfg, indent=2) + "\n")
print(f"enabled {key} in {p}")
PY
}
