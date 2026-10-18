#!/bin/sh
# Step 4.4: `tap` (by coordinates and by --text/--id), `swipe`, `text` and `key` on a paired iPhone go to karagoz's
# runner as signed requests: points in the portrait panel with the interface orientation, converted from the tree's
# pixels for every rotation and the mini; element taps match the tree and refuse a target under the software keyboard;
# any Unicode text but control characters; the hardware buttons and the keys that type a character, other names refused
# before anything is sent; every runner failure maps to its code (K42).
# Precondition: macOS. Fake adb, simctl, devicectl and xcodebuild come through ANDROID_HOME and DEVELOPER_DIR under
# env -i, Xcode's preferences through a fake HOME, usbmuxd through USBMUXD_SOCKET_ADDRESS (the fakes in
# smoke/fixtures/runner/).
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iPhones need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; [ -n "$daemon" ] && { kill "$daemon"; wait "$daemon"; } 2>/dev/null; pkill -f "sleep 97\\.44"; pkill -f "runner.cjs $tmp/fake"; rm -rf "$tmp"' EXIT
daemon=
fail() { echo "FAIL: $*"; exit 1; }
is() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; }
code_of() { "$node_bin" -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }

# Fakes, as in smoke 4.3. Scripts call /bin tools by absolute path: env -i leaves no PATH for them.
fake="$tmp/fake"
fixtures=$(pwd)/smoke/fixtures/runner
dev="$tmp/Xcode.app/Contents/Developer"
mkdir -p "$tmp/sdk/platform-tools" "$dev/usr/bin" "$tmp/home/Library/Preferences" "$fake"
cat > "$tmp/sdk/platform-tools/adb" <<FAKE
#!/bin/sh
case "\$*" in
  devices) printf 'List of devices attached\n\n' ;;
  *) exit 0 ;;
esac
FAKE
cat > "$dev/usr/bin/simctl" <<FAKE
#!/bin/sh
echo '{"devices":{}}'
FAKE
cat > "$dev/usr/bin/devicectl" <<FAKE
#!/bin/sh
case "\$*" in
  "list devices --json-output - -q") /bin/cat "$fake/list.json" ;;
  "device info apps --device "*" --json-output - -q") /bin/cat "$fake/apps.json" ;;
  "device install app --device "*" -q") ;;
  "device info displays --device "*" --json-output - -q") /bin/cat "$fake/displays.json" ;;
  *) exit 1 ;;
esac
FAKE
cat > "$dev/usr/bin/xcodebuild" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/xcodebuild"
case "\$*" in
  *build-for-testing*)
    while [ \$# -gt 0 ]; do [ "\$1" = -derivedDataPath ] && dd=\$2; shift; done
    /bin/mkdir -p "\$dd/Build/Products/Debug-iphoneos/KaragozRunner-Runner.app"
    /bin/cp "$fixtures/KaragozRunner.xctestrun" "\$dd/Build/Products/KaragozRunner_iphoneos27.1-arm64.xctestrun"
    ;;
  *test-without-building*)
    while [ \$# -gt 0 ]; do [ "\$1" = -xctestrun ] && xr=\$2; shift; done
    "$node_bin" "$fixtures/runner.cjs" "$fake" "\$xr" & exec /bin/sleep 97.44
    ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$dev/usr/bin/simctl" "$dev/usr/bin/devicectl" "$dev/usr/bin/xcodebuild"
echo '{"result":{"devices":[{"visibilityClass":"default","properties":{"hardware":{"udid":"P1","reality":"physical","platform":"iOS","marketingName":"iPhone 14 Pro Max"},"connection":{"pairingState":"paired","transportType":"wired","tunnelState":"connected"}}}]}}' > "$fake/list.json"
echo '{"result":{"apps":[{"bundleIdentifier":"com.karagozmcp.runner.abcde12345.xctrunner"}]}}' > "$fake/apps.json"
echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>IDEProvisioningTeamByIdentifier</key><dict><key>account-1</key><array><dict><key>isFreeProvisioningTeam</key><false/><key>teamID</key><string>ABCDE12345</string><key>teamName</key><string>Team</string></dict></array></dict></dict></plist>' > "$tmp/home/Library/Preferences/com.apple.dt.Xcode.plist"
k() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$dev" USBMUXD_SOCKET_ADDRESS="UNIX:$tmp/usbmuxd" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
refuses() {
  step=$1 code=$2 text=$3
  shift 3
  if out=$(k "$@"); then fail "$step exited 0: $out"; fi
  is "$step" "$(printf '%s' "$out" | code_of)" "$code"
  [ "$text" = - ] || case "$(printf '%s' "$out" | message_of)" in *"$text"*) ;; *) fail "$step text: $out" ;; esac
}
display() {
  size=
  [ -z "$2" ] || size=",\"nativeSize\":[$2]"
  echo "{\"result\":{\"displays\":[{\"primary\":true,\"pointScale\":${3:-3}$1$size}]}}" > "$fake/displays.json"
}
# sent: the last input the runner got, as "<route> <body>".
sent() { /usr/bin/tail -1 "$fake/inputs"; }
inputs() { /usr/bin/wc -l < "$fake/inputs" | /usr/bin/tr -d ' '; }
k install-runner --device P1 > /dev/null || fail "install-runner on the fake phone failed"
"$node_bin" "$fixtures/usbmuxd.cjs" "$tmp/usbmuxd" "$fake" &
daemon=$!
echo P1 > "$fake/usb"
: > "$fake/inputs"
display ',"currentOrientation":"rot0"' 1290,2796

# 1. Coordinates: pixels / scale, turned into the portrait panel (K35's table) with the interface orientation:
# 0 portrait 1, 90 landscape right 4, 180 upside down 2, 270 landscape left 3; no rotation counts as portrait.
out=$(k tap 645 1398 --device P1) || fail "tap exited non-zero: $out"
is "tap" "$out" '{"device":"P1","x":645,"y":1398}'
is "tap sent" "$(sent)" '/tap {"x":215,"y":466,"orientation":1}'
out=$(k tap 645 1398 --duration 800 --device P1) || fail "long press exited non-zero: $out"
is "long press" "$out" '{"device":"P1","x":645,"y":1398,"duration":800}'
is "long press sent" "$(sent)" '/tap {"x":215,"y":466,"duration":800,"orientation":1}'
# turned <devicectl orientation> <x> <y> <what the runner gets>; devicectl's rot270 is karagoz's rotation 90 (K34).
turned() {
  display ",\"currentOrientation\":\"$1\"" 1290,2796
  k tap "$2" "$3" --device P1 > /dev/null || fail "tap at $1 failed"
  is "tap at $1" "$(sent)" "$4"
}
turned rot270 1800 300 '/tap {"x":330,"y":600,"orientation":4}'
turned rot90 1800 300 '/tap {"x":100,"y":332,"orientation":3}'
turned rot180 300 600 '/tap {"x":330,"y":732,"orientation":2}'
display '' 1290,2796
k tap 1800 300 --device P1 > /dev/null || fail "tap without a rotation failed"
is "no rotation" "$(sent)" '/tap {"x":600,"y":100,"orientation":1}'
display ',"currentOrientation":"rot0"' 1080,2340 2.88
k tap 540 1170 --device P1 > /dev/null || fail "tap on a mini failed"
is "mini" "$(sent)" '/tap {"x":187.5,"y":406.25,"orientation":1}'
display ',"currentOrientation":"rot270"'
before=$(inputs)
refuses "rotated, no panel size" CAPTURE_FAILED "panel size" tap 100 100 --device P1
is "rotated, no panel size: nothing sent" "$(inputs)" "$before"
display ',"currentOrientation":"rot0"' 1290,2796
out=$(k swipe 645 2000 645 600 --device P1) || fail "swipe exited non-zero: $out"
is "swipe" "$out" '{"device":"P1","x1":645,"y1":2000,"x2":645,"y2":600,"duration":300}'
is "swipe sent" "$(sent)" '/swipe {"x1":215,"y1":666.667,"x2":215,"y2":200,"duration":300,"orientation":1}'
k swipe 645 2000 645 600 --duration 1000 --device P1 > /dev/null || fail "slow swipe failed"
is "slow swipe sent" "$(sent)" '/swipe {"x1":215,"y1":666.667,"x2":215,"y2":200,"duration":1000,"orientation":1}'
ok="coordinates, rotations 0/90/180/270/none, mini, no panel size, swipe"

# 2. Element taps against a fixed tree: --id, --text on label and value, invisible direction marks, ambiguity, not
# found, a target under the software keyboard refused, one of the keyboard's keys tapped.
cat > "$fake/tree.json" <<'JSON'
{"root":{"type":2,"label":"Probe","frame":[0,0,430,932],"children":[{"type":4,"frame":[0,0,430,932],"children":[
{"type":9,"label":"Tap me 1","identifier":"tap-button","frame":[16,100,200,44]},
{"type":48,"label":"Row","frame":[16,160,200,40]},{"type":48,"label":"Row","frame":[16,210,200,40]},
{"type":49,"value":"abc","identifier":"name-field","frame":[16,260,398,36]},
{"type":48,"label":"Row 30","frame":[16,700,200,40]},
{"type":19,"frame":[0,600,430,332],"children":[{"type":20,"label":"q","frame":[10,610,40,50]}]}]}]}}
JSON
out=$(k tap --id tap-button --device P1) || fail "tap --id exited non-zero: $out"
is "tap --id" "$out" '{"device":"P1","x":348,"y":366,"element":{"role":"Button","label":"Tap me 1","identifier":"tap-button","bounds":[48,300,648,432]}}'
is "tap --id sent" "$(sent)" '/tap {"x":116,"y":122,"orientation":1}'
out=$(k tap --text abc --duration 600 --device P1) || fail "tap --text on a value exited non-zero: $out"
is "tap --text value" "$(sent)" '/tap {"x":215,"y":278,"duration":600,"orientation":1}'
marked=$(printf '\342\200\216Tap me 1')
k tap --text "$marked" --device P1 > /dev/null || fail "tap --text with a direction mark failed"
is "direction mark" "$(sent)" '/tap {"x":116,"y":122,"orientation":1}'
before=$(inputs)
refuses "ambiguous" ELEMENT_AMBIGUOUS "2 nodes match label or value 'Row'" tap --text Row --device P1
refuses "not found" ELEMENT_NOT_FOUND "no node with identifier 'nope'" tap --id nope --timeout 1000 --device P1
refuses "under the keyboard" ELEMENT_COVERED "hide the keyboard" tap --text 'Row 30' --device P1
is "refused element taps: nothing sent" "$(inputs)" "$before"
k tap --text q --device P1 > /dev/null || fail "tapping a key of the keyboard failed"
is "keyboard key" "$(sent)" '/tap {"x":30,"y":635,"orientation":1}'
ok="$ok, element taps, direction marks, ambiguous, not found, keyboard cover, keyboard key"

# 3. text and key. Any Unicode with newline and tab; other control characters, and keys an iPhone has no counterpart
# for, are refused before anything reaches the runner.
typed=$(printf 'çğ \360\237\230\200\n\tx')
out=$(k text "$typed" --device P1) || fail "text exited non-zero: $out"
is "text" "$out" '{"device":"P1","text":"çğ 😀\n\tx"}'
is "text sent" "$(sent)" '/text {"text":"çğ 😀\n\tx","speed":120}'
before=$(inputs)
refuses "control character" TEXT_UNSUPPORTED "cannot type 'U+0001' on an iPhone" text "$(printf 'a\001')" --device P1
for name in DPAD_UP F1 PAGE_DOWN SHIFT_LEFT; do refuses "key $name" INVALID_ARGS "'$name' has no iPhone key" key $name --device P1; done
refuses "key BACK" INVALID_ARGS "swipe from the left edge" key BACK --device P1
is "refused text and keys: nothing sent" "$(inputs)" "$before"
for case in HOME:3:home POWER:26:lock VOLUME_UP:24:volumeUp VOLUME_DOWN:25:volumeDown; do
  name=${case%%:*} rest=${case#*:}
  out=$(k key "$name" --device P1) || fail "key $name exited non-zero: $out"
  is "key $name" "$out" "{\"device\":\"P1\",\"key\":\"KEYCODE_$name\",\"code\":${rest%%:*}}"
  is "key $name sent" "$(sent)" "/button {\"button\":\"${rest#*:}\"}"
done
for case in A:a 7:0 SPACE:' ' TAB:'\t' ENTER:'\n' ESCAPE:'\u001b' MINUS:-; do
  k key "${case%%:*}" --device P1 > /dev/null || fail "key ${case%%:*} failed"
  is "key ${case%%:*} sent" "$(sent)" "/text {\"text\":\"${case#*:}\",\"speed\":120}"
done
k key DEL --device P1 > /dev/null || fail "key DEL failed"
is "key DEL sent" "$(sent)" "$(printf '/text {"text":"\177","speed":120}')"
ok="$ok, text, control characters, iPhone-less keys, buttons, keys that type"

# 4. The runner's failures; a tap and a ui-tree at the same time are both answered.
for m in event:"did not take the event" xctest:"Failed to synthesize event" private:"update karagoz" close:"closed the connection"; do
  echo "${m%%:*}" > "$fake/runner-mode"
  refuses "runner ${m%%:*}" HELPER_FAILED "${m#*:}" tap 645 1398 --device P1
done
echo hang > "$fake/runner-mode"
t0=$(date +%s)
refuses "runner hangs" HELPER_FAILED "did not answer within 30 s" tap 645 1398 --device P1
[ $(($(date +%s) - t0)) -le 40 ] || fail "hang took $(($(date +%s) - t0)) s"
rm "$fake/runner-mode"
k tap 645 1398 --device P1 > "$tmp/both.tap" & first=$!
k ui-tree --device P1 > "$tmp/both.tree" & second=$!
wait $first || fail "tap beside a ui-tree failed: $(/bin/cat "$tmp/both.tap")"
wait $second || fail "ui-tree beside a tap failed: $(/bin/cat "$tmp/both.tree")"
echo '{"result":{"apps":[]}}' > "$fake/apps.json"
pkill -f "runner.cjs $fake"; rm -f "$fake/runner-port"
refuses "no runner" RUNNER_NOT_INSTALLED "'karagoz install-runner --device P1' (MCP: install_runner)" tap 1 1 --device P1
ok="$ok, runner failures, hang (30s), tap beside ui-tree, not installed"

echo "ok: $ok"
