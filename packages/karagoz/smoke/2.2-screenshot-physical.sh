#!/bin/sh
# Step 2.2: `screenshot` reads the `dumpsys window displays` formats of Android 10 (two states), 11, 12, 13 and 14
# (fake adb, always), and captures a physical device by serial and by model name with K6 metadata that matches the
# device's own `wm size` and `wm density` (when one is listed).
# Precondition: the build only; a phone with USB debugging on is optional, and no emulator is needed.
# Nothing here writes to a phone: the only calls that reach one are `adb devices`, the getprop that `devices` and name
# matching make, screencap, `wm size`, `wm density` and `dumpsys window displays`. The adb server on the default port is
# never stopped or restarted.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

tmp=$(mktemp -d)
serial=
# set +e: errexit stays on inside the trap.
trap 'set +e; rm -rf "$tmp"' EXIT
# Prints one field of a success result (a dotted key such as pixels.width). Fails unless stdout is one JSON line.
field() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  let value = JSON.parse(out);
  for (const key of process.argv[1].split(".")) value = value?.[key];
  if (value === undefined) process.exit(1);
  console.log(value);
' "$1"; }
# Passes when the file is a whole PNG of the given size: signature, IHDR first, the IEND chunk last.
png_ok() { node -e '
  const [file, width, height] = process.argv.slice(1);
  const png = require("fs").readFileSync(file);
  const signature = Buffer.from("89504e470d0a1a0a", "hex");
  const iend = Buffer.from("0000000049454e44ae426082", "hex");
  const whole = png.subarray(0, 8).equals(signature) && png.toString("latin1", 12, 16) === "IHDR" && png.subarray(-12).equals(iend);
  process.exit(whole && png.readUInt32BE(16) === Number(width) && png.readUInt32BE(20) === Number(height) ? 0 : 1);
' "$1" "$2" "$3"; }
# Prints FAIL: and exits 1, with the phone's serial replaced by <phone> (CLAUDE.md, Device data). A literal replace,
# not sed: a serial such as 192.168.1.5:5555 holds regex characters.
fail() {
  if [ -z "$serial" ]; then
    printf 'FAIL: %s\n' "$1"
  else
    printf 'FAIL: %s\n' "$1" | node -e '
      process.stdout.write(require("fs").readFileSync(0, "utf8").split(process.argv[1]).join("<phone>"));
    ' "$serial"
  fi
  exit 1
}

# 1. One fake device per `dumpsys window displays` format, through a fake adb on an otherwise empty PATH. The fake
# answers by serial and rejects any other call. It sets its own PATH: without it cat is not found, and karagoz
# reports that screencap returned no data.
mkdir "$tmp/fake"
cat > "$tmp/fake/adb" <<'EOF'
#!/bin/sh
PATH=/usr/bin:/bin
here=${0%/*}
case "$*" in
  devices) printf 'List of devices attached\nfake-api29\tdevice\nfake-api29-seascape\tdevice\nfake-api30\tdevice\nfake-api31\tdevice\nfake-api33\tdevice\nfake-api34\tdevice\n\n' ;;
  "-s $2 exec-out screencap -p") cat "$here/$2.png" ;;
  "-s $2 shell wm density") cat "$here/$2.density" ;;
  "-s $2 shell dumpsys window displays") cat "$here/$2.txt" ;;
  *) echo "fake adb: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/fake/adb"
# $1 serial, $2 a PNG with only IHDR and IEND as hex (zlib.crc32 needs Node 22.2 and engines says >=22), $3 density.
device() {
  node -e 'require("fs").writeFileSync(process.argv[1], Buffer.from(process.argv[2], "hex"))' "$tmp/fake/$1.png" "$2"
  printf 'Physical density: %s\n' "$3" >"$tmp/fake/$1.density"
}
png1080x2280=89504e470d0a1a0a0000000d4948445200000438000008e80806000000398e1ad40000000049454e44ae426082
png2280x1080=89504e470d0a1a0a0000000d49484452000008e8000004380806000000b91b71010000000049454e44ae426082
device fake-api34 89504e470d0a1a0a0000000d49484452000004380000090c0806000000122c48f40000000049454e44ae426082 450
device fake-api33 "$png1080x2280" 440
device fake-api31 89504e470d0a1a0a0000000d49484452000002d00000064c080600000027bcb5b70000000049454e44ae426082 320
device fake-api30 "$png2280x1080" 440
device fake-api29 "$png1080x2280" 440
device fake-api29-seascape "$png2280x1080" 440
# The Android 14 shape, written by hand in the AOSP 14 format (K23): the (organized) header, base= before cur=,
# mUserRotation= next to mRotation=, the insetsRoundedCornerFrame= tail, an ime line with visibleFrame=.
cat > "$tmp/fake/fake-api34.txt" <<'EOF'
WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
  Display: mDisplayId=0 (organized)
    init=1440x3088 600dpi base=1080x2316 450dpi cur=1080x2316 app=1080x2106
    mRotation=0 mDeferredRotationPauseCount=0
    mUserRotationMode=USER_ROTATION_FREE mUserRotation=ROTATION_0
  WindowInsetsStateController
    InsetsState
      mDisplayFrame=Rect(0, 0 - 1080, 2316)
        InsetsSource id=3 type=ime frame=[0,0][0,0] visibleFrame=[0,1307][1080,2316] visible=false flags= insetsRoundedCornerFrame=false
        InsetsSource id=27 type=displayCutout frame=[0,0][1080,75] visible=true flags= insetsRoundedCornerFrame=false
        InsetsSource id=a0000 type=statusBars frame=[0,0][1080,75] visible=true flags= insetsRoundedCornerFrame=false
        InsetsSource id=b0001 type=navigationBars frame=[0,2181][1080,2316] visible=true flags= insetsRoundedCornerFrame=false
        InsetsSource id=b0004 type=systemGestures frame=[0,0][0,0] visible=true flags= insetsRoundedCornerFrame=false
EOF
# Android 13 (emulator, API 33): no id= token, ITYPE_* names, sentinel cutout frames such as [0,0][-100000,2280].
cat > "$tmp/fake/fake-api33.txt" <<'EOF'
WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
  Display: mDisplayId=0 rootTasks=3
    init=1080x2280 440dpi mMinSizeOfResizeableTaskDp=220 cur=1080x2280 app=1080x2016 rng=1080x1080-2016x2016
    mRotation=0 mDeferredRotationPauseCount=0
  WindowInsetsStateController
    InsetsState
      mDisplayFrame=Rect(0, 0 - 1080, 2280)
        InsetsSource type=ITYPE_STATUS_BAR frame=[0,0][1080,132] visible=true insetsRoundedCornerFrame=false
        InsetsSource type=ITYPE_NAVIGATION_BAR frame=[0,2148][1080,2280] visible=true insetsRoundedCornerFrame=false
        InsetsSource type=ITYPE_LEFT_DISPLAY_CUTOUT frame=[0,0][-100000,2280] visible=true insetsRoundedCornerFrame=false
        InsetsSource type=ITYPE_TOP_DISPLAY_CUTOUT frame=[0,0][1080,132] visible=true insetsRoundedCornerFrame=false
        InsetsSource type=ITYPE_RIGHT_DISPLAY_CUTOUT frame=[100000,0][1080,2280] visible=true insetsRoundedCornerFrame=false
        InsetsSource type=ITYPE_BOTTOM_DISPLAY_CUTOUT frame=[0,100000][1080,2280] visible=true insetsRoundedCornerFrame=false
EOF
# Android 12 (a phone, API 31), parser lines only: ITYPE_* names, a gesture source wider than the status bar, an
# ITYPE_IME line with visibleFrame=, and an mSource= copy under InsetsSourceProviders.
cat > "$tmp/fake/fake-api31.txt" <<'EOF'
WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
  Display: mDisplayId=0 rootTasks=6
    init=720x1612 320dpi cur=720x1612 app=720x1460 rng=720x664-1444x1460
    mRotation=0 mDeferredRotationPauseCount=0
  WindowInsetsStateController
    InsetsState
      mDisplayFrame=Rect(0, 0 - 720, 1612)
        InsetsSource type=ITYPE_STATUS_BAR frame=[0,0][720,72] visible=true
        InsetsSource type=ITYPE_NAVIGATION_BAR frame=[0,1532][720,1612] visible=true
        InsetsSource type=ITYPE_TOP_MANDATORY_GESTURES frame=[0,0][720,96] visible=true
        InsetsSource type=ITYPE_LEFT_DISPLAY_CUTOUT frame=[0,0][-2147483648,1612] visible=true
        InsetsSource type=ITYPE_TOP_DISPLAY_CUTOUT frame=[0,0][720,72] visible=true
        InsetsSource type=ITYPE_RIGHT_DISPLAY_CUTOUT frame=[2147483647,0][720,1612] visible=true
        InsetsSource type=ITYPE_BOTTOM_DISPLAY_CUTOUT frame=[0,2147483647][720,1612] visible=true
        InsetsSource type=ITYPE_IME frame=[0,0][0,0] visibleFrame=[0,1532][720,1612] visible=false
    InsetsSourceProviders:
      InsetsSourceProvider
        mSource=InsetsSource type=ITYPE_STATUS_BAR frame=[0,0][720,500] visible=true
EOF
# Android 11 (emulator, API 30, landscape): no mDisplayFrame= line, 6-space sources, and an mSource= copy with
# spaces before InsetsSource.
cat > "$tmp/fake/fake-api30.txt" <<'EOF'
WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
  Display: mDisplayId=0 stacks=3
    init=1080x2280 440dpi cur=2280x1080 app=2016x1080 rng=1080x1003-2016x2016
    mRotation=1 mDeferredRotationPauseCount=0
  WindowInsetsStateController
    InsetsState
      InsetsSource type=ITYPE_STATUS_BAR frame=[0,0][2280,77] visible=true
      InsetsSource type=ITYPE_NAVIGATION_BAR frame=[2148,0][2280,1080] visible=true
      InsetsSource type=ITYPE_LEFT_DISPLAY_CUTOUT frame=[0,0][132,1080] visible=true
      InsetsSource type=ITYPE_TOP_DISPLAY_CUTOUT frame=[0,0][2280,-2147483648] visible=true
      InsetsSource type=ITYPE_RIGHT_DISPLAY_CUTOUT frame=[2147483647,0][2280,1080] visible=true
      InsetsSource type=ITYPE_BOTTOM_DISPLAY_CUTOUT frame=[0,2147483647][2280,1080] visible=true
    Control map:
    InsetsSourceProviders map:
   mSource=    InsetsSource type=ITYPE_STATUS_BAR frame=[0,0][2280,500] visible=true
EOF
# Android 10 (emulator, API 29, gesture navigation): no mRotation=, and TYPE_* sources that are not what apps get
# (a 132 px TYPE_SIDE_BAR_1 against a 44 px gesture bar); mStable= sits next to the mDock= line the parser reads.
cat > "$tmp/fake/fake-api29.txt" <<'EOF'
WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
  Display: mDisplayId=0
    init=1080x2280 440dpi cur=1080x2280 app=1080x2148 rng=1080x997-2148x2065
  DisplayFrames w=1080 h=2280 r=0
    mStable=[0,83][1080,2236]
    mDock=[0,0][1080,2236]
    mDisplayCutout=WmDisplayCutout{DisplayCutout{insets=Rect(0, 0 - 0, 0) boundingRect={Bounds=[Rect(0, 0 - 0, 0), Rect(0, 0 - 0, 0), Rect(0, 0 - 0, 0), Rect(0, 0 - 0, 0)]}}, mFrameSize=null}
  WindowInsetsStateController
    InsetsState
      InsetsSource type=TYPE_SIDE_BAR_1 frame=[0,2148][1080,2280] visible=true
      InsetsSource type=TYPE_TOP_BAR frame=[0,0][1080,83] visible=false
EOF
# Android 10 in seascape (r=3): the right edge comes from the mDisplayCutout= insets, the left one from mDock=.
cat > "$tmp/fake/fake-api29-seascape.txt" <<'EOF'
WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
  Display: mDisplayId=0
    init=1080x2280 440dpi cur=2280x1080 app=2016x1080 rng=1080x1003-2016x2016
  DisplayFrames w=2280 h=1080 r=3
    mStable=[132,77][2280,1080]
    mDock=[132,77][2280,1080]
    mDisplayCutout=WmDisplayCutout{DisplayCutout{insets=Rect(0, 0 - 132, 0) boundingRect={Bounds=[Rect(0, 0 - 0, 0), Rect(0, 0 - 0, 0), Rect(2148, 457 - 2280, 623), Rect(0, 0 - 0, 0)]}}, mFrameSize=null}
  WindowInsetsStateController
    InsetsState
      InsetsSource type=TYPE_SIDE_BAR_1 frame=[0,0][132,1080] visible=true
      InsetsSource type=TYPE_TOP_BAR frame=[0,0][2280,77] visible=true
EOF
# An exact compare: a wrong density still exits 0 with a self-consistent scale. $1 serial, $2 the expected JSON
# after "device".
expect() {
  out=$(env -i HOME="$tmp" PATH="$tmp/fake" "$(command -v node)" dist/cli.js screenshot --device "$1" --out "$tmp/${1#fake-}.png" 2>"$tmp/err") \
    || fail "screenshot on the fake adb ($1) exited non-zero: $out $(cat "$tmp/err")"
  want="{\"path\":\"$tmp/${1#fake-}.png\",\"device\":\"$1\",$2}"
  [ "$out" = "$want" ] || fail "the $1 fixture gave $out, expected $want"
}
expect fake-api34 '"pixels":{"width":1080,"height":2316},"logical":{"width":384,"height":823.4666666666667},"scale":2.8125,"safeArea":{"top":75,"right":0,"bottom":135,"left":0},"rotation":0'
expect fake-api33 '"pixels":{"width":1080,"height":2280},"logical":{"width":392.72727272727275,"height":829.0909090909091},"scale":2.75,"safeArea":{"top":132,"right":0,"bottom":132,"left":0},"rotation":0'
expect fake-api31 '"pixels":{"width":720,"height":1612},"logical":{"width":360,"height":806},"scale":2,"safeArea":{"top":72,"right":0,"bottom":80,"left":0},"rotation":0'
expect fake-api30 '"pixels":{"width":2280,"height":1080},"logical":{"width":829.0909090909091,"height":392.72727272727275},"scale":2.75,"safeArea":{"top":77,"right":132,"bottom":0,"left":132},"rotation":90'
expect fake-api29 '"pixels":{"width":1080,"height":2280},"logical":{"width":392.72727272727275,"height":829.0909090909091},"scale":2.75,"safeArea":{"top":0,"right":0,"bottom":44,"left":0},"rotation":0'
expect fake-api29-seascape '"pixels":{"width":2280,"height":1080},"logical":{"width":829.0909090909091,"height":392.72727272727275},"scale":2.75,"safeArea":{"top":77,"right":132,"bottom":0,"left":132},"rotation":270'

# 2. A physical device on the default server, if one is listed. Every failure goes through fail, which masks the serial.
list=$(node dist/cli.js devices) || fail "devices exited non-zero: $list"
phone=$(printf '%s' "$list" | node -e '
  const { devices } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const found = devices.find((d) => d.kind === "physical" && d.state === "device");
  if (found) console.log(JSON.stringify({ ...found, named: found.name ? devices.filter((d) => d.name === found.name).length : 0 }));
')
if [ -z "$phone" ]; then
  echo "SKIP: no physical device"
  physical="physical skipped"
else
  serial=$(printf '%s' "$phone" | field id)
  name=$(printf '%s' "$phone" | field name)
  named=$(printf '%s' "$phone" | field named)

  out=$(node dist/cli.js screenshot --device "$serial" --out "$tmp/phone.png" 2>"$tmp/err") \
    || fail "screenshot by serial exited non-zero: $out $(cat "$tmp/err")"
  [ "$(printf '%s' "$out" | field path)" = "$tmp/phone.png" ] || fail "path is not $tmp/phone.png: $out"
  [ "$(printf '%s' "$out" | field device)" = "$serial" ] || fail "device is not $serial: $out"
  png_ok "$tmp/phone.png" "$(printf '%s' "$out" | field pixels.width)" "$(printf '%s' "$out" | field pixels.height)" \
    || fail "$tmp/phone.png is not a whole PNG of the reported size: $out"

  # The K6 metadata against the device's own values, the override when one is set. No $ anchors: adb shell ends lines
  # with \r.
  size=$(adb -s "$serial" shell wm size 2>&1) || fail "adb -s $serial shell wm size failed: $size"
  density=$(adb -s "$serial" shell wm density 2>&1) || fail "adb -s $serial shell wm density failed: $density"
  why=$(printf '%s' "$out" | node -e '
    const out = require("fs").readFileSync(0, "utf8").trimEnd();
    const fail = (reason) => { console.log(reason); process.exit(1); };
    if (out.includes("\n")) fail("stdout is not one line");
    const { pixels, logical, scale, safeArea, rotation } = JSON.parse(out);
    const [size, density] = process.argv.slice(1);
    const read = (text, pattern) => text.match(new RegExp(`Override ${pattern}`)) ?? text.match(new RegExp(`Physical ${pattern}`));
    const wh = read(size, "size: (\\d+)x(\\d+)");
    if (!wh) fail(`no size in: ${size}`);
    const [width, height] = [90, 270].includes(rotation) ? [wh[2], wh[1]] : [wh[1], wh[2]];
    if (pixels.width !== Number(width) || pixels.height !== Number(height)) fail(`pixels are not ${width}x${height} (wm size)`);
    const dpi = read(density, "density: (\\d+)")?.[1];
    if (dpi === undefined) fail(`no density in: ${density}`);
    if (scale !== Number(dpi) / 160) fail(`scale is not ${dpi}/160`);
    for (const axis of ["width", "height"]) {
      if (Math.abs(logical[axis] * scale - pixels[axis]) >= 1e-6) fail(`logical.${axis} * scale is not pixels.${axis}`);
    }
    if (![0, 90, 180, 270].includes(rotation)) fail("rotation is not 0, 90, 180 or 270");
    for (const [edge, value] of Object.entries(safeArea)) {
      if (!Number.isInteger(value) || value < 0) fail(`safeArea.${edge} is not a non-negative integer`);
    }
    if (safeArea.top + safeArea.bottom >= pixels.height || safeArea.left + safeArea.right >= pixels.width) fail("safeArea covers the screen");
  ' "$size" "$density" 2>"$tmp/err") || fail "$why: $out $(cat "$tmp/err")"

  if [ "$named" = 1 ]; then
    res=$(node dist/cli.js screenshot --device "$name" --out "$tmp/byname.png" 2>"$tmp/err") \
      || fail "screenshot by model name $name exited non-zero: $res $(cat "$tmp/err")"
    [ "$(printf '%s' "$res" | field device)" = "$serial" ] || fail "model name $name did not resolve to $serial: $res"
  else
    echo "note: by-name step skipped, $named entries named $name"
  fi
  physical="physical $name $(printf '%s' "$out" | field pixels.width)x$(printf '%s' "$out" | field pixels.height)"
  physical="$physical scale $(printf '%s' "$out" | field scale) rotation $(printf '%s' "$out" | field rotation)"
fi

echo "ok: api29, api29-seascape, api30, api31, api33, api34 fixtures, $physical"
