#!/bin/sh
# Step 4.1: on macOS `devices` lists the iPhones attached to the Mac, read from devicectl, after the Android entries and
# the simulators: id the UDID, kind physical, state devicectl's pairing state, name the model. Simulators, remembered
# phones that are not attached, nearby unpaired devices and other Apple devices are dropped; Xcode 27's properties
# dictionary and the older keys read the same; a missing, failing or hung devicectl is one ios errors entry. Targeted
# commands but screenshot find an iPhone by UDID or model and refuse it with NOT_SUPPORTED (K18, K21 4.1 and 4.2 notes,
# K39).
# Precondition: macOS with Xcode. No emulator is needed. Step 1 reads the real devicectl list only and compares zero
# rows when no iPhone is attached. Fake adb, simctl and devicectl come through ANDROID_HOME and DEVELOPER_DIR under
# env -i; the adb server on the default port is never touched.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iPhones need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; pkill -f "sleep 97\.39"; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
is() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; }

# Fakes. Each prints what a file holds, so a step changes one file. Scripts call /bin tools by absolute path: env -i
# leaves no PATH for them.
mkdir -p "$tmp/sdk/platform-tools" "$tmp/dev/usr/bin" "$tmp/nodc/usr/bin" "$tmp/home"
cat > "$tmp/sdk/platform-tools/adb" <<FAKE
#!/bin/sh
case "\$*" in
  devices) printf 'List of devices attached\n'; /bin/cat "$tmp/adb.out" ;;
  *) exit 0 ;;
esac
FAKE
printf '#!/bin/sh\n/bin/cat "%s/sim.json"\n' "$tmp" > "$tmp/dev/usr/bin/simctl"
cat > "$tmp/dev/usr/bin/devicectl" <<FAKE
#!/bin/sh
case "\$*" in
  "list devices --json-output - -q") exec /bin/sh "$tmp/devicectl.sh" ;;
  *) exit 1 ;;
esac
FAKE
cp "$tmp/dev/usr/bin/simctl" "$tmp/nodc/usr/bin/simctl"
chmod +x "$tmp/sdk/platform-tools/adb" "$tmp/dev/usr/bin/simctl" "$tmp/dev/usr/bin/devicectl" "$tmp/nodc/usr/bin/simctl"
dc() { printf '%s\n' "$1" > "$tmp/devicectl.sh"; }
adb_lists() { printf "$1" > "$tmp/adb.out"; }
sims() { printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[%s]}}\n' "$1" > "$tmp/sim.json"; }
devdir=$tmp/dev
kdev=
kz() {
  env -i HOME="$tmp/home" PATH=/usr/bin:/bin ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$devdir" KARAGOZ_DEVICE="$kdev" \
    "$node_bin" dist/cli.js "$@" 2>/dev/null
}

# Xcode 27's shape. P1 also carries the deprecated keys, with a different model name: properties must win. Kept: P1-P4;
# P3 is unpaired and, as devicectl prints such a phone, has no reality and no model name (measured). Dropped: G1
# remembered but not attached, S1 a simulator, W1 a watch, E1 no hardware info, N1 nearby and pairable.
cat > "$tmp/phones27.json" <<'JSON'
{"info":{"outcome":"success","jsonVersion":5,"environment":{"TERM":"x"}},"result":{"devices":[
{"identifier":"C1","visibilityClass":"default","hardwareProperties":{"udid":"P1","reality":"physical","platform":"iOS","marketingName":"OLD"},"connectionProperties":{"pairingState":"paired","tunnelState":"connected","transportType":"wired"},"properties":{"hardware":{"udid":"P1","reality":"physical","platform":"iOS","marketingName":"iPhone 14 Pro Max"},"connection":{"pairingState":"paired","state":"connected","transportType":"wired"},"state":{"name":"Owner's iPhone"}}},
{"identifier":"C2","visibilityClass":"default","properties":{"hardware":{"udid":"P2","reality":"physical","platform":"iOS","marketingName":"iPhone 17 Pro"},"connection":{"pairingState":"paired","state":"disconnected","transportType":"localNetwork"}}},
{"identifier":"C3","visibilityClass":"default","properties":{"hardware":{"udid":"P3","platform":"iOS","productType":"iPhone15,3"},"connection":{"pairingState":"unpaired","state":"disconnected","transportType":"wired"}}},
{"identifier":"C4","visibilityClass":"default","properties":{"hardware":{"udid":"P4","reality":"physical","platform":"iOS","marketingName":"iPad Air 11-inch (M3)"},"connection":{"pairingState":"pairingInProgress","state":"connecting","transportType":"wired"}}},
{"identifier":"C5","visibilityClass":"default","properties":{"hardware":{"udid":"G1","reality":"physical","platform":"iOS","marketingName":"iPhone 12"},"connection":{"pairingState":"paired","state":"unavailable"}}},
{"identifier":"C6","visibilityClass":"simulators","properties":{"hardware":{"udid":"S1","reality":"simulated","platform":"iOS","marketingName":"iPhone 17"},"connection":{"pairingState":"paired","state":"connected","transportType":"sameMachine"}}},
{"identifier":"C7","visibilityClass":"default","properties":{"hardware":{"udid":"W1","reality":"physical","platform":"watchOS","marketingName":"Apple Watch Series 10"},"connection":{"pairingState":"paired","state":"connected","transportType":"localNetwork"}}},
{"identifier":"C8","visibilityClass":"default","hardwareProperties":{},"connectionProperties":{"pairingState":"unpaired","tunnelState":"disconnected"},"properties":{"hardware":{},"connection":{"pairingState":"unpaired","state":"disconnected"}}},
{"identifier":"C9","visibilityClass":"wirelessPairableDevices","properties":{"hardware":{"udid":"N1","reality":"physical","platform":"iOS","marketingName":"iPhone 16"},"connection":{"pairingState":"unpaired","state":"disconnected","transportType":"localNetwork"}}}
]}}
JSON
# Xcode 15-26's shape: the same devices under the old keys only, tunnelState for state.
"$node_bin" -e '
  const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  for (const d of doc.result.devices) {
    const { hardware = {}, connection = {} } = d.properties;
    const { state, ...rest } = connection;
    d.hardwareProperties = hardware;
    d.connectionProperties = { ...rest, ...(state && { tunnelState: state }) };
    delete d.properties;
  }
  delete doc.info.jsonVersion;
  console.log(JSON.stringify(doc));
' "$tmp/phones27.json" > "$tmp/phones26.json"
android='{"id":"fake-1","platform":"android","kind":"physical","state":"device","name":null}'
sim='{"id":"A1","platform":"ios","kind":"simulator","state":"Booted","name":"iPhone 17 Pro"}'
phones='{"id":"P1","platform":"ios","kind":"physical","state":"paired","name":"iPhone 14 Pro Max"},{"id":"P2","platform":"ios","kind":"physical","state":"paired","name":"iPhone 17 Pro"},{"id":"P3","platform":"ios","kind":"physical","state":"unpaired","name":null},{"id":"P4","platform":"ios","kind":"physical","state":"pairingInProgress","name":"iPad Air 11-inch (M3)"}'

# 1. Real Mac: the iPhone rows are what the framework devicectl's own list gives under the same rules. env -i leaves
# DEVELOPER_DIR unset, so karagoz runs the framework binary too; the fake adb lists nothing.
adb_lists ''
framework=/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl
out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin ANDROID_HOME="$tmp/sdk" "$node_bin" dist/cli.js devices 2>/dev/null) \
  || fail "real Mac: devices exited non-zero: $out"
want=$("$framework" list devices --json-output - -q | "$node_bin" -e '
  const { result } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const rows = result.devices.flatMap((d) => {
    const hw = d.properties?.hardware ?? d.hardwareProperties ?? {};
    const c = d.properties?.connection ?? d.connectionProperties ?? {};
    if ((hw.reality ?? "physical") !== "physical" || hw.platform !== "iOS") return [];
    if ((c.state ?? c.tunnelState) === "unavailable") return [];
    if (d.visibilityClass !== undefined && d.visibilityClass !== "default") return [];
    if (typeof hw.udid !== "string" || typeof c.pairingState !== "string") return [];
    const name = typeof hw.marketingName === "string" ? hw.marketingName : null;
    return [{ id: hw.udid, platform: "ios", kind: "physical", state: c.pairingState, name }];
  });
  console.log(JSON.stringify(rows));
')
got=$(echo "$out" | "$node_bin" -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (r.errors?.some((e) => e.platform === "ios")) { console.log("ios error: " + JSON.stringify(r.errors)); process.exit(); }
  console.log(JSON.stringify(r.devices.filter((d) => d.platform === "ios" && d.kind === "physical")));
')
[ "$got" = "$want" ] || fail "real Mac: iPhone rows $got, devicectl says $want"
real=$(echo "$want" | "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).length)')
[ "$real" -gt 0 ] || echo "note: no iPhone attached; the real-Mac step compared zero rows"

# 2-3. Parse: attached iPhones only, in devicectl's order, after Android and the simulators, from either shape.
adb_lists 'fake-1\tdevice\n'
sims '{"udid":"A1","name":"iPhone 17 Pro","state":"Booted","isAvailable":true}'
dc "/bin/cat '$tmp/phones27.json'"
out=$(kz devices) || fail "Xcode 27 shape exited non-zero: $out"
is "Xcode 27 shape" "$out" "{\"devices\":[$android,$sim,$phones]}"
dc "/bin/cat '$tmp/phones26.json'"
out=$(kz devices) || fail "Xcode 26 shape exited non-zero: $out"
is "Xcode 26 shape" "$out" "{\"devices\":[$android,$sim,$phones]}"

# 4. devicectl missing, failing, not JSON, without a device list, hung: the other rows and one ios entry, exit 0.
entry() { echo "{\"devices\":[$android,$sim],\"errors\":[{\"platform\":\"ios\",\"code\":\"$1\",\"message\":\"$2\"}]}"; }
devdir=$tmp/nodc
out=$(kz devices) || fail "missing devicectl exited non-zero: $out"
is missing "$out" "$(entry DEVICECTL_NOT_FOUND "devicectl not found (tried $tmp/nodc/usr/bin/devicectl, from DEVELOPER_DIR). Point DEVELOPER_DIR at an Xcode 15 or later, not the Command Line Tools, or unset it.")"
devdir=$tmp/dev
dc 'echo "fake devicectl failure" >&2; exit 1'
out=$(kz devices) || fail "failing devicectl exited non-zero: $out"
is failing "$out" "$(entry DEVICECTL_FAILED 'fake devicectl failure')"
dc 'echo "not json"'
out=$(kz devices) || fail "non-JSON devicectl exited non-zero: $out"
is not-json "$out" "$(entry DEVICECTL_FAILED 'unexpected devicectl output: not json')"
dc "echo '{\"info\":{\"outcome\":\"failed\"}}'"
out=$(kz devices) || fail "devicectl without a list exited non-zero: $out"
is no-list "$out" "$(entry DEVICECTL_FAILED 'unexpected devicectl output: {\"info\":{\"outcome\":\"failed\"}}')"
dc 'exec /bin/sleep 97.39'
start=$(date +%s)
out=$(kz devices) || fail "hung devicectl exited non-zero: $out"
elapsed=$(($(date +%s) - start))
is hung "$out" "$(entry DEVICECTL_TIMEOUT "devicectl did not answer within 10s. CoreDevice's service may still be starting or be stuck.")"
[ "$elapsed" -ge 9 ] && [ "$elapsed" -lt 16 ] || fail "hung: took ${elapsed}s, expected about 10"
! pgrep -f 'sleep 97\.39' >/dev/null || fail "hung: the fake devicectl's sleep outlived karagoz"

# 5. Targets: an iPhone is found by UDID, model or KARAGOZ_DEVICE and refused before any readiness check, unpaired
# included; a name on an iPhone and a simulator, or no value with several devices, is ambiguous (K21 4.1 note).
code_of() { "$node_bin" -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
field() { "$node_bin" -e "console.log(JSON.parse(require('fs').readFileSync(0, 'utf8')).$1)"; }
# refuses <step> <code> <karagoz args...>: non-zero exit, one JSON line, that code.
refuses() {
  step=$1 code=$2
  shift 2
  if out=$(kz "$@"); then fail "$step exited 0: $out"; fi
  is "$step" "$(printf '%s' "$out" | code_of)" "$code"
}
dc "/bin/cat '$tmp/phones27.json'"
refuses "by UDID" NOT_SUPPORTED ui-tree --device P1
is "by UDID text" "$(printf '%s' "$out" | field error.message)" \
  "device P1 is an iPhone; karagoz runs only screenshot, install-runner and uninstall-runner on one yet."
refuses "by model" NOT_SUPPORTED ui-tree --device "iPhone 14 Pro Max"
kdev=P3
refuses "unpaired, from KARAGOZ_DEVICE" NOT_SUPPORTED key HOME
kdev=
refuses "iPhone and simulator name" DEVICE_AMBIGUOUS screenshot --device "iPhone 17 Pro"
refuses "unknown value" DEVICE_NOT_FOUND screenshot --device nope
case "$(printf '%s' "$out" | field error.message)" in *"P1 (iPhone 14 Pro Max)"*"P3, "*) ;; *) fail "DEVICE_NOT_FOUND text: $out" ;; esac
adb_lists ''
sims ''
cat > "$tmp/one.json" <<'JSON'
{"result":{"devices":[{"visibilityClass":"default","properties":{"hardware":{"udid":"P1","reality":"physical","platform":"iOS","marketingName":"iPhone 14 Pro Max"},"connection":{"pairingState":"paired","state":"connected","transportType":"wired"}}}]}}
JSON
dc "/bin/cat '$tmp/one.json'"
refuses "bare, one iPhone" NOT_SUPPORTED ui-tree
adb_lists 'fake-1\tdevice\n'
refuses "bare, emulator and iPhone" DEVICE_AMBIGUOUS screenshot
# A missing devicectl means no iPhones: the one emulator is the target.
devdir=$tmp/nodc
out=$(kz key HOME) || fail "bare, no devicectl, one emulator exited non-zero: $out"
is "bare, no devicectl" "$(printf '%s' "$out" | field device)" fake-1
devdir=$tmp/dev
dc 'exec /bin/sleep 97.39'
start=$(date +%s)
refuses "bare, hung devicectl" DEVICECTL_TIMEOUT key HOME
took=$(($(date +%s) - start))
[ "$took" -ge 9 ] && [ "$took" -lt 16 ] || fail "bare, hung devicectl: took ${took}s, expected about 10"
! pgrep -f 'sleep 97\.39' >/dev/null || fail "bare, hung devicectl: the fake devicectl's sleep outlived karagoz"

echo "ok: real ($real), Xcode 27 shape, Xcode 26 shape, missing, failing, not-json, no-list, hung (${elapsed}s), targets (${took}s)"
