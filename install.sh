#!/usr/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# When run as root install entrypoint living next to scripts/
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
Usage: install.sh [options]

Install / refresh the Antigravity Linux desktop App (FHS layout under /opt),
optionally the official agy CLI, and this updater plugin.

Run as your regular user (do not use sudo): --app elevates automatically via
pkexec for /opt and /usr/local, while --cli and --plugin install under $HOME.

Options:
  --app           Install/update desktop App (default if no flags)
  --cli           Install/update agy via official install.sh
  --plugin        Install this plugin + enable sidecar in ~/.gemini/config
  --yes, -y       Non-interactive confirmations (pkexec still prompts)
  --check         Only print local/remote versions; do not install
  -h, --help      Show help

Examples:
  ./install.sh                  # App only
  ./install.sh --app --cli      # App + CLI
  ./install.sh --plugin         # plugin + sidecar enable
  ./install.sh --app --cli --plugin --yes
U
}

DO_APP=0
DO_CLI=0
DO_PLUGIN=0
ASSUME_YES=0
DO_CHECK=0
EXPLICIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) DO_APP=1; EXPLICIT=1 ;;
    --cli) DO_CLI=1; EXPLICIT=1 ;;
    --plugin) DO_PLUGIN=1; EXPLICIT=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --check) DO_CHECK=1 ;;
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

require_non_root "install.sh"

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

echo "=== agy-linux-live-update installer ==="
echo "arch: $(uname -m) → $REL_ARCH"
echo "plugin root: $PLUGIN_ROOT"

read -r APP_REMOTE_BUILD APP_REMOTE_URL < <(latest_from_download_page)
APP_REMOTE_VER=${APP_REMOTE_BUILD%%-*}
APP_LOCAL_BUILD=$(installed_build_id || true)
APP_LOCAL_VER=$(installed_app_version || true)
CLI_LOCAL=$(installed_cli_version || true)
CLI_REMOTE=$(latest_cli_version || true)

echo "App : local ${APP_LOCAL_VER:-?} (${APP_LOCAL_BUILD:-no build-id})  →  remote ${APP_REMOTE_VER} (${APP_REMOTE_BUILD})"
echo "CLI : local ${CLI_LOCAL:-?}  →  remote ${CLI_REMOTE:-?}"

if [ "$DO_CHECK" -eq 1 ]; then
  exit 0
fi

if [ "$DO_APP" -eq 1 ]; then
  if [ "$APP_LOCAL_BUILD" = "$APP_REMOTE_BUILD" ]; then
    echo "App already at $APP_REMOTE_BUILD"
  else
    if confirm "Install App $APP_REMOTE_BUILD to /opt/antigravity (pkexec)?"; then
      TARBALL=$(download_app_tarball "$APP_REMOTE_BUILD" "$APP_REMOTE_URL")
      install_app_from_tarball "$TARBALL" "$APP_REMOTE_BUILD"
      echo "App installed. Launch with: antigravity"
    else
      echo "Skipped App install."
    fi
  fi
fi

if [ "$DO_CLI" -eq 1 ]; then
  if [ -n "$CLI_REMOTE" ] && [ -n "$CLI_LOCAL" ] && ! version_gt "$CLI_REMOTE" "$CLI_LOCAL"; then
    echo "CLI already at $CLI_LOCAL"
  else
    if confirm "Install/update CLI (agy) via official install.sh?"; then
      install_official_cli
      echo "CLI now: $(installed_cli_version || true)"
    else
      echo "Skipped CLI install."
    fi
  fi
fi

if [ "$DO_PLUGIN" -eq 1 ]; then
  if confirm "Install plugin $PLUGIN_NAME and enable sidecar?"; then
    install_this_plugin
    echo "Plugin installed. Restart Antigravity, then open Extensions → Linux Updater."
  else
    echo "Skipped plugin install."
  fi
fi

# Always refresh the user wrapper so PATH helpers find the renamed plugin.
mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/update-antigravity" <<'WRAP'
#!/usr/bin/bash
set -euo pipefail

resolve_core() {
  local candidates=(
    "${HOME}/.gemini/config/plugins/agy-linux-live-update/scripts/update-core.sh"
    "${HOME}/tools/agy-linux-live-update/scripts/update-core.sh"
    "${HOME}/.gemini/config/plugins/linux-updater/scripts/update-core.sh"
  )
  local p
  for p in "${candidates[@]}"; do
    if [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

CORE=$(resolve_core) || {
  echo "agy-linux-live-update plugin scripts not found. Install with: ./install.sh --plugin" >&2
  exit 1
}

DO_CHECK=0
DO_APP=0
DO_CLI=0
ASSUME_YES=0
EXPLICIT=0
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --check) DO_CHECK=1 ;;
    --app) DO_APP=1; EXPLICIT=1 ;;
    --cli) DO_CLI=1; EXPLICIT=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help)
      exec "$CORE" --help
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: update-antigravity [--check] [--app] [--cli] [--yes]" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$ASSUME_YES" -eq 1 ]; then
  ARGS+=(--yes)
fi
if [ "$EXPLICIT" -eq 1 ]; then
  if [ "$DO_APP" -eq 1 ]; then ARGS+=(--app); fi
  if [ "$DO_CLI" -eq 1 ]; then ARGS+=(--cli); fi
fi

if [ "$DO_CHECK" -eq 1 ]; then
  exec "$CORE" check "${ARGS[@]}"
fi

if [ "$EXPLICIT" -eq 0 ]; then
  exec "$CORE" update "${ARGS[@]}"
fi

if [ "$DO_APP" -eq 1 ] && [ "$DO_CLI" -eq 1 ]; then
  exec "$CORE" update "${ARGS[@]}"
elif [ "$DO_APP" -eq 1 ]; then
  exec "$CORE" update-app "${ARGS[@]}"
else
  exec "$CORE" update-cli "${ARGS[@]}"
fi
WRAP
chmod +x "$HOME/.local/bin/update-antigravity"

echo "Done."
