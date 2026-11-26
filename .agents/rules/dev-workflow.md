---
trigger: always_on
---

# Agent Guidelines

## Git 工作流

- **原子化 commit（每完成一项修改就 commit）**：每修复一个独立问题或完成一个独立改动（修一个 bug、做完一个功能、改完文档），验证通过后立即单独提交，严禁把多项修复或不相关的改动攒在同一个 commit 里。
- **一组 commit 完成后就推送**：用户提出的任务完成、相关 commit 都已提交后，执行 `git push origin main` 同步到 GitHub，不需要再询问。推送前先 `git fetch`，确认远端没有新提交；如果有，先停下来告诉用户。
- Commit message 用英文：首行是简短的祈使句摘要，空一行后列出要点。

## 修改插件后的固定步骤

1. **验证**：`node --check sidecars/updater/main.mjs`；面板脚本需要先从 `index.html` 中抽出 `<script>` 再执行 `node --check`；shell 脚本用 `bash -n`。
2. **升版本号**：只要改动了用户可感知的行为，就提升 `plugin.json` 的 `version`（修复升 patch，功能升 minor）。插件自更新靠比较这个版本号来判断有没有新版本。
3. **重新安装**：执行 `./install.sh --plugin --yes`，然后比对 `~/.gemini/config/plugins/agy-linux-live-update/` 中的文件与仓库一致。只改仓库代码不会影响 Antigravity 里正在运行的面板。
4. **提醒用户重启 Antigravity**，Sidecar 才会加载新代码。

## 面板（`sidecars/updater/index.html`）设计约束

- **点击和状态切换不能改变元素尺寸**，只能改颜色、透明度和形状。只有两类例外：用户主动展开的区域（Activity log、页脚插件面板），以及更新成功后操作区收起。
- 动态文字一律单行省略或固定行数；会互相切换的内容叠放在同一个格子里，只做淡入淡出。
- 最小宽度 360px（含 10px 滚动条槽位）。
- 界面改动用模拟后端 + 浏览器子代理，在 400px 和 360px 宽度下用 `boundingBox()` 实测尺寸。

## 注意

- 仓库根目录就是插件根目录，**不要在根目录放 `AGENTS.md` / `GEMINI.md`**：`agy plugin validate --strict` 会报警告，导致 `install.sh --plugin` 安装失败。开发规范放在 `.agents/rules/` 里。
