#!/bin/sh
# Step 1.4: key, tap (a point, a long press, --text or --id), swipe and text each print one JSON line, and bad
# arguments fail with the JSON envelope before any device call. A fake adb covers what a live screen cannot produce.
# Precondition: an emulator is running with state device, its screen on and unlocked, on the image the 1.1-1.3 smokes
# use (Android 16, stock launcher and Settings). Only HOME and BACK are sent; nothing changes a setting, installs or
# rotates anything, and the adb server on the default port is never touched.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

tmp=$(mktemp -d)
id=
# set +e: errexit stays on inside the trap, and a failing adb call would skip the rest.
trap 'set +e; if [ -n "$id" ]; then adb -s "$id" shell input keyevent HOME; adb -s "$id" shell am force-stop com.android.settings; adb -s "$id" shell am force-stop com.google.android.settings.intelligence; fi >/dev/null 2>&1; rm -rf "$tmp"' EXIT
# Prints .error.code, or not-json. The envelope must be exactly one line (K5).
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
# Prints .error.message of a one-line envelope, or not-json.
message_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.message) } catch { console.log("not-json") }
'; }
# Prints one field of a success result (a dotted key such as root.package). Fails unless stdout is one JSON line.
field() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  let value = JSON.parse(out);
  for (const key of process.argv[1].split(".")) value = value?.[key];
  if (value === undefined) process.exit(1);
  console.log(value);
' "$1"; }
# Prints the text of every node of a ui-tree result, one per line, in document order.
texts() { node -e '
  const walk = (node) => [...(node.text === undefined ? [] : [node.text]), ...(node.children ?? []).flatMap(walk)];
  console.log(walk(JSON.parse(require("fs").readFileSync(0, "utf8")).root).join("\n"));
'; }
# Prints the center of the first node of a ui-tree result whose resourceId is $1, as two JSON numbers: "x y".
center() { node -e '
  const find = (node) => (node.resourceId === process.argv[1] ? node : (node.children ?? []).map(find).find(Boolean));
  const node = find(JSON.parse(require("fs").readFileSync(0, "utf8")).root);
  if (!node) process.exit(1);
  const [l, t, r, b] = node.bounds;
  console.log(JSON.stringify((l + r) / 2), JSON.stringify((t + b) / 2));
' "$1"; }
# Reads ui-tree until root.package is $1, for up to $2 seconds; a read that fails counts as not yet. Leaves the last
# read in $tree.
wait_front() {
  end=$(($(date +%s) + $2))
  until tree=$(node dist/cli.js ui-tree --device "$id" 2>/dev/null) && [ "$(printf '%s' "$tree" | field root.package)" = "$1" ]; do
    [ "$(date +%s)" -lt "$end" ] || { echo "FAIL: $1 was not in front within $2 s; the last read: $(printf '%s' "$tree" | field root.package || printf '%s' "$tree")"; exit 1; }
  done
}
# Prints the text of the focused EditText of a ui-tree result; fails when none is focused.
focused_text() { node -e '
  const find = (node) => (node.class === "android.widget.EditText" && node.focused ? node : (node.children ?? []).map(find).find(Boolean));
  const node = find(JSON.parse(require("fs").readFileSync(0, "utf8")).root);
  if (!node) process.exit(1);
  process.stdout.write(`${node.text ?? ""}\n`);
'; }
# Starts Settings at the top of its list and waits until it is in front; leaves the read in $tree. Its search runs in
# the Settings task from another package and survives am start -S (K25), so it is stopped first.
settings_top() {
  adb -s "$id" shell am force-stop com.google.android.settings.intelligence
  adb -s "$id" shell am start -W -S -a android.settings.SETTINGS >/dev/null
  wait_front com.android.settings 10
}
# Fails unless `node dist/cli.js` with the arguments after $2 exits non-zero with a one-line envelope whose code is $1
# and, when $2 is not empty, whose message is exactly $2.
refuses() {
  want=$1 msg=$2
  shift 2
  if got=$(node dist/cli.js "$@" 2>/dev/null); then echo "FAIL: $* exited 0: $got"; exit 1; fi
  [ "$(printf '%s' "$got" | code_of)" = "$want" ] || { echo "FAIL: $*: expected $want, got: $got"; exit 1; }
  [ -z "$msg" ] || [ "$(printf '%s' "$got" | message_of)" = "$msg" ] \
    || { echo "FAIL: $*: expected the message '$msg', got: $got"; exit 1; }
}

# 1. The first ready emulator. Every live call names it, so a second device cannot cause DEVICE_AMBIGUOUS.
list=$(node dist/cli.js devices) || { echo "FAIL: devices exited non-zero: $list"; exit 1; }
id=$(printf '%s' "$list" | node -e '
  const found = JSON.parse(require("fs").readFileSync(0, "utf8")).devices.find((d) => d.kind === "emulator" && d.state === "device");
  if (!found) process.exit(1);
  console.log(found.id);
') || { echo "FAIL: no ready emulator in: $list (is one running? emulator -avd <name>)"; exit 1; }

# 2. Arguments. Each fails before any device call.
refuses INVALID_ARGS "'key' needs <key>" key
refuses INVALID_ARGS "unknown key 'NOPE'; use a KeyEvent name such as HOME, BACK or ENTER, or a code from 1 to 340" key NOPE
refuses INVALID_ARGS "unexpected argument 'extra'" key HOME extra
refuses INVALID_ARGS "unexpected argument 'extra'" devices extra
refuses INVALID_ARGS "'tap' takes <x> <y>, --text or --id" tap
refuses INVALID_ARGS "'tap' needs <x> <y>" tap 5
refuses INVALID_ARGS "'tap' takes <x> <y>, --text or --id" tap 1 2 --text x
refuses INVALID_ARGS "'tap' takes <x> <y>, --text or --id" tap --text x --id y
refuses INVALID_ARGS "--timeout needs --text or --id" tap 1 2 --timeout 5
refuses INVALID_ARGS "--timeout must be a whole number of milliseconds (got '1.5')" tap --text x --timeout 1.5
refuses INVALID_ARGS "<y> must be a non-negative number (got 'x')" tap 1 x
refuses INVALID_ARGS "unexpected argument '3'" tap 1 2 3
refuses INVALID_ARGS "<x> must be a non-negative number (got '1e3')" tap 1e3 5
refuses INVALID_ARGS "'swipe' needs <x1> <y1> <x2> <y2>" swipe 1 2 3
refuses INVALID_ARGS "'tap' does not take the option '--out'" tap 1 2 --out x
refuses INVALID_ARGS "--duration must be a whole number of milliseconds (got '1.5')" tap 1 2 --duration 1.5
refuses INVALID_ARGS "'key' does not take the option '--duration'" key HOME --duration 5
refuses INVALID_ARGS "'text' needs <text>" text
refuses INVALID_ARGS "'text' needs <text>" text ''
refuses INVALID_ARGS "unexpected argument 'b'" text a b
refuses TEXT_UNSUPPORTED "cannot type 'ğ' (U+011F): Android's input text types only printable ASCII, newline, tab, ç, Ç and ß; nothing was typed" text 'ağ' --device "$id"

# 3. key: four spellings of HOME.
want="{\"device\":\"$id\",\"key\":\"KEYCODE_HOME\",\"code\":3}"
for key in HOME home KEYCODE_HOME 3; do
  out=$(node dist/cli.js key "$key" --device "$id") || { echo "FAIL: key $key exited non-zero: $out"; exit 1; }
  [ "$out" = "$want" ] || { echo "FAIL: key $key printed $out, expected $want"; exit 1; }
done
home=$(adb -s "$id" shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1)
case $home in */*) ;; *) echo "FAIL: resolve-activity named no launcher activity: $home"; exit 1 ;; esac
tree=$(node dist/cli.js ui-tree --device "$id") || { echo "FAIL: ui-tree exited non-zero: $tree"; exit 1; }
front=$(printf '%s' "$tree" | field root.package) || { echo "FAIL: ui-tree printed no root.package: $tree"; exit 1; }
[ "$front" = "${home%%/*}" ] || { echo "FAIL: after key HOME the front package is $front, not the launcher ${home%%/*}"; exit 1; }

# 4. Long press: a held touch on empty workspace opens the launcher's popup; a failed one would be a tap on nothing.
node dist/cli.js key HOME --device "$id" >/dev/null
out=$(node dist/cli.js tap 540 1100 --duration 1000 --device "$id") || { echo "FAIL: tap --duration exited non-zero: $out"; exit 1; }
want="{\"device\":\"$id\",\"x\":540,\"y\":1100,\"duration\":1000}"
[ "$out" = "$want" ] || { echo "FAIL: tap --duration printed $out, expected $want"; exit 1; }
tree=$(node dist/cli.js ui-tree --device "$id") || { echo "FAIL: ui-tree exited non-zero: $tree"; exit 1; }
printf '%s' "$tree" | texts | grep -qx Widgets \
  || { echo "FAIL: no node with the text Widgets after the long press: $(printf '%s' "$tree" | texts | tr '\n' '|')"; exit 1; }
node dist/cli.js key BACK --device "$id" >/dev/null

# 5. tap: the center of the Settings search bar opens the search, a separate app.
settings_top
point=$(printf '%s' "$tree" | center com.android.settings:id/search_bar_title) \
  || { echo "FAIL: no com.android.settings:id/search_bar_title in Settings: $(printf '%s' "$tree" | texts | tr '\n' '|')"; exit 1; }
cx=${point% *}
cy=${point#* }
out=$(node dist/cli.js tap "$cx" "$cy" --device "$id") || { echo "FAIL: tap exited non-zero: $out"; exit 1; }
want="{\"device\":\"$id\",\"x\":$cx,\"y\":$cy}"
[ "$out" = "$want" ] || { echo "FAIL: tap printed $out, expected $want"; exit 1; }
wait_front com.google.android.settings.intelligence 10

# 6. text: %s and a quote arrive literally. The 2 s wait: text typed as a field appears loses characters (K25).
end=$(($(date +%s) + 10))
until tree=$(node dist/cli.js ui-tree --device "$id" 2>/dev/null) && printf '%s' "$tree" | focused_text >/dev/null; do
  [ "$(date +%s)" -lt "$end" ] || { echo "FAIL: no focused EditText in the search within 10 s"; exit 1; }
done
sleep 2
out=$(node dist/cli.js text "it's 100%s ok" --device "$id") || { echo "FAIL: text exited non-zero: $out"; exit 1; }
want="{\"device\":\"$id\",\"text\":\"it's 100%s ok\"}"
[ "$out" = "$want" ] || { echo "FAIL: text printed $out, expected $want"; exit 1; }
tree=$(node dist/cli.js ui-tree --device "$id") || { echo "FAIL: ui-tree exited non-zero: $tree"; exit 1; }
typed=$(printf '%s' "$tree" | focused_text) || { echo "FAIL: no focused EditText after typing"; exit 1; }
[ "$typed" = "it's 100%s ok" ] || { echo "FAIL: the search field reads '$typed', expected 'it's 100%s ok'"; exit 1; }

# 7. swipe: a slow drag up moves the Settings list, restarted at its top.
settings_top
before=$(printf '%s' "$tree" | texts)
out=$(node dist/cli.js swipe 540 1800 540 800 --duration 1000 --device "$id") || { echo "FAIL: swipe exited non-zero: $out"; exit 1; }
want="{\"device\":\"$id\",\"x1\":540,\"y1\":1800,\"x2\":540,\"y2\":800,\"duration\":1000}"
[ "$out" = "$want" ] || { echo "FAIL: swipe printed $out, expected $want"; exit 1; }
tree=$(node dist/cli.js ui-tree --device "$id") || { echo "FAIL: ui-tree exited non-zero: $tree"; exit 1; }
[ "$(printf '%s' "$tree" | texts)" != "$before" ] || { echo "FAIL: the Settings texts did not change after the swipe"; exit 1; }

# 8. Without --duration, swipe states Android's own 300 ms.
out=$(node dist/cli.js swipe 540 800 540 1800 --device "$id") || { echo "FAIL: swipe exited non-zero: $out"; exit 1; }
want="{\"device\":\"$id\",\"x1\":540,\"y1\":800,\"x2\":540,\"y2\":1800,\"duration\":300}"
[ "$out" = "$want" ] || { echo "FAIL: swipe printed $out, expected $want"; exit 1; }

# 9. Element taps: by text, by id suffix, and a missing label with and without --timeout.
settings_top
out=$(node dist/cli.js tap --text 'Search Settings' --device "$id") || { echo "FAIL: tap --text exited non-zero: $out"; exit 1; }
[ "$(printf '%s' "$out" | field element.text)" = 'Search Settings' ] || { echo "FAIL: tap --text tapped another node: $out"; exit 1; }
printf '%s' "$out" | node -e '
  const { x, y, element: { bounds: [l, t, r, b] } } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(x === (l + r) / 2 && y === (t + b) / 2 ? 0 : 1);
' || { echo "FAIL: tap --text did not tap the center of element.bounds: $out"; exit 1; }
wait_front com.google.android.settings.intelligence 10
settings_top
out=$(node dist/cli.js tap --id search_bar_title --device "$id") || { echo "FAIL: tap --id exited non-zero: $out"; exit 1; }
wait_front com.google.android.settings.intelligence 10
settings_top
refuses ELEMENT_NOT_FOUND '' tap --text karagoz-no-such-label --device "$id"
case $(printf '%s' "$got" | message_of) in *'(1 read in '*) ;; *) echo "FAIL: ELEMENT_NOT_FOUND does not say 1 read: $got"; exit 1 ;; esac
start=$(date +%s)
refuses ELEMENT_NOT_FOUND '' tap --text karagoz-no-such-label --timeout 3000 --device "$id"
[ $(($(date +%s) - start)) -ge 3 ] || { echo "FAIL: --timeout 3000 gave up within 3 s: $got"; exit 1; }
reads=$(printf '%s' "$got" | message_of | sed -n 's/.*(\([0-9]*\) reads in .*/\1/p')
[ "${reads:-0}" -ge 2 ] || { echo "FAIL: --timeout 3000 read fewer than 2 times: $got"; exit 1; }

# 10. Against a fake adb. ANDROID_HOME makes $tmp/sdk/platform-tools/adb karagoz's first adb candidate.
fake=$tmp/fake
mkdir -p "$tmp/sdk/platform-tools" "$fake"
cat > "$tmp/sdk/platform-tools/adb" <<'FAKE'
#!/bin/sh
# Fake adb for smoke 1.4: answers from $FAKE and records every input call. A text starting with FAIL fails the way
# input does on a character it cannot type.
case "$*" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n\n' ;;
  *'exec-out uiautomator dump /dev/tty') cat "$FAKE/dump" ;;
  *'shell dumpsys window -a InputMethod') cat "$FAKE/ime" ;;
  *'shell dumpsys accessibility') echo 'ACCESSIBILITY MANAGER (dumpsys accessibility)' ;;
  *"shell input 'text' 'FAIL"*) echo 'java.lang.NullPointerException: Attempt to get length of null array' >&2; exit 255 ;;
  *"shell input 'tap' '7' '7'")
    { echo; echo "Exception occurred while executing 'tap':"; echo 'java.lang.SecurityException: Injecting input events requires the caller (or the source of the instrumentation, if any) to have the INJECT_EVENTS permission.'; } >&2
    exit 255 ;;
  *"shell input 'keyevent' '82'") echo 'java.lang.SecurityException: Injecting to another application requires INJECT_EVENTS permission' >&2; exit 1 ;;
  *"shell input 'text' 'BLOCK"*)
    { echo; echo "Exception occurred while executing 'text':"; echo 'java.lang.SecurityException: Injecting input events requires the caller (or the source of the instrumentation, if any) to have the INJECT_EVENTS permission.'; } >&2
    exit 255 ;;
  *'shell input '*) echo "$*" >> "$FAKE/input" ;;
  *) echo "fake adb: unexpected arguments: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb"
# A hidden keyboard as the device prints it with Settings in front: a stale region, and a visible window after it.
cat > "$tmp/ime-hidden" <<'FAKE'
WINDOW MANAGER WINDOWS (dumpsys window windows)
  Window #0 Window{a94b01 u0 InputMethod}:
    mViewVisibility=0x8 mHaveFrame=true mObscured=false
    touchable region=SkRegion((0,63,1080,2400))
    isOnScreen=false
    isVisible=false

  Hiding System Alert Windows:
  #0 Window{584ca95 u0 com.example/com.example.MainActivity}:
    isOnScreen=true
    isVisible=true

  mInputMethodWindow=Window{a94b01 u0 InputMethod}
FAKE
cat > "$tmp/ime-shown" <<'FAKE'
WINDOW MANAGER WINDOWS (dumpsys window windows)
  Window #0 Window{a94b01 u0 InputMethod}:
    mViewVisibility=0x0 mHaveFrame=true mObscured=false
    touchable region=SkRegion((0,63,1080,2400))
    isOnScreen=true
    isVisible=true

FAKE
# Writes the dump the fake returns: a com.example root holding the <node> elements in $1.
dump() {
  printf '%s' "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\"><node class=\"android.widget.FrameLayout\" package=\"com.example\" bounds=\"[0,0][1080,2400]\">$1</node></hierarchy>" > "$fake/dump"
}
# Runs karagoz against the fake with the keyboard text in file $1 and the arguments after it. Sets $got.
fake_run() {
  cp "$1" "$fake/ime"
  shift
  rm -f "$fake/input"
  got=$(ANDROID_HOME="$tmp/sdk" FAKE="$fake" node dist/cli.js "$@" --device emulator-5554 2>/dev/null)
}
# Fails unless $got is a one-line envelope with code $2 and the message $3, or a message starting with $3 when $4 is
# prefix. $1: the fixture.
error_is() {
  [ "$(printf '%s' "$got" | code_of)" = "$2" ] || { echo "FAIL: fixture $1: expected $2, got: $got"; exit 1; }
  msg=$(printf '%s' "$got" | message_of)
  if [ "$4" = prefix ]; then
    case $msg in "$3"*) ;; *) echo "FAIL: fixture $1: the message does not start with '$3': $got"; exit 1 ;; esac
  else
    [ "$msg" = "$3" ] || { echo "FAIL: fixture $1: expected the message '$3', got: $got"; exit 1; }
  fi
}
# Fails unless the fake recorded exactly the input call $2, or none when $2 is empty. $1: the fixture.
input_is() {
  if [ -z "$2" ]; then
    [ ! -e "$fake/input" ] || { echo "FAIL: fixture $1 sent input: $(cat "$fake/input")"; exit 1; }
  else
    [ "$(cat "$fake/input" 2>/dev/null)" = "$2" ] \
      || { echo "FAIL: fixture $1: expected the input call $2, got: $(cat "$fake/input" 2>/dev/null)"; exit 1; }
  fi
}

# a. Two nodes carry the label: both are named, and nothing is tapped.
dump '<node class="android.widget.TextView" text="Dark theme" bounds="[84,1263][298,1320]" /><node class="android.widget.Switch" text="Dark theme" bounds="[859,1254][996,1380]" />'
if fake_run "$tmp/ime-hidden" tap --text 'Dark theme'; then echo "FAIL: fixture a exited 0: $got"; exit 1; fi
error_is a ELEMENT_AMBIGUOUS "2 nodes match text or contentDesc 'Dark theme': android.widget.TextView [84,1263,298,1320], android.widget.Switch [859,1254,996,1380]; tap one by its coordinates"
input_is a ''

# b. The center lies in the visible keyboard's touchable region: refused, nothing tapped.
dump '<node class="android.widget.Button" text="Bottom" bounds="[0,2074][1080,2200]" />'
if fake_run "$tmp/ime-shown" tap --text Bottom; then echo "FAIL: fixture b exited 0: $got"; exit 1; fi
error_is b ELEMENT_COVERED "'Bottom' at (540, 2137) is under the on-screen keyboard; hide it with karagoz key BACK, or tap another point"
input_is b ''

# c. The same region while the keyboard is hidden is stale: tapped.
fake_run "$tmp/ime-hidden" tap --text Bottom || { echo "FAIL: fixture c exited non-zero: $got"; exit 1; }
input_is c "-s emulator-5554 shell input 'tap' '540' '2137'"

# d. A node with no area never matches.
dump '<node class="android.widget.Button" text="Save" bounds="[0,0][0,0]" />'
if fake_run "$tmp/ime-hidden" tap --text Save; then echo "FAIL: fixture d exited 0: $got"; exit 1; fi
error_is d ELEMENT_NOT_FOUND "no node with text or contentDesc 'Save' in com.example (1 read in " prefix
input_is d ''

# e. --id matches the part after :id/, and --duration holds the touch; a longer id does not match.
dump '<node class="android.widget.Button" resource-id="com.example:id/save" bounds="[0,211][1080,337]" />'
fake_run "$tmp/ime-hidden" tap --id save || { echo "FAIL: fixture e exited non-zero: $got"; exit 1; }
input_is e "-s emulator-5554 shell input 'tap' '540' '274'"
fake_run "$tmp/ime-hidden" tap --id save --duration 700 || { echo "FAIL: fixture e with --duration exited non-zero: $got"; exit 1; }
input_is e "-s emulator-5554 shell input 'swipe' '540' '274' '540' '274' '700'"
dump '<node class="android.widget.Button" resource-id="com.example:id/save2" bounds="[0,211][1080,337]" />'
if fake_run "$tmp/ime-hidden" tap --id save; then echo "FAIL: fixture e with save2 exited 0: $got"; exit 1; fi
error_is e ELEMENT_NOT_FOUND "no node with resourceId 'save' or ending in ':id/save' in com.example (1 read in " prefix

# f. A text whose second chunk fails keeps the error's code and says how much was typed.
long=$(node -p '"a".repeat(100)')
if fake_run "$tmp/ime-hidden" text "${long}FAIL"; then echo "FAIL: fixture f exited 0: $got"; exit 1; fi
error_is f ADB_FAILED "java.lang.NullPointerException: Attempt to get length of null array; 100 of 104 characters were typed before this"
input_is f "-s emulator-5554 shell input 'text' '$long'"

# g. Invisible direction marks (here U+200E, as raw UTF-8) count on neither side; the element keeps them; case counts.
lrm=$(printf '\342\200\216')
dump "<node class=\"android.widget.TextView\" text=\"${lrm}Buds${lrm}\" bounds=\"[0,400][1080,500]\" />"
fake_run "$tmp/ime-hidden" tap --text Buds || { echo "FAIL: fixture g exited non-zero: $got"; exit 1; }
input_is g "-s emulator-5554 shell input 'tap' '540' '450'"
[ "$(printf '%s' "$got" | field element.text)" = "${lrm}Buds${lrm}" ] || { echo "FAIL: fixture g: element.text lost its marks: $got"; exit 1; }
fake_run "$tmp/ime-hidden" tap --text "${lrm}Buds" || { echo "FAIL: fixture g with a marked label exited non-zero: $got"; exit 1; }
input_is g "-s emulator-5554 shell input 'tap' '540' '450'"
if fake_run "$tmp/ime-hidden" tap --text buds; then echo "FAIL: fixture g with buds exited 0: $got"; exit 1; fi
error_is g ELEMENT_NOT_FOUND "no node with text or contentDesc 'buds' in com.example (1 read in " prefix
input_is g ''

# h. A device that denies INJECT_EVENTS to shell, API 31+ form: INPUT_BLOCKED instead of adb's stack trace.
blocked='the device does not let adb inject input (SecurityException: INJECT_EVENTS permission); on Xiaomi, Redmi and POCO turn on Developer options > USB debugging (Security settings), on vivo and iQOO turn on USB simulated click; retrying does not help'
if fake_run "$tmp/ime-hidden" tap 7 7; then echo "FAIL: fixture h exited 0: $got"; exit 1; fi
error_is h INPUT_BLOCKED "$blocked"

# i. The API <= 30 form (exit 1), and text keeps its suffix: the denial comes before any character.
if fake_run "$tmp/ime-hidden" key MENU; then echo "FAIL: fixture i exited 0: $got"; exit 1; fi
error_is i INPUT_BLOCKED "$blocked"
if fake_run "$tmp/ime-hidden" text BLOCKme; then echo "FAIL: fixture i with text exited 0: $got"; exit 1; fi
error_is i INPUT_BLOCKED "$blocked; 0 of 7 characters were typed before this"

echo "ok: $id, key 3, long press popup, tap into search, text 13 chars, swipe moved, element taps, direction marks, input blocked"
