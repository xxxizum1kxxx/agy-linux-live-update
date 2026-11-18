---
name: check-updates
description: >-
  Check whether the Linux Antigravity desktop App (/opt) and agy CLI have
  newer official releases. Use only when the user asks to check Antigravity
  updates on Linux.
disable-model-invocation: true
---

# Check updates

1. From the plugin root (parent of `skills/`), run:

```bash
./scripts/update-core.sh --help
./scripts/update-core.sh status
```

2. Summarize local vs remote App build-id and CLI versions for the user.
3. Do **not** download or install anything unless the user explicitly asks to update.
