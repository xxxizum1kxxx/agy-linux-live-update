#!/usr/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'U'
Usage: update-core.sh <command> [options]

Commands:
  status              Print local/remote App + CLI versions (text)
  status-json         Same as status, machine-readable JSON on stdout
  check               Exit 0 if up to date, 100 if updates available
  update-app          Download and install desktop App to /opt
  update-cli          Update agy via official install.sh
  update              update-app and/or update-cli (see flags)

Options:
  --yes, -y           Non-interactive confirmations
  --app               With update/check: only App
  --cli               With update/check: only CLI
  -h, --help          Show help
U
}

ASSUME_YES=0
SCOPE_APP=1
SCOPE_CLI=1
EXPLICIT_SCOPE=0

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

gather_status() {
  APP_LOCAL_VER=$(installed_app_version || true)
  APP_LOCAL_BUILD=$(installed_build_id || true)
  read -r APP_REMOTE_BUILD APP_REMOTE_URL < <(latest_from_download_page)
  APP_REMOTE_VER=${APP_REMOTE_BUILD%%-*}
  CLI_LOCAL=$(installed_cli_version || true)
  CLI_REMOTE=$(latest_cli_version || true)

  APP_NEEDS=0
  CLI_NEEDS=0
  if [ "$APP_LOCAL_BUILD" != "$APP_REMOTE_BUILD" ]; then
    APP_NEEDS=1
  fi
  if [ -n "$CLI_REMOTE" ] && { [ -z "$CLI_LOCAL" ] || version_gt "$CLI_REMOTE" "$CLI_LOCAL"; }; then
    CLI_NEEDS=1
  fi
}

print_status_text() {
  echo "=== Linux Updater ==="
  echo "plugin: $PLUGIN_ROOT"
  echo "App : local ${APP_LOCAL_VER:-?} (${APP_LOCAL_BUILD:-no build-id})  →  remote ${APP_REMOTE_VER} (${APP_REMOTE_BUILD})"
  echo "CLI : local ${CLI_LOCAL:-?}  →  remote ${CLI_REMOTE:-?}"
  if [ "$APP_NEEDS" -eq 1 ]; then
    echo "App update available."
  else
    echo "App up to date."
  fi
  if [ "$CLI_NEEDS" -eq 1 ]; then
    echo "CLI update available."
  else
    echo "CLI up to date (or remote unknown)."
  fi
}

print_status_json() {
  python3 - "$APP_LOCAL_VER" "$APP_LOCAL_BUILD" "$APP_REMOTE_VER" "$APP_REMOTE_BUILD" "$APP_REMOTE_URL" "$CLI_LOCAL" "$CLI_REMOTE" "$APP_NEEDS" "$CLI_NEEDS" <<'PY'
import json, sys
(
    app_local_ver, app_local_build, app_remote_ver, app_remote_build, app_remote_url,
    cli_local, cli_remote, app_needs, cli_needs,
) = sys.argv[1:10]
print(json.dumps({
    "app": {
        "localVersion": app_local_ver or None,
        "localBuildId": app_local_build or None,
        "remoteVersion": app_remote_ver or None,
        "remoteBuildId": app_remote_build or None,
        "remoteUrl": app_remote_url or None,
        "updateAvailable": app_needs == "1",
    },
    "cli": {
        "localVersion": cli_local or None,
        "remoteVersion": cli_remote or None,
        "updateAvailable": cli_needs == "1",
    },
}, indent=2))
PY
}

do_update_app() {
  gather_status
  if [ "$APP_LOCAL_BUILD" = "$APP_REMOTE_BUILD" ]; then
    echo "App already at $APP_REMOTE_BUILD"
    return 0
  fi
  if ! confirm "Update App to $APP_REMOTE_BUILD? This will quit running Antigravity and prompt for pkexec."; then
    echo "Skipped App update."
    return 0
  fi
  TARBALL=$(download_app_tarball "$APP_REMOTE_BUILD" "$APP_REMOTE_URL")
  install_app_from_tarball "$TARBALL" "$APP_REMOTE_BUILD"
  echo "App updated. Relaunch Antigravity manually."
}

do_update_cli() {
  gather_status
  if [ -z "$CLI_REMOTE" ]; then
    echo "Could not determine remote CLI version; skip" >&2
    return 1
  fi
  if [ -n "$CLI_LOCAL" ] && ! version_gt "$CLI_REMOTE" "$CLI_LOCAL"; then
    echo "CLI already at $CLI_LOCAL (remote $CLI_REMOTE)"
    return 0
  fi
  if ! confirm "Update CLI (agy) ${CLI_LOCAL:-none} → $CLI_REMOTE via official install.sh?"; then
    echo "Skipped CLI update."
    return 0
  fi
  install_official_cli
  echo "CLI now: $(installed_cli_version)"
}

CMD=${1:-}
if [ -z "$CMD" ]; then
  usage
  exit 2
fi
shift || true

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --app) SCOPE_APP=1; SCOPE_CLI=0; EXPLICIT_SCOPE=1 ;;
    --cli) SCOPE_CLI=1; SCOPE_APP=0; EXPLICIT_SCOPE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [ "$EXPLICIT_SCOPE" -eq 0 ]; then
  SCOPE_APP=1
  SCOPE_CLI=1
fi

case "$CMD" in
  -h|--help) usage; exit 0 ;;
  status)
    gather_status
    print_status_text
    ;;
  status-json)
    gather_status
    print_status_json
    ;;
  check)
    gather_status
    print_status_text
    need=0
    if [ "$SCOPE_APP" -eq 1 ] && [ "$APP_NEEDS" -eq 1 ]; then need=1; fi
    if [ "$SCOPE_CLI" -eq 1 ] && [ "$CLI_NEEDS" -eq 1 ]; then need=1; fi
    if [ "$need" -eq 0 ]; then
      echo "Already up to date."
      exit 0
    fi
    echo "Updates available."
    exit 100
    ;;
  update-app)
    do_update_app
    ;;
  update-cli)
    do_update_cli
    ;;
  update)
    if [ "$SCOPE_APP" -eq 1 ]; then do_update_app; fi
    if [ "$SCOPE_CLI" -eq 1 ]; then do_update_cli; fi
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    usage
    exit 2
    ;;
esac
