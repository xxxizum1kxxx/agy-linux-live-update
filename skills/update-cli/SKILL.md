---
name: update-cli
description: >-
  Update only the agy CLI via Google's official install.sh. Use when the user
  asks to update the Antigravity CLI (not the desktop App).
disable-model-invocation: true
---

# Update CLI (agy)

1. From the plugin root, run:

```bash
./scripts/update-core.sh --help
./scripts/update-core.sh update-cli --yes
```

2. Confirm the new version with `agy --version`.
3. Do not update the desktop App unless asked.
