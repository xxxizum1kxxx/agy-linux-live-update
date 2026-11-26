#!/usr/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -d "$SCRIPT_DIR/scripts" ]; then
  PLUGIN_ROOT=$SCRIPT_DIR
  # shellcheck source=scripts/common.sh
  source "$SCRIPT_DIR/scripts/common.sh"
else
  PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
  # shellcheck source=common.sh
  source "$SCRIPT_DIR/common.sh"
fi

usage() {
  cat <<'U'
Usage: uninstall.sh [options]

Remove what this project's install.sh put on the system.

Run as your regular user (do not use sudo): --app elevates automatically via
pkexec, while --cli and --plugin remove per-user files under $HOME.

Options:
  --app           Remove desktop App from /opt + /usr/local (default if no flags)
  --cli           Remove user-local agy CLI binary (~/.local/bin/agy)
  --plugin        Uninstall this plugin, disable sidecar, clear updater cache
  --all           Same as --app --cli --plugin
  --yes, -y       Non-interactive confirmations (pkexec still prompts for --app)
  -h, --help      Show help

Examples:
  ./uninstall.sh                     # App only
  ./uninstall.sh --plugin            # plugin + sidecar + update-antigravity
  ./uninstall.sh --all --yes         # App + CLI + plugin
U
}

DO_APP=0
DO_CLI=0
DO_PLUGIN=0
ASSUME_YES=0
EXPLICIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) DO_APP=1; EXPLICIT=1 ;;
    --cli) DO_CLI=1; EXPLICIT=1 ;;
    --plugin) DO_PLUGIN=1; EXPLICIT=1 ;;
    --all) DO_APP=1; DO_CLI=1; DO_PLUGIN=1; EXPLICIT=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

if [ "$EXPLICIT" -eq 0 ]; then
  DO_APP=1
fi

require_non_root "uninstall.sh"

confirm() {
  local msg=$1
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  read -r -p "$msg [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== agy-linux-live-update uninstaller ==="
echo "arch: $(uname -m) → $REL_ARCH"
echo "plugin root: $PLUGIN_ROOT"
echo "targets: app=$DO_APP cli=$DO_CLI plugin=$DO_PLUGIN"

if [ "$DO_APP" -eq 1 ]; then
  if [ -e /opt/antigravity ] || [ -e /usr/local/bin/antigravity ] || \
     [ -e /usr/local/share/applications/antigravity.desktop ]; then
    if confirm "Remove desktop App from /opt and /usr/local (pkexec)?"; then
      uninstall_desktop_app
    else
      echo "Skipped App uninstall."
    fi
  else
    echo "Desktop App not found under /opt or /usr/local."
  fi
fi

if [ "$DO_CLI" -eq 1 ]; then
  if confirm "Remove user-local agy CLI binary?"; then
    uninstall_official_cli
  else
    echo "Skipped CLI uninstall."
  fi
fi

if [ "$DO_PLUGIN" -eq 1 ]; then
  if confirm "Uninstall plugin $PLUGIN_NAME, disable sidecar, and clear updater cache?"; then
    uninstall_this_plugin
    echo "Plugin removed. Restart Antigravity if it is running."
  else
    echo "Skipped plugin uninstall."
  fi
fi

echo "Done."
