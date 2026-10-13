#!/bin/sh
# Step 3.2: on macOS `screenshot` captures a booted iOS simulator in the K22 shape (scale from the simulator, rotation
# from devicectl on Xcode 27 and null otherwise, null safeArea, 2.88 on a 1080x2340 panel in either orientation), and
# target resolution sees both platforms: UDID, name and KARAGOZ_DEVICE select a simulator, an emulator next to a booted
# simulator makes a bare call DEVICE_AMBIGUOUS, an Android-only command (key) on a simulator is NOT_SUPPORTED, a
# missing tool hides only its own platform (K33, K21 3.2 note).
# Precondition: macOS with Xcode. A booted simulator is used when one is running, else that step prints SKIP; nothing
# here boots, stops or creates one, and no emulator is needed. Fake simctl and devicectl come through DEVELOPER_DIR,
# fake adb through ANDROID_HOME, all under env -i; the adb server on the default port is never touched.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iOS simulators need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; pkill -f "sleep 97\.4[35]"; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }
# A whole PNG header and trailer with the given size; karagoz reads nothing else.
png() { node -e '
  const { crc32 } = require("zlib");
  const chunk = (type, data) => { const t = Buffer.from(type, "latin1"); const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([t, data]))); return Buffer.concat([len, t, data, crc]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(Number(process.argv[1])); ihdr.writeUInt32BE(Number(process.argv[2]), 4); ihdr[8] = 8; ihdr[9] = 6;
  process.stdout.write(Buffer.concat([Buffer.from("89504e470d0a1a0a", "hex"), chunk("IHDR", ihdr), chunk("IEND", Buffer.alloc(0))]));
' "$1" "$2"; }
# devicectl's displays JSON on stdin to karagoz's rotation, by the same table; anything unreadable is null.
rotation_of() { node -e '
  try {
    const d = JSON.parse(require("fs").readFileSync(0, "utf8")).result.displays;
    const o = (d.find((x) => x.primary === true) ?? d[0]).currentOrientation;
    console.log(JSON.stringify({ rot0: 0, rot90: 270, rot180: 180, rot270: 90 }[o] ?? null));
  } catch { console.log("null") }
'; }

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them. Files under $fake steer them.
fake="$tmp/fake"
mkdir -p "$tmp/sdk/platform-tools" "$tmp/dev/usr/bin" "$tmp/empty" "$tmp/home" "$fake"
cat > "$tmp/sdk/platform-tools/adb" <<FAKE
#!/bin/sh
case "\$*" in
  devices) /bin/cat "$fake/adb-devices" ;;
  *"emu avd name") /bin/cat "$fake/avd" ;;
  *"shell input "*keyevent*3*) ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/dev/usr/bin/simctl" <<FAKE
#!/bin/sh
case "\$*" in
  "list devices --json") [ -e "$fake/list-fails" ] && { echo "list broke" >&2; exit 1; }; /bin/cat "$fake/list.json" ;;
  *" screenshot --mask=ignored "*) exec /bin/sh "$fake/shot" > "\$5" ;;
  *" SIMULATOR_MAINSCREEN_SCALE") /bin/cat "$fake/scale" ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/dev/usr/bin/devicectl" <<FAKE
#!/bin/sh
case "\$*" in
  "device info displays --device "*" --json-output - -q") exec /bin/sh "$fake/devicectl" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$tmp/dev/usr/bin/simctl" "$tmp/dev/usr/bin/devicectl"
emulator() { printf 'List of devices attached\nemulator-5554\tdevice\n\n' > "$fake/adb-devices"; }
no_android() { printf 'List of devices attached\n\n' > "$fake/adb-devices"; }
sims() { echo "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-26-2\":[$1]}}" > "$fake/list.json"; }
a1='{"udid":"A1","name":"iPhone 17 Pro","state":"Booted","isAvailable":true}'
a2='{"udid":"A2","name":"iPhone 17","state":"Booting","isAvailable":true}'
shot() { printf '%s\n' "$1" > "$fake/shot"; }
rot() { echo "echo '{\"result\":{\"displays\":[{\"primary\":true,\"currentOrientation\":\"$1\"}]}}'" > "$fake/devicectl"; }
png 1206 2622 > "$fake/1206.png"
png 1080 2340 > "$fake/1080.png"
png 2340 1080 > "$fake/2340.png"
printf 'Medium_Phone\r\nOK\r\n' > "$fake/avd"
echo 3.000000 > "$fake/scale"
# karagoz with only the fakes. A variable for one call goes inside the substitution: an assignment before a shell
# function call outlives the call in sh.
k() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev" \
  "$node_bin" dist/cli.js "$@" 2>/dev/null; }
refuses() { # <code> <label> <karagoz output> <exit>
  [ "$4" -ne 0 ] || fail "$2 exited 0: $3"
  [ "$(printf '%s' "$3" | code_of)" = "$1" ] || fail "$2: expected $1, got: $3"
}
ok=""

# 1. Real Mac: the first booted simulator, captured by UDID with a fake adb that lists nothing. Pixels and scale are
# what the simulator itself reports, rotation is what devicectl reports (null where it cannot read a simulator, Xcode
# 26), safeArea is null; the default file is private.
framework=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl
booted=$("$framework" list devices --json | node -e '
  const { devices } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const d = Object.entries(devices).filter(([k]) => k.startsWith("com.apple.CoreSimulator.SimRuntime.iOS-")).flatMap(([, l]) => l)
    .find((d) => d.isAvailable === true && d.state === "Booted");
  console.log(d ? d.udid : "");
')
if [ -n "$booted" ]; then
  no_android
  real() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
  out=$(real screenshot --device "$booted") || fail "real screenshot exited non-zero: $out"
  width=$("$framework" getenv "$booted" SIMULATOR_MAINSCREEN_WIDTH)
  height=$("$framework" getenv "$booted" SIMULATOR_MAINSCREEN_HEIGHT)
  scale=$("$framework" getenv "$booted" SIMULATOR_MAINSCREEN_SCALE)
  rotation=$(/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl device info \
    displays --device "$booted" --json-output - -q 2>/dev/null | rotation_of)
  echo "$out" | node -e '
    const [udid, w, h, s, rot] = process.argv.slice(1);
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const png = require("fs").readFileSync(r.path);
    const fail = (m) => { console.log("FAIL: real simulator: " + m + ": " + JSON.stringify(r)); process.exit(1); };
    const keys = Object.keys(r).join(",");
    if (keys !== "path,device,pixels,logical,scale,safeArea,rotation") fail("keys " + keys);
    if (r.device !== udid) fail("device");
    if (png.readUInt32BE(16) !== r.pixels.width || png.readUInt32BE(20) !== r.pixels.height) fail("pixels are not the PNG size");
    if (r.pixels.width !== Number(w) || r.pixels.height !== Number(h)) fail("pixels are not SIMULATOR_MAINSCREEN_*");
    const want = w === "1080" && h === "2340" ? 1080 / 375 : Number(s);
    if (r.scale !== want) fail("scale");
    if (r.logical.width !== r.pixels.width / r.scale || r.logical.height !== r.pixels.height / r.scale) fail("logical");
    if (r.safeArea !== null) fail("safeArea must be null");
    if (r.rotation !== JSON.parse(rot)) fail("rotation differs from devicectl: " + rot);
    if ((require("fs").statSync(r.path).mode & 0o777) !== 0o600) fail("file mode");
  ' "$booted" "$width" "$height" "$scale" "$rotation" || exit 1
  # Fake adb next to the real simulator: an emulator makes a bare call ambiguous, key on the simulator is refused.
  emulator
  out=$(real screenshot) && st=0 || st=$?
  refuses DEVICE_AMBIGUOUS "real simulator + emulator, bare screenshot" "$out" "$st"
  out=$(real key HOME --device "$booted") && st=0 || st=$?
  refuses NOT_SUPPORTED "key on the real simulator" "$out" "$st"
  ok="real ${width}x${height}"
else
  echo "SKIP: no booted simulator"
  ok="real skipped"
fi

# 2. Fake capture by UDID: the whole line but the path; the bytes written are the bytes simctl printed.
no_android; sims "$a1"; shot "/bin/cat '$fake/1206.png'"
out=$(k screenshot --device A1) || fail "fake capture exited non-zero: $out"
line=$(echo "$out" | node -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); delete r.path; console.log(JSON.stringify(r))')
[ "$line" = '{"device":"A1","pixels":{"width":1206,"height":2622},"logical":{"width":402,"height":874},"scale":3,"safeArea":null,"rotation":null}' ] \
  || fail "fake capture gave $line"
path=$(echo "$out" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).path)')
case "$path" in "$tmp/karagoz/A1-"*.png) ;; *) fail "default path $path" ;; esac
cmp -s "$path" "$fake/1206.png" || fail "written file differs from simctl's bytes"

# 3. The 1080x2340 panel (12 mini, 13 mini) gets 1080/375, in portrait and in landscape (Xcode 27's image follows
# the interface).
shot "/bin/cat '$fake/1080.png'"
line=$(k screenshot --device A1 | node -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(JSON.stringify([r.scale, r.logical]))')
[ "$line" = '[2.88,{"width":375,"height":812.5}]' ] || fail "mini gave $line"
shot "/bin/cat '$fake/2340.png'"
line=$(k screenshot --device A1 | node -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(JSON.stringify([r.scale, r.logical]))')
[ "$line" = '[2.88,{"width":812.5,"height":375}]' ] || fail "landscape mini gave $line"

# 3b. rotation from devicectl's primary display. Anything else is null, and a hung devicectl ends at its 10 s timeout
# without failing the capture.
shot "/bin/cat '$fake/1206.png'"
rotation_is() { # <expected> <label>
  got=$(k screenshot --device A1 | node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(0, "utf8")).rotation))')
  [ "$got" = "$1" ] || fail "$2: rotation $got, expected $1"
}
rot rot270; rotation_is 90 rot270
rot rot90; rotation_is 270 rot90
rot rot0; rotation_is 0 rot0
rot rot180; rotation_is 180 rot180
echo "echo '{\"result\":{\"displays\":[{\"currentOrientation\":\"rot0\"},{\"primary\":true,\"currentOrientation\":\"rot90\"}]}}'" > "$fake/devicectl"
rotation_is 270 "primary display second"
rot bogus; rotation_is null "unknown orientation"
echo 'exit 1' > "$fake/devicectl"; rotation_is null "failing devicectl"
echo 'exec /bin/sleep 97.45' > "$fake/devicectl"
start=$(date +%s)
rotation_is null "hung devicectl"
rot_took=$(( $(date +%s) - start ))
[ "$rot_took" -ge 9 ] && [ "$rot_took" -le 15 ] || fail "hung devicectl took ${rot_took}s"
sleep 1
! pgrep -f 'sleep 97\.45' >/dev/null || fail "the hung devicectl outlived karagoz"
rm "$fake/devicectl"

# 4. Selection: by name, bare with one simulator, KARAGOZ_DEVICE over ANDROID_SERIAL, ambiguity across platforms.
shot "/bin/cat '$fake/1206.png'"
out=$(k screenshot --device "iPhone 17 Pro") || fail "by name exited non-zero: $out"
out=$(k screenshot) || fail "bare with one simulator exited non-zero: $out"
emulator
out=$(k screenshot) && st=0 || st=$?
refuses DEVICE_AMBIGUOUS "emulator + simulator, bare screenshot" "$out" "$st"
out=$(k ui-tree) && st=0 || st=$?
refuses DEVICE_AMBIGUOUS "emulator + simulator, bare ui-tree" "$out" "$st"
case "$(printf '%s' "$out" | message_of)" in *KARAGOZ_DEVICE*) ;; *) fail "DEVICE_AMBIGUOUS does not name KARAGOZ_DEVICE: $out" ;; esac
out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev" \
  KARAGOZ_DEVICE=A1 ANDROID_SERIAL=emulator-5554 "$node_bin" dist/cli.js screenshot 2>/dev/null) \
  || fail "KARAGOZ_DEVICE exited non-zero: $out"
[ "$(echo "$out" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).device)')" = A1 ] \
  || fail "KARAGOZ_DEVICE did not win over ANDROID_SERIAL: $out"
printf 'iPhone 17 Pro\r\nOK\r\n' > "$fake/avd"
out=$(k screenshot --device "iPhone 17 Pro") && st=0 || st=$?
refuses DEVICE_AMBIGUOUS "AVD and simulator with one name" "$out" "$st"
printf 'Medium_Phone\r\nOK\r\n' > "$fake/avd"
out=$(k screenshot --device nosuch) && st=0 || st=$?
refuses DEVICE_NOT_FOUND "unknown name" "$out" "$st"
case "$(printf '%s' "$out" | message_of)" in *"emulator-5554 (Medium_Phone), A1 (iPhone 17 Pro)"*) ;; *) fail "DEVICE_NOT_FOUND listing: $out" ;; esac

# 5. Android-only commands refuse a simulator, before readiness; a booting simulator is not ready for screenshot.
sims "$a1,$a2"
out=$(k key HOME --device A1) && st=0 || st=$?
refuses NOT_SUPPORTED "key on a simulator" "$out" "$st"
[ "$(printf '%s' "$out" | message_of)" = "'key' does not run on iOS simulators yet" ] || fail "NOT_SUPPORTED text: $out"
out=$(k key HOME --device A2) && st=0 || st=$?
refuses NOT_SUPPORTED "key on a booting simulator" "$out" "$st"
out=$(k screenshot --device A2) && st=0 || st=$?
refuses DEVICE_NOT_READY "screenshot on a booting simulator" "$out" "$st"
out=$(k key HOME --device emulator-5554) || fail "key on the emulator next to simulators: $out"

# 6. Capture failures. A failed capture leaves the caller's --out file as it was.
no_android; sims "$a1"
echo keep > "$tmp/old.png"
shot "echo 'An error was encountered processing the command (domain=simctl.SimDisplayScreenshotWriter.ScreenshotError, code=2):' >&2; echo 'Error creating the image' >&2; exit 2"
out=$(k screenshot --device A1 --out "$tmp/old.png") && st=0 || st=$?
refuses SIMCTL_FAILED "failing simctl" "$out" "$st"
# simctl's own text, not Node's "Command failed: <command>" wrapper: with encoding buffer, stderr is a Buffer.
case "$(printf '%s' "$out" | message_of)" in "An error was encountered"*"Error creating the image") ;; *) fail "SIMCTL_FAILED lost simctl's text: $out" ;; esac
[ "$(cat "$tmp/old.png")" = keep ] || fail "a failed capture changed the --out file"
shot "echo 'not an image'"
out=$(k screenshot --device A1) && st=0 || st=$?
refuses CAPTURE_FAILED "text instead of a PNG" "$out" "$st"
shot "/bin/cat '$fake/1206.png'"; echo nope > "$fake/scale"
out=$(k screenshot --device A1) && st=0 || st=$?
refuses CAPTURE_FAILED "unreadable scale" "$out" "$st"
echo 3.000000 > "$fake/scale"
[ -z "$(ls -d "$tmp"/karagoz-* 2>/dev/null)" ] || fail "a capture left its temp directory"

# 7. Listing failures. A missing tool hides only its platform; a broken one stops the call unless the value is an id
# the other platform listed; nothing listed and no adb is adb's error, as before 3.2.
out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" DEVELOPER_DIR="$tmp/dev" "$node_bin" dist/cli.js screenshot 2>/dev/null) \
  || fail "no adb, one simulator, bare screenshot: $out"
sims ""
out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" DEVELOPER_DIR="$tmp/dev" "$node_bin" dist/cli.js screenshot 2>/dev/null) && st=0 || st=$?
refuses ADB_NOT_FOUND "no adb, no simulator" "$out" "$st"
emulator
out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/empty" "$node_bin" dist/cli.js key HOME 2>/dev/null) \
  || fail "no simctl, one emulator, bare key: $out"
no_android
out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/empty" "$node_bin" dist/cli.js screenshot 2>/dev/null) && st=0 || st=$?
refuses NO_DEVICE "no simctl, no emulator" "$out" "$st"
case "$(printf '%s' "$out" | message_of)" in *"emulator -avd"*"USB debugging"*"open -a Simulator"*"xcrun simctl boot <name>"*) ;; *) fail "NO_DEVICE text: $out" ;; esac
emulator; sims "$a1"; touch "$fake/list-fails"
out=$(k key HOME) && st=0 || st=$?
refuses SIMCTL_FAILED "broken simctl, bare key" "$out" "$st"
out=$(k key HOME --device emulator-5554) || fail "broken simctl, key on the emulator's id: $out"
rm "$fake/list-fails"

# 8. A hung capture ends at the 30 s timeout and leaves no process behind.
no_android
shot "exec /bin/sleep 97.43"
start=$(date +%s)
out=$(k screenshot --device A1) && st=0 || st=$?
took=$(( $(date +%s) - start ))
refuses SIMCTL_TIMEOUT "hung capture" "$out" "$st"
[ "$took" -ge 29 ] && [ "$took" -le 40 ] || fail "hung capture took ${took}s"
sleep 1
! pgrep -f 'sleep 97\.43' >/dev/null || fail "the hung simctl outlived karagoz"
[ -z "$(ls -d "$tmp"/karagoz-* 2>/dev/null)" ] || fail "a hung capture left its temp directory"

echo "ok: $ok, capture, mini, rotation (hung ${rot_took}s), select, not supported, failures, listing, hung (${took}s)"
