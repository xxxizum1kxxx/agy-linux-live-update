# Linux Updater (`agy-linux-live-update`)

Install, check, and update the [Google Antigravity](https://antigravity.google/download/) desktop App (`/opt`) and `agy` CLI on Linux, with an Antigravity plugin + Sidecar panel.

Compatible with **GNOME / KDE / XFCE** (`.desktop`, multi-size hicolor icons, desktop/icon cache refresh).

**中文：** 在 Linux 上安装 / 检查 / 更新 Google Antigravity 桌面 App（`/opt`）与 `agy` CLI，并提供 Antigravity 插件 + Sidecar 面板。兼容 GNOME / KDE / XFCE。

> The Sidecar UI is English-only. This README is English-first with Chinese summaries under each section.
>
> **中文：** Sidecar 面板仅英文。本文档以英文为主，各节附中文摘要。

## Quick install (desktop App)

```bash
git clone https://github.com/xxxizum1kxxx/agy-linux-live-update.git ~/tools/agy-linux-live-update
cd ~/tools/agy-linux-live-update
chmod +x install.sh uninstall.sh scripts/*.sh bin/update-antigravity
./install.sh --yes                # App only by default
```

Or from an existing checkout:

```bash
~/tools/agy-linux-live-update/install.sh --yes
```

Optional combinations (CLI / plugin need explicit flags; CLI is off by default):

```bash
./install.sh --app --cli --yes            # App + official CLI
./install.sh --app --cli --plugin --yes   # App + CLI + this plugin
./install.sh --check                      # Print local/remote versions only
./install.sh --plugin --yes               # Plugin + enable Sidecar
./install.sh --cli --yes                  # CLI only
```

Writes under `/opt` and `/usr/local` use **pkexec**.

**中文：** 克隆后运行 `./install.sh --yes` 默认只装桌面 App。加 `--cli` / `--plugin` 才装 CLI 或插件。写入 `/opt`、`/usr/local` 时会弹出 pkexec。

## What gets installed (FHS)

| Path | Purpose |
|------|---------|
| `/opt/antigravity` | Expanded official tarball |
| `/opt/antigravity/.build-id` | Remote build id (update checks) |
| `/opt/antigravity/chrome-sandbox` | setuid root (Electron sandbox) |
| `/usr/local/bin/antigravity` | Launcher symlink |
| `/usr/local/share/applications/antigravity.desktop` | Desktop entry |
| `/usr/local/share/icons/hicolor/*/apps/antigravity.png` | Multi-size icons |

After install the script refreshes `update-desktop-database`, `gtk-update-icon-cache`, `xdg-desktop-menu`, and `kbuildsycoca5|6` when present.

Arch detection: `x86_64` → `linux-x64`, `aarch64`/`arm64` → `linux-arm`. Download-page requests use a browser User-Agent to avoid some 403s.

**中文：** 安装到标准 FHS 路径；结束后尽量刷新桌面与图标缓存。架构自动识别；拉官网页面时使用浏览器 UA。

## Plugin / Sidecar

```bash
./install.sh --plugin --yes
# or
agy plugin validate --strict ~/tools/agy-linux-live-update
agy plugin install ~/tools/agy-linux-live-update
```

Enable the Sidecar (`install.sh --plugin` does this; or manually):

```bash
mkdir -p ~/.gemini/config
python3 - <<'PY'
import json
from pathlib import Path
p = Path.home() / ".gemini/config/config.json"
cfg = {}
if p.exists():
    cfg = json.loads(p.read_text() or "{}")
cfg.setdefault("sidecars", {})
cfg["sidecars"].pop("linux-updater/updater", None)
cfg["sidecars"]["agy-linux-live-update/updater"] = {"enabled": True}
p.write_text(json.dumps(cfg, indent=2) + "\n")
print("enabled agy-linux-live-update/updater in", p)
PY
```

Restart Antigravity, then open **Extensions → Linux Updater**.

Slash skills: `/check-updates`, `/update-app`, `/update-cli`.

**中文：** 安装并启用 Sidecar 后重启 Antigravity，从 Extensions → Linux Updater 打开面板。斜杠技能同上。

### Background check & desktop notifications

When the Sidecar process starts, it runs a quiet `status-json` check and may call:

```bash
notify-send --app-name="Linux Updater" …
```

Notes:

- Antigravity has **no** Sidecar API for host/in-app notification badges. Desktop alerts use **`notify-send`** (libnotify), not the App’s agent Notifications settings.
- Needs a running notification daemon (GNOME/KDE/XFCE usually provide one). If `notify-send` is missing or fails, checks still work; only the toast is skipped.
- Desktop notifications use app name **Antigravity Linux Updater** and the Antigravity PNG icon when available.
- Panel toggle **Notify on every startup**:
  - **Off** (default): notify only when updates are available (same fingerprint is not notified twice).
  - **On**: always notify at startup with either “Updates available” or “Up to date”.
- Manual **Check** in the panel never sends a desktop notification.
- If the `agy` CLI is not installed, CLI status/update is skipped (App-only). Pass `--cli` to `update-core.sh` / `update-antigravity` to force a CLI probe (e.g. to install).
- The panel can also check/update **this plugin** from GitHub (`xxxizum1kxxx/agy-linux-live-update` on `main`) via **Update Plugin** / `update-core.sh update-plugin`.
- Opening the panel shows the **cached** result first, then refreshes in the background.

**中文：** Sidecar 启动时自动检查；`notify-send` 应用名为 Antigravity Linux Updater，图标用 Antigravity PNG。面板可检查/更新本插件（GitHub `main`）。未安装 `agy` CLI 时不检查 CLI。打开面板先显示缓存再后台刷新。

## CLI updates

`install.sh` installs `~/.local/bin/update-antigravity`:

```bash
update-antigravity --check
update-antigravity --app --yes
update-antigravity --cli --yes
```

Core script: `scripts/update-core.sh` (download + `pkexec scripts/install-root.sh`).

**中文：** 终端可用 `update-antigravity`；底层是 `scripts/update-core.sh`。

## Uninstall

Use `uninstall.sh` (mirrors `install.sh` flags):

```bash
chmod +x uninstall.sh scripts/uninstall-root.sh
./uninstall.sh                     # App only (default)
./uninstall.sh --plugin            # plugin + sidecar + update-antigravity wrapper
./uninstall.sh --cli               # user-local ~/.local/bin/agy
./uninstall.sh --all --yes         # App + CLI + plugin
```

`--app` uses **pkexec** via `scripts/uninstall-root.sh` (removes `/opt/antigravity`, launcher, desktop entry, icons, refreshes caches). `--plugin` also clears updater cache under `~/.cache/antigravity/linux-updater` and sidecar data. `--cli` does not delete `~/.gemini/antigravity-cli` config data.

**中文：** 用 `./uninstall.sh` 卸载，flag 与安装脚本对应；默认只卸桌面 App。`--all` 卸 App + CLI + 插件。`--app` 会 pkexec；`--cli` 不删 CLI 配置目录。

## Limitations

- Official Linux tarball only (no deb/rpm repo).
- Updating the desktop App quits running Antigravity and requires `pkexec`.
- Sidecar is off until enabled in `~/.gemini/config/config.json`.
- Icon scaling prefers ImageMagick (`magick`/`convert`); otherwise the source image is copied into each size directory.
- Desktop update toasts need `notify-send` and a notification daemon.
- This repository is **not** an official Google product.

**中文：** 仅官方 tarball；更新 App 会退出进程并需 pkexec；Sidecar 需手动启用；图标缩放优先 ImageMagick；桌面通知依赖 `notify-send`；非 Google 官方产品。

## License

MIT
