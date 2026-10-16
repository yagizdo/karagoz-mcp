#!/bin/sh
# Step 2.4: key, tap (a point, a long press, --id), text and swipe on a physical phone, through its Settings app and
# Settings search: each verb exits 0 with its JSON line and the screen shows its effect; an ambiguous and a missing
# element are refused; the keyboard reports the touchable region ELEMENT_COVERED reads.
# Precondition: the build only; a phone is optional, and no emulator is needed. If a phone is used: screen on and
# unlocked, no other UiAutomation client connected, and a Settings app whose home page has a search entry (a clickable
# node whose resource id, or failing that whose content description, contains "search").
# What reaches a phone: reads (`adb devices`, the getprop of `devices`, `settings get`, `dumpsys power`, `dumpsys window
# policy`, `dumpsys window -a InputMethod`, `dumpsys window windows`, `dumpsys accessibility`, `cmd package
# resolve-activity`, `pidof uiautomator`, `wm size`); `am start -W -a android.settings.SETTINGS`; karagoz `ui-tree`,
# `key` (HOME, BACK, DEL only), `tap`, `swipe` and `text` into the Settings search field; on exit, once input was sent,
# `adb shell input keyevent` BACK three times and HOME. It writes no setting, installs nothing, never presses ENTER and
# never taps a search result, so the search keeps no history. It leaves the phone on the home screen. The adb server
# on the default port is never stopped or restarted.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

tmp=$(mktemp -d)
serial=
sent=
# set +e: errexit stays on inside the trap. Once input was sent: close the search without submitting, then go home.
trap 'set +e; rm -rf "$tmp"; if [ -n "$sent" ]; then for code in 4 4 4 3; do adb -s "$serial" shell input keyevent "$code"; done; fi >/dev/null 2>&1' EXIT
# Prints one field of a success result (a dotted key such as element.resourceId). Fails unless stdout is one JSON line.
field() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  let value = JSON.parse(out);
  for (const key of process.argv[1].split(".")) value = value?.[key];
  if (value === undefined) process.exit(1);
  console.log(value);
' "$1"; }
# Prints .error.code of a one-line envelope, not-one-line or not-json. Never the message: it can quote a label.
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
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
# Sets value to one `settings get`, without the \r of devices that lack shell protocol v2. Not called inside
# $(...): fail would only leave the subshell, and errexit would end the script with no FAIL line.
setting() {
  value=$(adb -s "$serial" shell settings get "$1" "$2" 2>/dev/null) || fail "adb -s $serial shell settings get $1 $2 failed"
  value=$(printf "%s" "$value" | tr -d "\\r")
}

# Helpers below each read one device output on stdin and print only booleans, counts or bounds (search_entry also
# prints a resource id suffix, for a variable, never for echo). Every one strips \r first: a device without shell
# protocol v2 ends lines with \r\n.

# Prints "<isVisible> <rects>" for the IME's own block of `dumpsys window -a InputMethod` (input.ts's block rule):
# "true 1", "false 0". rects counts rectangles of positive size inside [0, $1]; $1 is the screen's longer side.
ime_state() { node -e '
  const out = require("fs").readFileSync(0, "utf8").replaceAll("\r", "");
  const max = Number(process.argv[1]);
  const block = /Window\{[^}\n]* InputMethod\}:\n([\s\S]*?)(?:\n[ \t]*\n|$)/.exec(out)?.[1] ?? "";
  const visible = /^\s*isVisible=true$/m.test(block);
  const region = /touchable region=SkRegion\((.*)\)$/m.exec(block)?.[1] ?? "";
  const rects = [...region.matchAll(/\((-?\d+),(-?\d+),(-?\d+),(-?\d+)\)/g)].map((m) => m.slice(1).map(Number))
    .filter(([l, t, r, b]) => l >= 0 && t >= 0 && r <= max && b <= max && r > l && b > t);
  console.log(visible, visible ? rects.length : 0);
' "$1"; }

# Prints true when `dumpsys power` says mWakefulness=Awake (Asleep, Dozing and Dreaming are not).
awake() { node -e '
  const out = require("fs").readFileSync(0, "utf8").replaceAll("\r", "");
  console.log(/^\s*mWakefulness=(\w+)/m.exec(out)?.[1] === "Awake");
'; }

# Prints the first `showing=` value of `dumpsys window policy` (KeyguardServiceDelegate), or missing. Line-anchored so
# showingAndNotOccluded=, mIsShowing= and mShowingDream= never match.
keyguard_showing() { node -e '
  const out = require("fs").readFileSync(0, "utf8").replaceAll("\r", "");
  console.log(/^\s*showing=(\w+)/m.exec(out)?.[1] ?? "missing");
'; }

# Prints the number of PopupWindow windows in `dumpsys window windows`: header lines only, so mCurrentFocus= and
# mFocusedWindow= lines naming the same window do not count twice.
popups() { node -e '
  const out = require("fs").readFileSync(0, "utf8").replaceAll("\r", "");
  console.log((out.match(/^\s*Window #\d+ Window\{[^}\n]* PopupWindow:[^}\n]*\}:/gm) ?? []).length);
'; }

# On a ui-tree result: the focused editable node (class ending in EditText or AutoCompleteTextView, focused true).
#   focused box          prints its bounds "l t r b"
#   focused is <text>    prints true when its text is exactly <text>
#   focused has <text>   prints true when its text contains <text>
# Exits 1 when no such node exists, so `x=$(... | focused box) || fail ...` reads as "no focused field".
focused() { node -e '
  const [mode, want] = process.argv.slice(1);
  const editable = (n) => typeof n.class === "string" && /(EditText|AutoCompleteTextView)$/.test(n.class);
  const find = (n) => (editable(n) && n.focused === true ? n : (n.children ?? []).map(find).find(Boolean));
  const node = find(JSON.parse(require("fs").readFileSync(0, "utf8")).root);
  if (!node) process.exit(1);
  const text = node.text ?? "";
  console.log(mode === "box" ? node.bounds.join(" ") : mode === "is" ? text === want : text.includes(want));
' "$@"; }

# On a ui-tree result: the search entry, the first clickable node with non-zero bounds whose resourceId contains
# "search" (any case) and whose class is not editable; failing that, the first such node whose contentDesc contains
# "search" (One UI 6.1's Settings search is a Button with no id and a content description only). Prints
# "<x> <y> id <suffix>" (the part after :id/, the whole id when it has none) or "<x> <y> text <contentDesc>". Exits 1
# when there is none. The target is last so `read` keeps it whole.
search_entry() { node -e '
  const nodes = [];
  const walk = (n) => { nodes.push(n); (n.children ?? []).forEach(walk); };
  walk(JSON.parse(require("fs").readFileSync(0, "utf8")).root);
  const area = (n) => Array.isArray(n.bounds) && n.bounds[2] > n.bounds[0] && n.bounds[3] > n.bounds[1];
  const editable = (n) => typeof n.class === "string" && /(EditText|AutoCompleteTextView)$/.test(n.class);
  const has = (n, key) => typeof n[key] === "string" && n[key].toLowerCase().includes("search");
  const tappable = nodes.filter((n) => n.clickable === true && area(n) && !editable(n));
  const entry = tappable.find((n) => has(n, "resourceId")) ?? tappable.find((n) => has(n, "contentDesc"));
  if (!entry) process.exit(1);
  const id = entry.resourceId;
  const target = !has(entry, "resourceId") ? `text ${entry.contentDesc}`
    : `id ${id.includes(":id/") ? id.slice(id.indexOf(":id/") + 4) : id}`;
  const [l, t, r, b] = entry.bounds;
  console.log((l + r) / 2, (t + b) / 2, target);
'; }

# On a ui-tree result: how many nodes with an area `tap --id $1` matches (karagoz's own rule).
id_count() { node -e '
  let count = 0;
  const walk = (n) => {
    const b = n.bounds;
    const hit = typeof n.resourceId === "string" && (n.resourceId === process.argv[1] || n.resourceId.endsWith(`:id/${process.argv[1]}`));
    if (hit && Array.isArray(b) && b[2] > b[0] && b[3] > b[1]) count++;
    (n.children ?? []).forEach(walk);
  };
  walk(JSON.parse(require("fs").readFileSync(0, "utf8")).root);
  console.log(count);
' "$1"; }

# On a ui-tree result: a sha1 of every text, contentDesc and bounds in document order. Compared, never printed, so no
# label leaves the phone; bounds make a scroll count even when the same rows stay on screen.
screen_sum() { node -e '
  const walk = (n) => [n.text, n.contentDesc, String(n.bounds), ...(n.children ?? []).flatMap(walk)];
  const all = walk(JSON.parse(require("fs").readFileSync(0, "utf8")).root).filter((v) => typeof v === "string");
  console.log(require("crypto").createHash("sha1").update(all.join("\n")).digest("hex"));
'; }

# Runs karagoz on the phone with the arguments; sets out. A failure prints the verb and the error code only.
run() {
  out=$(node dist/cli.js "$@" --device "$serial" 2>/dev/null) || fail "$1 exited non-zero: $(printf '%s' "$out" | code_of)"
}
# Fails unless karagoz with the arguments after $1 exits non-zero with a one-line envelope whose code is $1; sets out.
refuses() {
  want=$1
  shift
  if out=$(node dist/cli.js "$@" --device "$serial" 2>/dev/null); then fail "$1 exited 0; expected $want"; fi
  [ "$(printf '%s' "$out" | code_of)" = "$want" ] || fail "$1: expected $want, got $(printf '%s' "$out" | code_of)"
}
# Sets pkg to the package of the activity `cmd package resolve-activity` picks for the arguments.
resolve() {
  pkg=$(adb -s "$serial" shell cmd package resolve-activity --brief "$@" 2>/dev/null) \
    || fail "adb -s $serial shell cmd package resolve-activity $* failed"
  pkg=$(printf '%s' "$pkg" | tr -d '\r' | tail -n 1)
  pkg=${pkg%%/*}
  case $pkg in '' | *' '* | android) fail "resolve-activity $* found no single activity" ;; esac
}
# FAILs unless the phone is awake and past its lock screen: keys would land in the PIN field (README).
lock_guard() {
  power=$(adb -s "$serial" shell dumpsys power 2>/dev/null) || fail "adb -s $serial shell dumpsys power failed"
  policy=$(adb -s "$serial" shell dumpsys window policy 2>/dev/null) || fail "adb -s $serial shell dumpsys window policy failed"
  on=$(printf '%s' "$power" | awake)
  shown=$(printf '%s' "$policy" | keyguard_showing)
  [ "$shown" != missing ] || fail "dumpsys window policy has no showing= line"
  [ "$on" = true ] && [ "$shown" = false ] || fail "the phone is locked or its screen is off; unlock it and rerun"
}

# Conditions for wait_until. Each returns a status and never prints; a failed read is "not yet". tree, state and
# count keep the last read.
read_tree() { tree=$(node dist/cli.js ui-tree --device "$serial" 2>/dev/null); }
front() { read_tree && [ "$(printf '%s' "$tree" | field root.package)" = "$1" ]; }
has_field() { read_tree && printf '%s' "$tree" | focused box >/dev/null; }
field_is() { read_tree && [ "$(printf '%s' "$tree" | focused is "$1")" = true ]; }
field_lacks() { read_tree && [ "$(printf '%s' "$tree" | focused has "$1")" = false ]; }
screen_not() { read_tree && [ "$(printf '%s' "$tree" | screen_sum)" != "$1" ]; }
# $1 is a case pattern for ime_state's output, such as 'false *'.
ime_is() {
  dump=$(adb -s "$serial" shell dumpsys window -a InputMethod 2>/dev/null) || return 1
  state=$(printf '%s' "$dump" | ime_state "$height")
  case $state in $1) ;; *) false ;; esac
}
popup_count() {
  dump=$(adb -s "$serial" shell dumpsys window windows 2>/dev/null) || return 1
  count=$(printf '%s' "$dump" | popups)
}
popups_above() { popup_count && [ "$count" -gt "$1" ]; }
popups_at_most() { popup_count && [ "$count" -le "$1" ]; }
# Retries the condition $2 (a command string) until it holds, for up to $1 seconds, then returns 1. The deadline is
# checked before each try, so one slow ui-tree read (up to 6 s on the Infinix) can overrun it.
poll() {
  end=$(($(date +%s) + $1))
  until eval "$2"; do
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep 1
  done
}
# poll, then FAIL with $3.
wait_until() { poll "$1" "$2" || fail "$3"; }
# Sends key $2, $1 times.
keys() {
  i=0
  while [ "$i" -lt "$1" ]; do
    run key "$2"
    i=$((i + 1))
  done
}

# 2. A physical phone, if one is listed.
list=$(node dist/cli.js devices 2>/dev/null) || fail "devices exited non-zero: $(printf '%s' "$list" | code_of)"
phone=$(printf '%s' "$list" | node -e '
  const { devices } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const found = devices.find((d) => d.kind === "physical" && d.state === "device");
  if (found) console.log(found.id);
')
if [ -z "$phone" ]; then
  echo "SKIP: no physical device"
  echo "ok: physical skipped"
  exit 0
fi
serial=$phone

# 3. Guards. A dump unbinds enabled services and can take one off its accessibility shortcut for good (K24 2.3 note).
setting secure enabled_accessibility_services
case $value in
  '' | null) ;;
  *) echo "SKIP: accessibility services are enabled on the phone"; echo "ok: physical skipped"; exit 0 ;;
esac
a11y=$(adb -s "$serial" shell dumpsys accessibility 2>/dev/null) || fail "adb -s $serial shell dumpsys accessibility failed"
case $a11y in *'Ui Automation['*)
  fail "another UiAutomation client is connected (dumpsys accessibility shows Ui Automation[); stop Appium, Maestro or uiautomator events and rerun" ;;
esac
lock_guard
setting system accelerometer_rotation
accel=$value
setting system user_rotation
user=$value
size=$(adb -s "$serial" shell wm size 2>/dev/null) || fail "adb -s $serial shell wm size failed"
dims=$(printf '%s' "$size" | node -e '
  const last = [...require("fs").readFileSync(0, "utf8").matchAll(/(\d+)x(\d+)/g)].at(-1);
  if (!last) process.exit(1);
  const [w, h] = [Number(last[1]), Number(last[2])];
  console.log(Math.min(w, h), Math.max(w, h));
') || fail "wm size printed no WxH"
read -r width height <<EOF
$dims
EOF
resolve -a android.intent.action.MAIN -c android.intent.category.HOME
launcher=$pkg
resolve -a android.settings.SETTINGS
settings=$pkg

# 4. key HOME.
sent=1
run key HOME
[ "$(printf '%s' "$out" | field code)" = 3 ] || fail "key HOME did not report code 3"
wait_until 30 'front "$launcher"' "the launcher was not in front within 30 s after key HOME"

# 5. Settings and its search entry. A non-unique id would make step 11's --id tap ELEMENT_AMBIGUOUS.
adb -s "$serial" shell am start -W -a android.settings.SETTINGS >/dev/null 2>&1 \
  || fail "adb -s $serial shell am start -W -a android.settings.SETTINGS failed"
wait_until 30 'front "$settings"' "Settings was not in front within 30 s after am start"
entry=$(printf '%s' "$tree" | search_entry) || fail "no search entry on the Settings home page"
read -r sx sy by target <<EOF
$entry
EOF
if [ "$by" = id ]; then
  [ "$(printf '%s' "$tree" | id_count "$target")" = 1 ] || fail "the Settings search entry id is not unique"
fi

# 6. Point tap on the entry: the search opens with its field focused.
run tap "$sx" "$sy"
[ "$(printf '%s' "$out" | node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(0, "utf8"))).join())')" = device,x,y ] \
  || fail "tap output keys are not device, x, y"
wait_until 30 has_field "no focused editable field within 30 s after the tap on the search entry"

# 7. The keyboard reports a touchable region: what ELEMENT_COVERED reads.
wait_until 10 "ime_is 'true [1-9]*'" "the keyboard reports no touchable region; ELEMENT_COVERED cannot work on this phone"
rects=${state#* }

# 8. text, read back from the field, then deleted. Text typed while a field appears loses characters (K25).
lock_guard
sleep 2
typed="kq'z 7%s"
run text "$typed"
[ "$(printf '%s' "$out" | field text)" = "$typed" ] || fail "text did not echo the typed text"
wait_until 30 'field_is "$typed"' "the field did not read back the typed text within 30 s"
keys 8 DEL
wait_until 30 'field_lacks kq' "the field still holds the typed text after 8 x key DEL"

# 9. BACK hides the keyboard. With the keyboard shown, the IME takes the first BACK (research run order).
run key BACK
wait_until 10 "ime_is 'false *'" "the keyboard did not hide after key BACK"

# 10. Long press on typed text: selection popups appear and BACK closes them; no toolbar item is tapped, so the
# clipboard is not touched.
run text "kq kq"
wait_until 30 'field_is "kq kq"' "the field did not read back kq kq within 30 s"
box=$(printf '%s' "$tree" | focused box) || fail "no focused field for the long press"
read -r l t r b <<EOF
$box
EOF
popup_count || fail "adb -s $serial shell dumpsys window windows failed"
before=$count
run tap "$((l + (r - l) * 15 / 100))" "$(((t + b) / 2))" --duration 1000
[ "$(printf '%s' "$out" | field duration)" = 1000 ] || fail "tap --duration did not echo duration 1000"
wait_until 10 'popups_above "$before"' "the long press opened no popup window within 10 s"
# The long press shows the keyboard again. Which one takes the first BACK differs: the keyboard on Android 16, the
# popups on Android 12, where the keyboard then stays up.
run key BACK
if ! poll 5 'popups_at_most "$before"'; then
  run key BACK
  wait_until 10 'popups_at_most "$before"' "the popup windows stayed after two key BACK"
fi
if ime_is 'true *'; then
  run key BACK
  wait_until 10 "ime_is 'false *'" "the keyboard did not hide after key BACK"
fi
keys 5 DEL
run key BACK
wait_until 30 'front "$settings"' "Settings was not in front within 30 s after leaving the search"

# 11. Element taps: the entry by --id (--text when it has no id), an ambiguous id, a missing label.
if [ "$by" = id ]; then
  run tap --id "$target"
  rid=$(printf '%s' "$out" | field element.resourceId) || fail "tap --id output has no element.resourceId"
  case $rid in "$target" | *":id/$target") ;; *) fail "tap --id tapped another element than the search entry" ;; esac
else
  run tap --text "$target"
  [ "$(printf '%s' "$out" | field element.contentDesc)" = "$target" ] \
    || fail "tap --text tapped another element than the search entry"
fi
[ "$(printf '%s' "$out" | field x)" = "$sx" ] && [ "$(printf '%s' "$out" | field y)" = "$sy" ] \
  || fail "tap --$by did not tap the search entry's center"
wait_until 30 has_field "no focused editable field within 30 s after tap --$by"
wait_until 10 "ime_is 'true *'" "the keyboard did not show after tap --$by"
run key BACK
wait_until 10 "ime_is 'false *'" "the keyboard did not hide after key BACK"
run key BACK
wait_until 30 'front "$settings"' "Settings was not in front within 30 s after leaving the search"

amb=$(printf '%s' "$tree" | id_count title)
if [ "$amb" -ge 2 ]; then
  sum=$(printf '%s' "$tree" | screen_sum)
  refuses ELEMENT_AMBIGUOUS tap --id title
  read_tree || fail "ui-tree exited non-zero: $(printf '%s' "$tree" | code_of)"
  [ "$(printf '%s' "$tree" | screen_sum)" = "$sum" ] || fail "the Settings screen changed after a refused tap --id title"
  ambiguous="ambiguous $amb"
else
  echo "note: ambiguous step skipped"
  ambiguous="ambiguous skipped"
fi

# A phone read takes up to 6 s, so the emulator smoke's --timeout 3000 would give one read.
start=$(date +%s)
refuses ELEMENT_NOT_FOUND tap --text karagoz-no-such-label --timeout 10000
elapsed=$(($(date +%s) - start))
reads=$(printf '%s' "$out" | node -e '
  const m = /\((\d+) reads? in /.exec(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message);
  if (!m) process.exit(1);
  console.log(m[1]);
') || fail "the ELEMENT_NOT_FOUND message names no read count"
[ "$elapsed" -ge 10 ] && [ "$reads" -ge 2 ] || fail "--timeout 10000 ended after $elapsed s and $reads reads"

# 12. swipe on the Settings home, then back with Android's default duration.
read_tree || fail "ui-tree exited non-zero: $(printf '%s' "$tree" | code_of)"
sum=$(printf '%s' "$tree" | screen_sum)
x=$((width / 2))
low=$((height * 75 / 100))
high=$((height * 35 / 100))
run swipe "$x" "$low" "$x" "$high" --duration 1000
wait_until 30 'screen_not "$sum"' "the Settings screen did not move within 30 s after the swipe"
run swipe "$x" "$high" "$x" "$low"
[ "$(printf '%s' "$out" | field duration)" = 300 ] || fail "swipe without --duration did not echo duration 300"

# 13. HOME from Settings: step 4 can start on the launcher already, so this is the step where HOME shows its effect.
wait_until 30 'front "$settings"' "Settings was not in front within 30 s after the swipes"
run key HOME
wait_until 30 'front "$launcher"' "the launcher was not in front within 30 s after key HOME"

# Nothing left behind. pidof exits 1 when nothing matches, so its output decides, not its exit status.
left=$(adb -s "$serial" shell pidof uiautomator 2>/dev/null) || true
[ -z "$left" ] || fail "a uiautomator process is left on the phone"
a11y=$(adb -s "$serial" shell dumpsys accessibility 2>/dev/null) || fail "adb -s $serial shell dumpsys accessibility failed"
case $a11y in *'Ui Automation['*) fail "the UiAutomation slot is still held after the run" ;; esac
setting system accelerometer_rotation
[ "$value" = "$accel" ] || fail "accelerometer_rotation changed during the run"
setting system user_rotation
[ "$value" = "$user" ] || fail "user_rotation changed during the run"

echo "ok: physical keys 3, tap, text 8 chars, keyboard $rects rect, long press, 2 element taps, $ambiguous, not found $reads reads, swipe moved"
