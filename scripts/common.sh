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
GITHUB_REPO='xxxizum1kxxx/agy-linux-live-update'
GITHUB_BRANCH='main'

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

require_non_root() {
  if [ "$(id -u)" -eq 0 ]; then
    local cmd=${1:-$(basename "$0")}
    echo "Error: do not run $cmd as root or with sudo." >&2
    echo "  - Desktop App (--app) elevates automatically via pkexec for /opt and /usr/local." >&2
    echo "  - CLI (--cli), plugin (--plugin), cache, and wrapper files are per-user under \$HOME." >&2
    if [ -n "${SUDO_USER:-}" ]; then
      echo "Re-run as your regular user (${SUDO_USER}), without sudo." >&2
    else
      echo "Re-run as a regular non-root user." >&2
    fi
    return 1
  fi
}

curl_get() {
  curl -fsSL -A "$CURL_UA" "$@"
}

installed_app_version() {
  python3 - <<'PY' 2>/dev/null || true
import json, os, struct, sys

p = "/opt/antigravity/resources/app.asar"
try:
    with open(p, "rb") as f:
        prefix = f.read(16)
        if len(prefix) < 16:
            sys.exit(0)
        _, header_pickle_size, _, json_size = struct.unpack_from("<4I", prefix, 0)
        header = json.loads(f.read(json_size).decode("utf-8"))
        meta = header.get("files", {}).get("package.json")
        if not isinstance(meta, dict) or "size" not in meta:
            sys.exit(0)
        if meta.get("unpacked"):
            unpacked = os.path.join(p + ".unpacked", "package.json")
            if not os.path.isfile(unpacked):
                sys.exit(0)
            with open(unpacked, "rb") as uf:
                data = uf.read()
        else:
            f.seek(8 + header_pickle_size + int(meta["offset"]))
            data = f.read(int(meta["size"]))
except FileNotFoundError:
    sys.exit(0)
print(json.loads(data.decode("utf-8"))["version"])
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

resolve_agy_bin() {
  if command -v agy >/dev/null 2>&1; then
    command -v agy
    return 0
  fi
  if [ -x "$HOME/.local/bin/agy" ]; then
    printf '%s\n' "$HOME/.local/bin/agy"
    return 0
  fi
  return 1
}

installed_cli_version() {
  local agy_bin
  if agy_bin=$(resolve_agy_bin); then
    "$agy_bin" --version 2>/dev/null | head -n1 | tr -d '\r'
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

version_ge() {
  python3 - "$1" "$2" <<'PY'
import sys

def parse(v: str):
    return tuple(int(x) for x in v.split(".")[:3])

a, b = sys.argv[1], sys.argv[2]
try:
    sys.exit(0 if parse(a) >= parse(b) else 1)
except Exception:
    sys.exit(1)
PY
}

local_plugin_version() {
  python3 - "$PLUGIN_ROOT/plugin.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("version") or "")
PY
}

local_plugin_commit() {
  if [ -d "$PLUGIN_ROOT/.git" ] && command -v git >/dev/null 2>&1; then
    git -C "$PLUGIN_ROOT" rev-parse --short HEAD 2>/dev/null || true
  fi
}

# Full SHA of the branch head. api.github.com is not CDN-cached like
# raw.githubusercontent.com (max-age=300 on branch URLs).
remote_plugin_commit_full() {
  curl_get \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${GITHUB_REPO}/commits/${GITHUB_BRANCH}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha") or "")'
}

remote_plugin_commit() {
  local sha
  sha=$(remote_plugin_commit_full) || return 1
  printf '%s\n' "${sha:0:7}"
}

# Read plugin.json at an exact commit (immutable, so never stale). Falls back
# to the branch URL only if the commit could not be resolved.
remote_plugin_version() {
  local ref=${1:-}
  if [ -z "$ref" ]; then
    ref=$(remote_plugin_commit_full || true)
  fi
  curl_get "https://raw.githubusercontent.com/${GITHUB_REPO}/${ref:-$GITHUB_BRANCH}/plugin.json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version") or "")'
}

install_plugin_from_dir() {
  local src=$1 agy_bin
  if ! agy_bin=$(resolve_agy_bin); then
    echo "agy not found; cannot reinstall plugin" >&2
    return 1
  fi
  "$agy_bin" plugin validate --strict "$src"
  # Only remove the legacy plugin id. Never uninstall ourselves first:
  # `agy plugin install` replaces an existing installation in place, while
  # uninstalling makes Antigravity stop this plugin's Sidecar — and with it
  # the process running this very update — leaving the plugin removed.
  "$agy_bin" plugin uninstall linux-updater >/dev/null 2>&1 || true
  "$agy_bin" plugin install "$src"
  # Re-source PLUGIN_ROOT after install if we updated from a temp tree.
  if [ -d "$HOME/.gemini/config/plugins/$PLUGIN_NAME" ]; then
    PLUGIN_ROOT="$HOME/.gemini/config/plugins/$PLUGIN_NAME"
  fi
  enable_sidecar_config
}

update_this_plugin_from_github() {
  local stage tarball remote_sha ref
  mkdir -p "$CACHE_DIR"
  stage=$(mktemp -d "$CACHE_DIR/plugin-update.XXXXXX")
  tarball="$stage/plugin.tar.gz"
  # Download the exact head commit so we install what the status check saw.
  remote_sha=$(remote_plugin_commit_full || true)
  ref=${remote_sha:-refs/heads/${GITHUB_BRANCH}}
  echo "Downloading github.com/${GITHUB_REPO}@${remote_sha:0:7}${remote_sha:+ }(${GITHUB_BRANCH})" >&2
  curl_get -o "$tarball" \
    "https://codeload.github.com/${GITHUB_REPO}/tar.gz/${ref}"
  tar -xzf "$tarball" -C "$stage"
  local src
  src=$(find "$stage" -mindepth 1 -maxdepth 1 -type d | head -n1)
  test -n "$src"
  test -f "$src/plugin.json"
  chmod +x "$src"/install.sh "$src"/uninstall.sh "$src"/scripts/*.sh "$src"/bin/* 2>/dev/null || true
  install_plugin_from_dir "$src"
  rm -rf "$stage"
  echo "Plugin updated from GitHub (${GITHUB_BRANCH}${remote_sha:+ @ ${remote_sha:0:7}}). Restart Antigravity to reload the Sidecar."
}

download_app_tarball() {
  local build=$1 url=$2
  local tarball="$CACHE_DIR/Antigravity-${build}.tar.gz"
  mkdir -p "$CACHE_DIR"
  if [ -f "$tarball" ] && [ -s "$tarball" ]; then
    echo "Using cached tarball: $tarball" >&2
    printf '%s\n' "$tarball"
    return 0
  fi
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
  local agy_bin
  if agy_bin=$(resolve_agy_bin); then
    # The official install.sh exits 0 without doing anything when agy already
    # exists ("already installed"), so use the CLI's built-in updater instead.
    "$agy_bin" update </dev/null
  else
    curl -fsSL "$CLI_INSTALL_URL" | bash
  fi
}

install_this_plugin() {
  local agy_bin
  if ! agy_bin=$(resolve_agy_bin); then
    echo "Error: agy CLI is not installed; cannot install plugin without agy." >&2
    echo "Install CLI first (./install.sh --cli) or run ./install.sh --cli --plugin." >&2
    return 1
  fi
  "$agy_bin" plugin validate --strict "$PLUGIN_ROOT"
  # Replace the legacy plugin id; `agy plugin install` replaces ours in place.
  "$agy_bin" plugin uninstall linux-updater >/dev/null 2>&1 || true
  "$agy_bin" plugin install "$PLUGIN_ROOT"
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

disable_sidecar_config() {
  mkdir -p "$HOME/.gemini/config"
  python3 - <<'PY'
import json
from pathlib import Path

p = Path.home() / ".gemini/config/config.json"
if not p.exists():
    print(f"no config at {p}")
    raise SystemExit(0)
try:
    cfg = json.loads(p.read_text() or "{}")
except json.JSONDecodeError:
    print(f"skipping unreadable {p}")
    raise SystemExit(0)
sidecars = cfg.get("sidecars")
if not isinstance(sidecars, dict):
    print(f"no sidecars block in {p}")
    raise SystemExit(0)
removed = []
for key in ("agy-linux-live-update/updater", "linux-updater/updater"):
    if key in sidecars:
        sidecars.pop(key, None)
        removed.append(key)
p.write_text(json.dumps(cfg, indent=2) + "\n")
if removed:
    print(f"removed sidecar keys {', '.join(removed)} from {p}")
else:
    print(f"no updater sidecar keys in {p}")
PY
}

uninstall_this_plugin() {
  local agy_bin
  if agy_bin=$(resolve_agy_bin); then
    "$agy_bin" plugin uninstall linux-updater >/dev/null 2>&1 || true
    "$agy_bin" plugin uninstall "$PLUGIN_NAME" >/dev/null 2>&1 || true
  else
    echo "agy not found; removing plugin directory if present"
    rm -rf "$HOME/.gemini/config/plugins/$PLUGIN_NAME"
    rm -rf "$HOME/.gemini/config/plugins/linux-updater"
  fi
  disable_sidecar_config
  # Sidecar runtime cache / settings
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/antigravity/linux-updater"
  rm -rf "$HOME/.gemini/antigravity/sidecar_data/agy-linux-live-update"
  rm -rf "$HOME/.gemini/antigravity/sidecar_data/linux-updater"
  rm -f "$HOME/.local/bin/update-antigravity"
}

uninstall_desktop_app() {
  local helper="$_COMMON_DIR/uninstall-root.sh"
  if ! command -v pkexec >/dev/null 2>&1; then
    echo "pkexec not found; cannot remove system files under /opt and /usr/local" >&2
    return 1
  fi
  # Best-effort stop before deleting /opt.
  pkill -f '/opt/antigravity/antigravity' 2>/dev/null || true
  sleep 1
  pkexec bash "$helper"
}

uninstall_official_cli() {
  # Official install.sh typically places `agy` on the user PATH.
  # Leave ~/.gemini/antigravity-cli config data in place (user settings).
  local removed=0
  if [ -e "$HOME/.local/bin/agy" ] || [ -L "$HOME/.local/bin/agy" ]; then
    rm -f "$HOME/.local/bin/agy"
    echo "removed $HOME/.local/bin/agy"
    removed=1
  fi
  if command -v agy >/dev/null 2>&1; then
    local agy_path
    agy_path=$(command -v agy)
    case "$agy_path" in
      "$HOME"/*)
        rm -f "$agy_path"
        echo "removed $agy_path"
        removed=1
        ;;
      *)
        echo "agy still on PATH at $agy_path (not under \$HOME); remove manually if desired" >&2
        ;;
    esac
  fi
  if [ "$removed" -eq 0 ]; then
    echo "No user-local agy binary found"
  fi
}
