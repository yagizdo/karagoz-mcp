#!/bin/sh
# Step 1.1: `devices` lists a running emulator with its AVD name; a missing or hung adb fails with the JSON envelope.
# Precondition: an emulator is running (emulator -avd <name>). Nothing here boots, stops or restarts anything,
# and the adb server on the default port is never touched.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
listener=
# set +e: errexit stays on inside the trap, and a failing kill or wait would skip the rm.
trap 'set +e; kill $listener 2>/dev/null; wait $listener 2>/dev/null; rm -rf "$tmp"' EXIT
# Prints .error.code, or not-json. The envelope must be exactly one line (K5).
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }

# 1. A ready emulator, named. Only its entry is printed: the full list names any phone attached (CLAUDE.md, Device data).
out=$(node dist/cli.js devices) || { echo "FAIL: devices exited non-zero: $out"; exit 1; }
emu=$(echo "$out" | node -e '
  const { devices } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const found = devices.find((d) => d.kind === "emulator" && d.state === "device" && typeof d.name === "string" && d.name);
  if (!found) process.exit(1);
  console.log(JSON.stringify(found));
') || { echo "FAIL: no ready, named emulator listed (is one running? emulator -avd <name>)"; exit 1; }

# 2. No adb anywhere: empty PATH, no SDK env, HOME without a default SDK. On macOS DEVELOPER_DIR without a simctl
# fails iOS too; with iOS listed, a missing adb is an errors entry and exit 0 (smoke 3.1).
if miss=$(env -i HOME="$tmp" PATH="$tmp" DEVELOPER_DIR="$tmp" "$node_bin" dist/cli.js devices 2>/dev/null); then echo "FAIL: missing adb exited 0"; exit 1; fi
[ "$(echo "$miss" | code_of)" = ADB_NOT_FOUND ] || { echo "FAIL: expected ADB_NOT_FOUND, got: $miss"; exit 1; }

# 3. adb hangs: point it at a port that accepts and never answers.
node -e 'const s = require("net").createServer(() => {}).listen(0, "127.0.0.1", () => require("fs").writeFileSync(process.argv[1], String(s.address().port)))' "$tmp/port" &
listener=$!
while [ ! -s "$tmp/port" ]; do kill -0 "$listener" || { echo "FAIL: listener did not start"; exit 1; }; sleep 0.1; done
start=$(date +%s)
if hang=$(ANDROID_ADB_SERVER_PORT=$(cat "$tmp/port") DEVELOPER_DIR="$tmp" node dist/cli.js devices 2>/dev/null); then echo "FAIL: hung adb exited 0"; exit 1; fi
elapsed=$(($(date +%s) - start))
[ "$(echo "$hang" | code_of)" = ADB_TIMEOUT ] || { echo "FAIL: expected ADB_TIMEOUT, got: $hang"; exit 1; }
[ "$elapsed" -lt 15 ] || { echo "FAIL: timeout took ${elapsed}s"; exit 1; }

echo "ok: $emu"
