#!/bin/sh
# Step 4.2: on macOS `screenshot` captures a paired iPhone with devicectl in the K22 shape (pixels from the PNG, scale
# from the primary display's pointScale with the 1080x2340 rule, rotation from its currentOrientation, null safeArea)
# and writes devicectl's own bytes. An unpaired or still-pairing iPhone is refused before any capture; devicectl's
# phone-state failures, an older devicectl without the verb, a hung or empty capture, a missing scale and a rotation
# during the capture map to their codes; every other command still refuses an iPhone (K40, K21 4.2 note).
# Precondition: macOS with Xcode. The real step captures a paired iPhone when `karagoz devices` lists one, else it
# prints SKIP; its image stays in this script's temp directory, removed at exit. Fake adb, simctl and devicectl come
# through ANDROID_HOME and DEVELOPER_DIR under env -i; the adb server on the default port is never touched.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iPhones need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; pkill -f "sleep 97\.46"; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
is() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; }
code_of() { "$node_bin" -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }
# The result line without its path, and the path alone.
line_of() { "$node_bin" -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); delete r.path; console.log(JSON.stringify(r))'; }
path_of() { "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).path)'; }

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them. Files under $fake steer them.
fake="$tmp/fake"
mkdir -p "$tmp/sdk/platform-tools" "$tmp/dev/usr/bin" "$tmp/nodc/usr/bin" "$tmp/home" "$fake"
cat > "$tmp/sdk/platform-tools/adb" <<FAKE
#!/bin/sh
case "\$*" in
  devices) /bin/cat "$fake/adb-devices" ;;
  *) exit 0 ;;
esac
FAKE
printf '#!/bin/sh\necho %s\n' "'{\"devices\":{}}'" > "$tmp/dev/usr/bin/simctl"
cp "$tmp/dev/usr/bin/simctl" "$tmp/nodc/usr/bin/simctl"
# The capture logs its UDID, then runs $fake/capture with the --destination path as $1.
cat > "$tmp/dev/usr/bin/devicectl" <<FAKE
#!/bin/sh
case "\$*" in
  "list devices --json-output - -q") /bin/cat "$fake/list.json" ;;
  "device capture screenshot --device "*" --destination "*" -q") echo "\$5" >> "$fake/captures"; exec /bin/sh "$fake/capture" "\$7" ;;
  "device info displays --device "*" --json-output - -q") exec /bin/sh "$fake/displays" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$tmp/dev/usr/bin/simctl" "$tmp/nodc/usr/bin/simctl" "$tmp/dev/usr/bin/devicectl"
printf 'List of devices attached\n\n' > "$fake/adb-devices"
# 16-bit RGBA PNGs with an iCCP chunk, as the phone's: 3x4 and 4x3 with pixel data, 1080x2340 with only the header and
# trailer karagoz reads.
"$node_bin" -e '
  const { crc32, deflateSync } = require("zlib");
  const fs = require("fs");
  const chunk = (type, data) => {
    const t = Buffer.from(type, "latin1"), len = Buffer.alloc(4), crc = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    crc.writeUInt32BE(crc32(Buffer.concat([t, data])));
    return Buffer.concat([len, t, data, crc]);
  };
  const png = (w, h, pixels) => {
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(w);
    ihdr.writeUInt32BE(h, 4);
    ihdr[8] = 16;
    ihdr[9] = 6;
    const iccp = Buffer.concat([Buffer.from("Display P3\0\0", "latin1"), deflateSync(Buffer.from("profile"))]);
    const idat = pixels ? [chunk("IDAT", deflateSync(Buffer.alloc((w * 8 + 1) * h, 7)))] : [];
    return Buffer.concat([Buffer.from("89504e470d0a1a0a", "hex"), chunk("IHDR", ihdr), chunk("iCCP", iccp), ...idat, chunk("IEND", Buffer.alloc(0))]);
  };
  fs.writeFileSync(process.argv[1] + "/p34.png", png(3, 4, true));
  fs.writeFileSync(process.argv[1] + "/p43.png", png(4, 3, true));
  fs.writeFileSync(process.argv[1] + "/m1080.png", png(1080, 2340, false));
' "$fake"
cap() { printf '%s\n' "$1" > "$fake/capture"; }
shot_of() { cap "/bin/cat '$fake/$1' > \"\$1\""; }
# err_of <stderr text> [exit code]: the capture prints the text to stderr and fails.
err_of() { printf '%s\n' "$1" > "$fake/stderr"; cap "/bin/cat '$fake/stderr' >&2; exit ${2:-1}"; }
disp() { printf '%s\n' "/bin/echo '$1'" > "$fake/displays"; }
rot() { disp "{\"result\":{\"displays\":[{\"primary\":true,\"pointScale\":3,\"currentOrientation\":\"$1\"}]}}"; }
row() { # <udid> <pairingState> <model>
  echo "{\"visibilityClass\":\"default\",\"properties\":{\"hardware\":{\"udid\":\"$1\",\"reality\":\"physical\",\"platform\":\"iOS\",\"marketingName\":\"$3\"},\"connection\":{\"pairingState\":\"$2\",\"state\":\"connected\",\"transportType\":\"wired\"}}}"
}
phones() { echo "{\"result\":{\"devices\":[$1]}}" > "$fake/list.json"; }
p1=$(row P1 paired "iPhone 14 Pro Max")
devdir=$tmp/dev
kdev=
k() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$devdir" \
  KARAGOZ_DEVICE="$kdev" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
# refuses <step> <code> <message, or - for any> <karagoz args...>: non-zero exit, one JSON line, that code.
refuses() {
  step=$1 code=$2 msg=$3
  shift 3
  if out=$(k "$@"); then fail "$step exited 0: $out"; fi
  is "$step" "$(printf '%s' "$out" | code_of)" "$code"
  [ "$msg" = - ] || is "$step text" "$(printf '%s' "$out" | message_of)" "$msg"
}
leftover() { [ -z "$(ls -d "$tmp"/karagoz-* 2>/dev/null)" ] || fail "$1 left a temp directory"; }

# 1. Real phone: a paired iPhone from the real devicectl, no DEVELOPER_DIR, fake adb with no device. Pixels are the
# PNG's, scale and rotation what devicectl's own info displays reports (pixels are not compared with nativeSize: a
# capture can differ from it), safeArea is null, the default file is private.
framework=/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl
real() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
phone=$(real devices | "$node_bin" -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const p = r.devices.find((d) => d.platform === "ios" && d.kind === "physical" && d.state === "paired");
  console.log(p ? p.id : "");
')
if [ -n "$phone" ]; then
  out=$(real screenshot --device "$phone") || fail "real screenshot exited non-zero: $out"
  shown=$("$framework" device info displays --device "$phone" --json-output - -q 2>/dev/null)
  size=$(echo "$out" | "$node_bin" -e '
    const [udid, tmp, shown] = process.argv.slice(1);
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(0, "utf8"));
    const fail = (m) => { console.log("FAIL: real phone: " + m); process.exit(1); };
    const keys = Object.keys(r).join(",");
    if (keys !== "path,device,pixels,logical,scale,safeArea,rotation") fail("keys " + keys);
    if (r.device !== udid) fail("device");
    if (!r.path.startsWith(tmp + "/karagoz/")) fail("default path");
    const png = fs.readFileSync(r.path);
    if (png.readUInt32BE(16) !== r.pixels.width || png.readUInt32BE(20) !== r.pixels.height) fail("pixels are not the PNG size");
    const d = JSON.parse(shown).result.displays;
    const primary = d.find((x) => x.primary === true) ?? d[0];
    const { width: w, height: h } = r.pixels;
    const mini = (w === 1080 && h === 2340) || (w === 2340 && h === 1080);
    if (r.scale !== (mini ? 1080 / 375 : primary.pointScale)) fail("scale " + r.scale);
    if (r.logical.width !== w / r.scale || r.logical.height !== h / r.scale) fail("logical");
    if (r.safeArea !== null) fail("safeArea must be null");
    const rotation = { rot0: 0, rot90: 270, rot180: 180, rot270: 90 }[primary.currentOrientation] ?? null;
    if (r.rotation !== rotation) fail("rotation " + r.rotation + ", devicectl says " + primary.currentOrientation);
    if ((fs.statSync(r.path).mode & 0o777) !== 0o600) fail("file mode");
    console.log(w + "x" + h);
  ' "$phone" "$tmp" "$shown") || { echo "$size"; exit 1; }
  leftover "the real capture"
  ok="real $size"
else
  echo "SKIP: no paired iPhone"
  ok="real skipped"
fi

# 2. Fixtures: the whole line but the path, devicectl's bytes written as they came, each rotation with a PNG of the
# matching shape, the primary display chosen over a first wireless one, the 1080x2340 rule, --out, every way to pick P1.
phones "$p1"
shot_of p34.png; rot rot0
out=$(k screenshot --device P1) || fail "capture exited non-zero: $out"
is capture "$(echo "$out" | line_of)" \
  '{"device":"P1","pixels":{"width":3,"height":4},"logical":{"width":1,"height":1.3333333333333333},"scale":3,"safeArea":null,"rotation":0}'
path=$(echo "$out" | path_of)
case "$path" in "$tmp/karagoz/P1-"*.png) ;; *) fail "default path $path" ;; esac
cmp -s "$path" "$fake/p34.png" || fail "the written file differs from devicectl's bytes"
rotation_is() { # <expected> <label>
  out=$(k screenshot --device P1) || fail "$2 exited non-zero: $out"
  is "$2" "$(echo "$out" | "$node_bin" -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(0, "utf8")).rotation))')" "$1"
}
shot_of p43.png; rot rot90; rotation_is 270 "rot90 (turned clockwise)"
rot rot270; rotation_is 90 "rot270 (turned counter-clockwise)"
shot_of p34.png; rot rot180; rotation_is 180 rot180
disp '{"result":{"displays":[{"primary":true,"pointScale":3}]}}'; rotation_is null "no currentOrientation"
disp '{"result":{"displays":[{"name":"Wireless","pointScale":1,"currentOrientation":"rot90"},{"primary":true,"pointScale":3,"currentOrientation":"rot0"}]}}'
out=$(k screenshot --device P1) || fail "wireless first exited non-zero: $out"
is "primary display" "$(echo "$out" | "$node_bin" -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(r.scale + "," + r.rotation)')" 3,0
shot_of m1080.png; rot rot0
out=$(k screenshot --device P1) || fail "mini exited non-zero: $out"
is mini "$(echo "$out" | "$node_bin" -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(JSON.stringify([r.scale, r.logical]))')" \
  '[2.88,{"width":375,"height":812.5}]'
shot_of p34.png
out=$(k screenshot --device P1 --out "$tmp/x/out.png") || fail "--out exited non-zero: $out"
is "--out" "$(echo "$out" | path_of)" "$tmp/x/out.png"
cmp -s "$tmp/x/out.png" "$fake/p34.png" || fail "--out differs from devicectl's bytes"
out=$(k screenshot --device "iPhone 14 Pro Max") || fail "by model exited non-zero: $out"
kdev=P1
out=$(k screenshot) || fail "KARAGOZ_DEVICE exited non-zero: $out"
kdev=
out=$(k screenshot) || fail "bare, one iPhone exited non-zero: $out"
is "bare, one iPhone" "$(echo "$out" | line_of)" \
  '{"device":"P1","pixels":{"width":3,"height":4},"logical":{"width":1,"height":1.3333333333333333},"scale":3,"safeArea":null,"rotation":0}'

# 3. Readiness from the listing: an unpaired or still-pairing iPhone is refused and devicectl never captures.
phones "$p1,$(row P3 unpaired "iPhone 15"),$(row P4 pairingInProgress "iPhone 16")"
: > "$fake/captures"
trust='Unlock the iPhone, tap Trust on "Trust This Computer?" and enter the passcode; if no prompt shows, unplug it and plug it in again.'
refuses unpaired DEVICE_NOT_READY "device P3 is not ready (state: unpaired). $trust" screenshot --device P3
refuses "pairing in progress" DEVICE_NOT_READY \
  "device P4 is not ready (state: pairingInProgress). Finish pairing on the iPhone: tap Trust, then enter the passcode." \
  screenshot --device P4
[ ! -s "$fake/captures" ] || fail "a phone that is not ready reached the capture"

# 4. Phone states devicectl reports at capture time, matched on its whole stderr: the Developer Mode and locked lines
# come after 300 characters, past the cut that DEVICECTL_FAILED's message gets.
rot rot0
pad=$(printf '%320s' '' | tr ' ' '-')
ddi='ERROR: The developer disk image could not be mounted on this device. (com.apple.dt.CoreDeviceError error 12040 (0x2F08))'
devmode='device P1 is not ready: Developer Mode is off. Turn it on in Settings > Privacy & Security > Developer Mode, then restart the iPhone.'
locked='device P1 is not ready: it is locked. Unlock the iPhone and try again.'
err_of 'ERROR: The device must be paired before it can be connected. (com.apple.dt.CoreDeviceError error 2 (0x02))'
refuses "must be paired" DEVICE_NOT_READY "device P1 is not ready: it is not paired with this Mac. $trust" screenshot --device P1
err_of "$(printf '%s\n       %s\n       The operation failed because Developer Mode is disabled.' "$ddi" "$pad")"
refuses "Developer Mode, deep in stderr" DEVICE_NOT_READY "$devmode" screenshot --device P1
err_of "$(printf '%s\n       %s\n       The operation failed because the device was still locked.' "$ddi" "$pad")"
refuses "locked, deep in stderr" DEVICE_NOT_READY "$locked" screenshot --device P1
err_of 'ERROR: The operation failed since Developer Mode is turned off on the device.'
refuses "Developer Mode turned off" DEVICE_NOT_READY "$devmode" screenshot --device P1
err_of 'ERROR: Developer mode is no longer enabled on the device.'
refuses "Developer Mode no longer enabled" DEVICE_NOT_READY "$devmode" screenshot --device P1
err_of 'ERROR: The device is locked. Unlock the device and try again.'
refuses "device is locked" DEVICE_NOT_READY "$locked" screenshot --device P1
err_of 'ERROR: A connection to this device could not be established. (com.apple.dt.CoreDeviceError error 4000 (0xFA0))'
refuses "no connection" DEVICECTL_FAILED - screenshot --device P1
case "$(printf '%s' "$out" | message_of)" in "ERROR: A connection to this device could not be established."*) ;; *) fail "DEVICECTL_FAILED lost devicectl's text: $out" ;; esac

# 5. An older devicectl rejects the verb at argument parsing (Xcode 26's 506.6 text); its failure wins over the displays
# read, whether that read works or fails.
old="needs Xcode 27 or later: this Mac's devicectl has no 'device capture screenshot'. Install Xcode 27 and open it once."
err_of "$(printf '%s\n%s\n%s' "Error: Unknown option '--device'" \
  'Usage: devicectl device [--verbose] [--quiet] [--timeout <seconds>] [--json-output <path>] [--log-output <path>] <subcommand>' \
  "  See 'devicectl device --help' for more information.")" 64
refuses "older devicectl" NOT_SUPPORTED "'screenshot' on an iPhone $old" screenshot --device P1
echo 'exit 1' > "$fake/displays"
refuses "older devicectl, displays failing" NOT_SUPPORTED "'screenshot' on an iPhone $old" screenshot --device P1

# 6. A hung capture ends at the 30 s timeout and leaves no process behind; a capture with no PNG, displays without a
# scale and a rotation the PNG contradicts are CAPTURE_FAILED; no devicectl means no iPhone to find.
rot rot0
cap 'exec /bin/sleep 97.46'
start=$(date +%s)
refuses "hung capture" DEVICECTL_TIMEOUT \
  "devicectl did not answer within 30s. CoreDevice's service may still be starting or be stuck." screenshot --device P1
took=$(($(date +%s) - start))
[ "$took" -ge 29 ] && [ "$took" -le 40 ] || fail "hung capture took ${took}s"
sleep 1
! pgrep -f 'sleep 97\.46' >/dev/null || fail "the hung capture outlived karagoz"
cap "echo 'not a png' > \"\$1\""
refuses "text, not a PNG" CAPTURE_FAILED "devicectl returned no image data" screenshot --device P1
cap 'exit 0'
refuses "no file" CAPTURE_FAILED "devicectl returned no image data" screenshot --device P1
shot_of p34.png; disp '{"result":{"displays":[{"primary":true,"currentOrientation":"rot0"}]}}'
refuses "no pointScale" CAPTURE_FAILED "cannot read scale from 'devicectl device info displays'" screenshot --device P1
rot rot90
refuses "rotated during the capture" CAPTURE_FAILED "the screen rotated during the capture (rotation 270, screenshot 3x4)" \
  screenshot --device P1
devdir=$tmp/nodc
refuses "no devicectl" DEVICE_NOT_FOUND - screenshot --device P1
devdir=$tmp/dev

# 7. No failure left a temp directory.
leftover "a failed capture"

# 8. Every other command still refuses an iPhone.
other="device P1 is an iPhone; karagoz runs only screenshot, ui-tree, tap, swipe, install-runner and uninstall-runner on one yet."
refuses "key" NOT_SUPPORTED "$other" key HOME --device P1
refuses "launch" NOT_SUPPORTED "$other" launch com.apple.Preferences --device P1

echo "ok: $ok, fixtures, readiness, failures, old devicectl, hung (${took}s), others"
