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
  status              Print local/remote App + CLI + plugin versions (text)
  status-json         Same as status, machine-readable JSON on stdout
  check               Exit 0 if up to date, 100 if updates available
  update-app          Download and install desktop App to /opt
  update-cli          Update agy via official install.sh
  update-plugin       Update this plugin from GitHub (xxxizum1kxxx/agy-linux-live-update)
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

  # Skip CLI remote probe when out of scope, or when CLI is not installed
  # (unless the user passed --cli explicitly).
  CLI_TRACKED=0
  CLI_REMOTE=""
  CLI_NEEDS=0
  if [ "$SCOPE_CLI" -eq 1 ] && { [ -n "$CLI_LOCAL" ] || [ "$EXPLICIT_SCOPE" -eq 1 ]; }; then
    CLI_TRACKED=1
    CLI_REMOTE=$(latest_cli_version || true)
    if [ -n "$CLI_REMOTE" ] && { [ -z "$CLI_LOCAL" ] || version_gt "$CLI_REMOTE" "$CLI_LOCAL"; }; then
      CLI_NEEDS=1
    fi
  fi

  APP_NEEDS=0
  if [ "$APP_LOCAL_BUILD" != "$APP_REMOTE_BUILD" ]; then
    APP_NEEDS=1
  fi

  PLUGIN_LOCAL_VER=$(local_plugin_version || true)
  PLUGIN_LOCAL_SHA=$(local_plugin_commit || true)
  PLUGIN_REMOTE_VER=$(remote_plugin_version || true)
  PLUGIN_REMOTE_SHA=$(remote_plugin_commit || true)
  PLUGIN_NEEDS=0
  PLUGIN_LOCAL_AHEAD=0
  if [ -n "$PLUGIN_REMOTE_VER" ] && [ -n "$PLUGIN_LOCAL_VER" ]; then
    if version_gt "$PLUGIN_REMOTE_VER" "$PLUGIN_LOCAL_VER"; then
      PLUGIN_NEEDS=1
    elif version_gt "$PLUGIN_LOCAL_VER" "$PLUGIN_REMOTE_VER"; then
      PLUGIN_LOCAL_AHEAD=1
    elif [ -n "$PLUGIN_REMOTE_SHA" ] && [ -n "$PLUGIN_LOCAL_SHA" ] \
      && [ "$PLUGIN_REMOTE_SHA" != "$PLUGIN_LOCAL_SHA" ] \
      && version_ge "$PLUGIN_REMOTE_VER" "$PLUGIN_LOCAL_VER"; then
      # Same version string, different commit on GitHub (docs/fix without bump).
      PLUGIN_NEEDS=1
    fi
  elif [ -n "$PLUGIN_REMOTE_VER" ] && [ -z "$PLUGIN_LOCAL_VER" ]; then
    PLUGIN_NEEDS=1
  fi
}

print_status_text() {
  echo "=== agy-linux-live-update ==="
  echo "plugin: $PLUGIN_ROOT"
  echo "arch : $(uname -m) ($REL_ARCH)"
  echo "App : local ${APP_LOCAL_VER:-?} (${APP_LOCAL_BUILD:-no build-id})  →  remote ${APP_REMOTE_VER} (${APP_REMOTE_BUILD})"
  if [ "$CLI_TRACKED" -eq 1 ]; then
    echo "CLI : local ${CLI_LOCAL:-?}  →  remote ${CLI_REMOTE:-?}"
  else
    echo "CLI : not installed (skipped)"
  fi
  echo "Plugin : local ${PLUGIN_LOCAL_VER:-?} (${PLUGIN_LOCAL_SHA:-no sha})  →  GitHub ${PLUGIN_REMOTE_VER:-?} (${PLUGIN_REMOTE_SHA:-?}) [$GITHUB_REPO@$GITHUB_BRANCH]"
  if [ "$APP_NEEDS" -eq 1 ]; then
    echo "App update available."
  else
    echo "App up to date."
  fi
  if [ "$CLI_TRACKED" -eq 0 ]; then
    echo "CLI not tracked."
  elif [ "$CLI_NEEDS" -eq 1 ]; then
    echo "CLI update available."
  else
    echo "CLI up to date (or remote unknown)."
  fi
  if [ "$PLUGIN_NEEDS" -eq 1 ]; then
    echo "Plugin update available."
  elif [ "$PLUGIN_LOCAL_AHEAD" -eq 1 ]; then
    echo "Plugin local version is ahead of GitHub."
  else
    echo "Plugin up to date (or remote unknown)."
  fi
}

print_status_json() {
  python3 - \
    "$APP_LOCAL_VER" "$APP_LOCAL_BUILD" "$APP_REMOTE_VER" "$APP_REMOTE_BUILD" "$APP_REMOTE_URL" \
    "$CLI_LOCAL" "$CLI_REMOTE" "$APP_NEEDS" "$CLI_NEEDS" "$CLI_TRACKED" \
    "$PLUGIN_LOCAL_VER" "$PLUGIN_REMOTE_VER" "$PLUGIN_LOCAL_SHA" "$PLUGIN_REMOTE_SHA" \
    "$PLUGIN_NEEDS" "$PLUGIN_LOCAL_AHEAD" "$GITHUB_REPO" "$GITHUB_BRANCH" <<'PY'
import json, sys
(
    app_local_ver, app_local_build, app_remote_ver, app_remote_build, app_remote_url,
    cli_local, cli_remote, app_needs, cli_needs, cli_tracked,
    plugin_local_ver, plugin_remote_ver, plugin_local_sha, plugin_remote_sha,
    plugin_needs, plugin_local_ahead, github_repo, github_branch,
) = sys.argv[1:19]
tracked = cli_tracked == "1"
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
        "tracked": tracked,
        "localVersion": cli_local or None,
        "remoteVersion": (cli_remote or None) if tracked else None,
        "updateAvailable": tracked and cli_needs == "1",
    },
    "plugin": {
        "localVersion": plugin_local_ver or None,
        "remoteVersion": plugin_remote_ver or None,
        "localCommit": plugin_local_sha or None,
        "remoteCommit": plugin_remote_sha or None,
        "repo": github_repo or None,
        "branch": github_branch or None,
        "updateAvailable": plugin_needs == "1",
        "localAhead": plugin_local_ahead == "1",
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
  # Always probe CLI remote for install/update, even if not currently installed.
  EXPLICIT_SCOPE=1
  SCOPE_CLI=1
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
  local before=${CLI_LOCAL:-}
  install_official_cli
  local after
  after=$(installed_cli_version || true)
  echo "CLI now: ${after:-not installed}"
  if [ -z "$after" ] || { [ -n "$before" ] && ! version_gt "$after" "$before"; }; then
    echo "CLI version did not change (${before:-none} → ${after:-none}); expected $CLI_REMOTE" >&2
    return 1
  fi
}

do_update_plugin() {
  gather_status
  if [ "$PLUGIN_NEEDS" -ne 1 ]; then
    if [ "$PLUGIN_LOCAL_AHEAD" -eq 1 ]; then
      echo "Plugin local ${PLUGIN_LOCAL_VER} is ahead of GitHub ${PLUGIN_REMOTE_VER}; skip."
    else
      echo "Plugin already at ${PLUGIN_LOCAL_VER:-?} (GitHub ${PLUGIN_REMOTE_VER:-?})"
    fi
    return 0
  fi
  if ! confirm "Update plugin ${PLUGIN_LOCAL_VER:-?} → ${PLUGIN_REMOTE_VER:-?} from GitHub (${GITHUB_REPO}@${GITHUB_BRANCH})?"; then
    echo "Skipped plugin update."
    return 0
  fi
  update_this_plugin_from_github
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
    if [ "$PLUGIN_NEEDS" -eq 1 ]; then need=1; fi
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
  update-plugin)
    do_update_plugin
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
