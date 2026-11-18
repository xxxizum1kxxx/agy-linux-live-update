---
name: update-app
description: >-
  Update only the Linux Antigravity desktop App under /opt from the official
  tarball. Use when the user asks to update the Antigravity App (not the CLI).
disable-model-invocation: true
---

# Update desktop App

Warn the user first:

- The running Antigravity process will be stopped.
- `pkexec` will prompt for authorization to write `/opt/antigravity`.
- They must relaunch Antigravity after the update.

Then run from the plugin root:

```bash
./scripts/update-core.sh --help
./scripts/update-core.sh update-app --yes
```

Report the new build-id from the command output. Do not update the CLI unless asked.
