#!/bin/sh
# Step 2.3: `ui-tree` on a physical phone, by serial and by model name, holds the K24 contract and agrees with the
# phone's own screenshot: the same rotation, every node inside its pixels.
# Precondition: the build only; a phone is optional, and no emulator is needed. If a phone is used: screen on and
# unlocked, a personal-profile app in front, no other UiAutomation client connected.
# What reaches a phone: `adb devices` and the getprop that `devices` and name matching make; `settings get`,
# `dumpsys accessibility` and `pidof uiautomator`; screenshot's screencap, `wm density` and `dumpsys window displays`;
# ui-tree's `uiautomator dump`. While a dump runs it unbinds accessibility services and can take one off its
# accessibility shortcut for good, so the phone step skips when any service is enabled (K24 2.3 note). The adb server
# on the default port is never stopped or restarted.
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
# Prints .error.code of a one-line envelope, not-one-line or not-json. Never the message: a failed dump's message can
# carry screen content.
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

# 2. A physical phone, if one is listed.
list=$(node dist/cli.js devices 2>/dev/null) || fail "devices exited non-zero: $(printf '%s' "$list" | code_of)"
phone=$(printf '%s' "$list" | node -e '
  const { devices } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const found = devices.find((d) => d.kind === "physical" && d.state === "device");
  if (found) console.log(JSON.stringify({ ...found, named: found.name ? devices.filter((d) => d.name === found.name).length : 0 }));
')
if [ -z "$phone" ]; then
  echo "SKIP: no physical device"
  echo "ok: physical skipped"
  exit 0
fi
serial=$(printf '%s' "$phone" | field id)
name=$(printf '%s' "$phone" | field name)
named=$(printf '%s' "$phone" | field named)

# 3. Guard. A dump unbinds enabled services and can take one off its accessibility shortcut for good.
setting secure enabled_accessibility_services
case $value in
  '' | null) ;;
  *) echo "SKIP: accessibility services are enabled on the phone"; echo "ok: physical skipped"; exit 0 ;;
esac
a11y=$(adb -s "$serial" shell dumpsys accessibility 2>/dev/null) || fail "adb -s $serial shell dumpsys accessibility failed"
case $a11y in *'Ui Automation['*)
  fail "another UiAutomation client is connected (dumpsys accessibility shows Ui Automation[); stop Appium, Maestro or uiautomator events and rerun" ;;
esac
setting system accelerometer_rotation
accel=$value
setting system user_rotation
user=$value

# 4. Screenshot: the screen size and rotation the tree is checked against.
shot=$(node dist/cli.js screenshot --device "$serial" --out "$tmp/phone.png" 2>/dev/null) \
  || fail "screenshot by serial exited non-zero: $(printf '%s' "$shot" | code_of)"
width=$(printf '%s' "$shot" | field pixels.width) || fail "screenshot output has no pixels.width"
height=$(printf '%s' "$shot" | field pixels.height) || fail "screenshot output has no pixels.height"
rotation=$(printf '%s' "$shot" | field rotation) || fail "screenshot output has no rotation"

# 5. By serial: the K24 contract on every node, bounds inside the screenshot. Prints the node count. Reasons name the
# field only, never a value or a class. class may be empty: the dumper writes "" for a null class name (K24).
tree=$(node dist/cli.js ui-tree --device "$serial" 2>/dev/null) \
  || fail "ui-tree by serial exited non-zero: $(printf '%s' "$tree" | code_of)"
nodes=$(printf '%s' "$tree" | node -e '
  const out = require("fs").readFileSync(0, "utf8");
  const [serial, rotation, width, height] = process.argv.slice(1);
  const fail = (reason) => { console.log(reason); process.exit(1); };
  if (out.includes("\n")) fail("stdout is not one line");
  let result;
  try { result = JSON.parse(out); } catch { fail("stdout is not JSON"); }
  if (Object.keys(result).join() !== "device,rotation,root") fail("the top-level keys are not device, rotation, root");
  if (result.device !== serial) fail("device is not the serial");
  if (result.rotation !== Number(rotation)) fail("rotation differs from the screenshot rotation");
  if (typeof result.root?.package !== "string" || !result.root.package) fail("root has no package");
  const KEYS = ["class", "package", "text", "contentDesc", "resourceId", "hint", "checkable", "checked", "clickable",
    "longClickable", "focusable", "focused", "scrollable", "selected", "password", "enabled", "bounds", "children"];
  const FLAGS = ["checkable", "checked", "clickable", "longClickable", "focusable", "focused", "scrollable", "selected", "password"];
  const STRINGS = ["package", "text", "contentDesc", "resourceId", "hint"];
  let nodes = 0;
  const walk = (node) => {
    nodes++;
    if (typeof node.class !== "string") fail("class is not a string");
    for (const key of Object.keys(node)) if (!KEYS.includes(key)) fail(`a node has ${JSON.stringify(key)}, which is not a contract field`);
    for (const flag of FLAGS) if (flag in node && node[flag] !== true) fail(`${flag} is present but not true`);
    if ("enabled" in node && node.enabled !== false) fail("enabled is present but not false");
    for (const key of STRINGS) if (key in node && (typeof node[key] !== "string" || !node[key])) fail(`${key} is not a non-empty string`);
    const b = node.bounds;
    if (!Array.isArray(b) || b.length !== 4 || !b.every(Number.isInteger)) fail("bounds are not four integers");
    const [l, t, r, bottom] = b;
    if ([l, r].some((x) => x < 0 || x > Number(width)) || [t, bottom].some((y) => y < 0 || y > Number(height))) {
      fail(`bounds are outside [0,0,${width},${height}]`);
    }
    if ("children" in node) {
      if (!Array.isArray(node.children) || !node.children.length) fail("children is not a non-empty array");
      node.children.forEach(walk);
    }
  };
  walk(result.root);
  console.log(nodes);
' "$serial" "$rotation" "$width" "$height") || fail "ui-tree by serial: $nodes"

# 6. By model name, when no other listed entry has it.
byname=
if [ "$named" = 1 ]; then
  res=$(node dist/cli.js ui-tree --device "$name" 2>/dev/null) \
    || fail "ui-tree by model name exited non-zero: $(printf '%s' "$res" | code_of)"
  [ "$(printf '%s' "$res" | field device)" = "$serial" ] || fail "the model name did not resolve to the phone"
  byname=", by name"
else
  echo "note: by-name step skipped, $named entries named $name"
fi

# 7. Nothing left behind. pidof exits 1 when nothing matches, so its output decides, not its exit status.
left=$(adb -s "$serial" shell pidof uiautomator 2>/dev/null) || true
[ -z "$left" ] || fail "a uiautomator process is left on the phone"
a11y=$(adb -s "$serial" shell dumpsys accessibility 2>/dev/null) || fail "adb -s $serial shell dumpsys accessibility failed"
case $a11y in *'Ui Automation['*) fail "the UiAutomation slot is still held after ui-tree" ;; esac
setting system accelerometer_rotation
[ "$value" = "$accel" ] || fail "accelerometer_rotation changed during the run"
setting system user_rotation
[ "$value" = "$user" ] || fail "user_rotation changed during the run"

echo "ok: physical rotation $rotation, $nodes nodes$byname"
