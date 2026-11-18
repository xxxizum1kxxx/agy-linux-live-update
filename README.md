# Linux Updater（agy-linux-live-update）

在 Linux 上安装 / 检查 / 更新 [Google Antigravity](https://antigravity.google/download/) 桌面 App（`/opt`）与 `agy` CLI，并提供 Antigravity 插件 + Sidecar 面板。

兼容 **GNOME / KDE / XFCE**（`.desktop` + 多尺寸 hicolor 图标 + 桌面/图标缓存刷新）。

## 一键安装桌面 App

```bash
# 克隆后
git clone https://github.com/xxxizum1kxxx/agy-linux-live-update.git ~/tools/agy-linux-live-update
cd ~/tools/agy-linux-live-update
chmod +x install.sh scripts/*.sh
./install.sh --yes
```

或从本仓库直接跑（需已有 checkout）：

```bash
~/tools/agy-linux-live-update/install.sh --yes
```

可选组合：

```bash
./install.sh --app --cli --plugin --yes   # App + CLI + 本插件
./install.sh --check                      # 只查看本地/远端版本
./install.sh --plugin --yes               # 仅安装插件并启用 Sidecar
```

提权写入 `/opt`、`/usr/local` 时会弹出 **pkexec**。

## 安装内容（FHS）

| 路径 | 说明 |
|------|------|
| `/opt/antigravity` | 官方 tarball 展开目录 |
| `/opt/antigravity/.build-id` | 远端 build id（用于检查更新） |
| `/opt/antigravity/chrome-sandbox` | setuid root（Electron sandbox） |
| `/usr/local/bin/antigravity` | 启动软链 |
| `/usr/local/share/applications/antigravity.desktop` | 桌面入口 |
| `/usr/local/share/icons/hicolor/*/apps/antigravity.png` | 多尺寸图标 |

安装后会尽量刷新：`update-desktop-database`、`gtk-update-icon-cache`、`xdg-desktop-menu`、`kbuildsycoca5|6`（若存在）。

架构自动识别：`x86_64` → `linux-x64`，`aarch64`/`arm64` → `linux-arm`。下载官网页面时使用浏览器 User-Agent，避免部分环境 403。

## 插件 / Sidecar

```bash
./install.sh --plugin --yes
# 或
agy plugin validate --strict ~/tools/agy-linux-live-update
agy plugin install ~/tools/agy-linux-live-update
```

启用 Sidecar（`install.sh --plugin` 会自动写；也可手动）：

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

重启 Antigravity，打开 **Extensions → Linux Updater**。

斜杠技能：`/check-updates`、`/update-app`、`/update-cli`。

## 终端更新

`install.sh` 会安装 `~/.local/bin/update-antigravity`：

```bash
update-antigravity --check
update-antigravity --app --yes
update-antigravity --cli --yes
```

底层脚本：`scripts/update-core.sh`（下载 + `pkexec scripts/install-root.sh`）。

## 卸载

桌面 App（需 pkexec）：

```bash
pkexec bash -c '
  rm -rf /opt/antigravity
  rm -f /usr/local/bin/antigravity
  rm -f /usr/local/share/applications/antigravity.desktop
  rm -f /usr/local/share/icons/hicolor/*/apps/antigravity.png
  update-desktop-database /usr/local/share/applications 2>/dev/null || true
  gtk-update-icon-cache -f -t /usr/local/share/icons/hicolor 2>/dev/null || true
'
```

插件：

```bash
agy plugin uninstall agy-linux-live-update
```

CLI 按官方 `install.sh` 的安装位置自行删除（通常在 `~/.local`）。

## 限制

- 仅支持官方 Linux tarball（无 deb/rpm 仓库）。
- 更新桌面 App 会结束正在运行的 Antigravity，并需要 `pkexec`。
- Sidecar 默认关闭，需在 `~/.gemini/config/config.json` 启用。
- 图标缩放优先使用 ImageMagick（`magick`/`convert`）；没有时会降级拷贝源图到各尺寸目录。
- 本仓库**不是** Google 官方产品。

## License

MIT
