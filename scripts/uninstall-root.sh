#!/usr/bin/bash
set -euo pipefail
# Privileged uninstaller for the FHS desktop App.
# Intended to be run via pkexec: pkexec scripts/uninstall-root.sh

rm -rf /opt/antigravity
rm -f /usr/local/bin/antigravity
rm -f /usr/local/share/applications/antigravity.desktop
rm -f /usr/local/share/icons/hicolor/*/apps/antigravity.png

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/local/share/applications 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/local/share/icons/hicolor 2>/dev/null || true
fi
if command -v xdg-desktop-menu >/dev/null 2>&1; then
  xdg-desktop-menu forceupdate 2>/dev/null || true
fi
if command -v kbuildsycoca6 >/dev/null 2>&1; then
  kbuildsycoca6 2>/dev/null || true
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
  kbuildsycoca5 2>/dev/null || true
fi

echo "Desktop App removed from /opt and /usr/local."
