---
paths:
  - "packages/karagoz/smoke/**/*.sh"
---

# Smoke scripts

One smoke per step proves it (K9: a script run by hand, no test framework yet). Paths are relative to `packages/karagoz/smoke/`.

- A smoke passes only when it prints `ok:` and exits 0. Check `$?` after every run; the `ok:` line alone is not the result. The 1.1 smoke printed `ok:` and exited 143 on every passing run until someone checked.
- Scripts run under `set -e`, and errexit stays on inside traps. Start every EXIT trap with `set +e` (the trap in `1.1-devices.sh`), and make each cleanup command safe when its variable is still empty because the script failed before setting it.
- An error check asserts the whole error envelope from `AGENTS.md` `## Hard boundaries`: non-zero exit, stdout exactly one JSON line, the expected `.error.code`. `JSON.parse` alone accepts one object spread over several lines.
- Feed JSON to a helper with `printf '%s'`, never `echo`: this machine's `/bin/sh` `echo` expands `\n` and splits one JSON line in two (`1.2-screenshot.sh`).
- A path a live device cannot produce is proven with a fake tool: a fake `adb` first in line through `ANDROID_HOME` (`1.3-ui-tree.sh`), fake Xcode tools through `DEVELOPER_DIR` (`3.1-devices-ios.sh`). The live part still runs the contract on a real target.
- A phone part prints `SKIP:` and passes when no phone is attached (`2.2-screenshot-physical.sh`), so the merge gate never needs a phone.
- A smoke never kills or restarts the adb server on the default port (5037): other tools on the machine share it. A smoke that needs its own server runs one on a free port through `ANDROID_ADB_SERVER_PORT` (`2.1-devices-physical.sh`).
- Comments follow `## Comments` in `.claude/rules/simplicity.md`. The header states what the script proves and its precondition; a step gets a comment only when its commands do not show why.
