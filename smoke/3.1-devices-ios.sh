#!/bin/sh
# Step 3.1: on macOS `devices` lists running iOS simulators next to the Android entries; a missing, failing or hung
# simctl or adb becomes an errors entry, and only both failing fails the command (K18 3.1 note, K32).
# Precondition: macOS with Xcode. No emulator or simulator is needed, and nothing here boots, stops or creates one;
# the adb server on the default port is never touched. Fake simctl and devicectl come through DEVELOPER_DIR, fake
# adb through ANDROID_HOME, all under env -i.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iOS simulators need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; pkill -f "sleep 97\.37"; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them.
mkdir -p "$tmp/sdk/platform-tools" "$tmp/dev/usr/bin" "$tmp/X.app/Contents/Developer/usr/bin" "$tmp/empty" "$tmp/home"
cat > "$tmp/sdk/platform-tools/adb" <<'FAKE'
#!/bin/sh
case "$*" in
  devices) printf 'List of devices attached\nfake-1\tdevice\n\n' ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/fixture.json" <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-2":[{"udid":"A1","name":"iPhone 17 Pro","state":"Booted","isAvailable":true,"dataPath":"/Users/me/x"},{"udid":"A2","name":"iPhone 17","state":"Booting","isAvailable":true},{"udid":"A3","name":"iPhone 16","state":"Shutdown","isAvailable":true},{"udid":"A4","name":"Gone","state":"Booted","isAvailable":false,"availabilityError":"runtime profile not found"},{"udid":"A5","name":"iPad Air 11-inch (M3)","state":"Booted","isAvailable":true},{"udid":"A6","state":"Booted","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.watchOS-26-0":[{"udid":"W1","name":"Apple Watch","state":"Booted","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.tvOS-26-0":[{"udid":"T1","name":"Apple TV","state":"Booted","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.xrOS-26-0":[{"udid":"X1","name":"Apple Vision Pro","state":"Booted","isAvailable":true}]}}
JSON
simctl() { printf '#!/bin/sh\n%s\n' "$1" > "$tmp/dev/usr/bin/simctl"; chmod +x "$tmp/dev/usr/bin/simctl"; }
# devicectl lists no iPhone, so its listing adds nothing here (smoke 4.1 covers it).
printf '#!/bin/sh\necho %s\n' "'{\"result\":{\"devices\":[]}}'" > "$tmp/dev/usr/bin/devicectl"
chmod +x "$tmp/sdk/platform-tools/adb" "$tmp/dev/usr/bin/devicectl"
# karagoz with only the fakes: no real adb on PATH or in the default SDK under this HOME.
run() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin "$@" "$node_bin" dist/cli.js devices 2>/dev/null; }
android='{"id":"fake-1","platform":"android","kind":"physical","state":"device","name":null}'
ios='{"id":"A1","platform":"ios","kind":"simulator","state":"Booted","name":"iPhone 17 Pro"},{"id":"A2","platform":"ios","kind":"simulator","state":"Booting","name":"iPhone 17"},{"id":"A5","platform":"ios","kind":"simulator","state":"Booted","name":"iPad Air 11-inch (M3)"}'
is() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; }

# 1. Real Mac: the iOS rows are what CoreSimulator's own simctl lists as running and available iOS simulators.
# env -i leaves DEVELOPER_DIR unset, so karagoz runs the framework simctl; the fake HOME does not change its list.
framework=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl
out=$(run ANDROID_HOME="$tmp/sdk") || fail "devices exited non-zero: $(echo "$out" | code_of)"
want=$("$framework" list devices --json | node -e '
  const { devices } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const rows = Object.entries(devices).filter(([k]) => k.startsWith("com.apple.CoreSimulator.SimRuntime.iOS-")).flatMap(([, l]) => l)
    .filter((d) => d.isAvailable === true && d.state !== "Shutdown")
    .map((d) => ({ id: d.udid, platform: "ios", kind: "simulator", state: d.state, name: d.name }));
  console.log(JSON.stringify(rows));
')
got=$(echo "$out" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (r.errors?.some((e) => e.platform === "ios")) { console.log("ios error: " + JSON.stringify(r.errors)); process.exit(); }
  console.log(JSON.stringify(r.devices.filter((d) => d.platform === "ios" && d.kind === "simulator")));
')
[ "$got" = "$want" ] || fail "real Mac: iOS rows $got, simctl says $want"
real=$(echo "$want" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).length)')
[ "$real" -gt 0 ] || echo "note: no simulator is running, so the real-Mac step compared zero rows"

# 2. Parse: running, available iOS and iPadOS only, in simctl's order, no path fields; Android first.
simctl "/bin/cat '$tmp/fixture.json'"
out=$(run ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev") || fail "parse exited non-zero: $out"
is parse "$out" "{\"devices\":[$android,$ios]}"

# 3. DEVELOPER_DIR as the .app path, with and without a trailing slash, as xcrun takes it.
cp "$tmp/dev/usr/bin/simctl" "$tmp/dev/usr/bin/devicectl" "$tmp/X.app/Contents/Developer/usr/bin/"
out=$(run ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/X.app") || fail ".app exited non-zero: $out"
is .app "$out" "{\"devices\":[$android,$ios]}"
out=$(run ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/X.app/") || fail ".app/ exited non-zero: $out"
is .app/ "$out" "{\"devices\":[$android,$ios]}"

# 4-6. simctl missing, failing, not JSON, hung: Android still listed, one ios entry, exit 0. A DEVELOPER_DIR without
# simctl has no devicectl either: a second ios entry.
entry() { echo "{\"devices\":[$android],\"errors\":[{\"platform\":\"ios\",\"code\":\"$1\",\"message\":\"$2\"}]}"; }
out=$(run ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/empty") || fail "missing simctl exited non-zero: $out"
simctl_missing="{\"platform\":\"ios\",\"code\":\"SIMCTL_NOT_FOUND\",\"message\":\"simctl not found (tried $tmp/empty/usr/bin/simctl, from DEVELOPER_DIR). Point DEVELOPER_DIR at an Xcode, not the Command Line Tools, or unset it.\"}"
devicectl_missing="{\"platform\":\"ios\",\"code\":\"DEVICECTL_NOT_FOUND\",\"message\":\"devicectl not found (tried $tmp/empty/usr/bin/devicectl, from DEVELOPER_DIR). Point DEVELOPER_DIR at an Xcode 15 or later, not the Command Line Tools, or unset it.\"}"
is missing "$out" "{\"devices\":[$android],\"errors\":[$simctl_missing,$devicectl_missing]}"
simctl 'echo "xcrun: error: unable to find utility" >&2; exit 72'
out=$(run ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev") || fail "failing simctl exited non-zero: $out"
is failing "$out" "$(entry SIMCTL_FAILED 'xcrun: error: unable to find utility')"
simctl 'echo "not json"'
out=$(run ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev") || fail "non-JSON simctl exited non-zero: $out"
is not-json "$out" "$(entry SIMCTL_FAILED 'unexpected simctl output: not json')"
simctl 'exec /bin/sleep 97.37'
start=$(date +%s)
out=$(run ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev") || fail "hung simctl exited non-zero: $out"
elapsed=$(($(date +%s) - start))
is hung "$out" "$(entry SIMCTL_TIMEOUT 'simctl did not answer within 30s. The simulator service may still be starting (the first call after login can take several seconds) or be stuck.')"
[ "$elapsed" -ge 29 ] && [ "$elapsed" -lt 40 ] || fail "hung: took ${elapsed}s, expected about 30"
! pgrep -f 'sleep 97\.37' >/dev/null || fail "hung: the fake simctl's sleep outlived karagoz"

# 7. No adb, simctl fine: the simulators and one android entry, exit 0.
simctl "/bin/cat '$tmp/fixture.json'"
out=$(run DEVELOPER_DIR="$tmp/dev") || fail "no adb exited non-zero: $out"
echo "$out" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const ok = r.devices.length === 3 && r.devices.every((d) => d.platform === "ios") && r.errors?.length === 1 &&
    r.errors[0].platform === "android" && r.errors[0].code === "ADB_NOT_FOUND";
  if (!ok) { console.log(`FAIL: no adb: ${JSON.stringify(r)}`); process.exit(1); }
'

# 8. Both missing: Android's envelope, exit 1, as before 3.1.
if out=$(run DEVELOPER_DIR="$tmp/empty"); then fail "both missing exited 0: $out"; fi
is "both missing" "$(echo "$out" | code_of)" ADB_NOT_FOUND

echo "ok: real ($real), parse, .app, missing, failing, not-json, hung (${elapsed}s), no adb, both missing"
