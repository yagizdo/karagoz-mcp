#!/bin/sh
# Step 1.3: `ui-tree` prints the focused window's accessibility tree as one JSON line, by serial and by AVD name;
# another UiAutomation client gives AUTOMATION_BUSY; an unknown target and an option the command does not declare
# fail with the JSON envelope. A fake adb covers parsing, failure classification and the WebView re-read.
# Precondition: an emulator is running with its screen on, and no other UiAutomation client is connected.
# The only device-side process started here is `uiautomator events` (step 6), which the script stops. Nothing here
# boots, stops, rotates or wakes anything, and the adb server on the default port is never touched.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

tmp=$(mktemp -d)
id=
events=
# set +e: errexit stays on inside the trap, and a failing kill or wait would skip the rest.
trap 'set +e; if [ -n "$events" ]; then kill "$events" 2>/dev/null; wait "$events" 2>/dev/null; adb -s "$id" shell pkill uiautomator >/dev/null 2>&1; fi; rm -rf "$tmp"' EXIT
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

# 2. A ready, named emulator to aim at.
list=$(node dist/cli.js devices) || { echo "FAIL: devices exited non-zero: $list"; exit 1; }
emu=$(printf '%s' "$list" | node -e '
  const found = JSON.parse(require("fs").readFileSync(0, "utf8")).devices.find((d) => d.kind === "emulator" && d.state === "device" && d.name);
  if (!found) process.exit(1);
  console.log(found.id, found.name);
') || { echo "FAIL: no ready, named emulator in: $list (is one running? emulator -avd <name>)"; exit 1; }
id=${emu% *}
name=${emu#* }

# 3. Only one UiAutomation client can be connected, and another one would make every read below fail.
a11y=$(adb -s "$id" shell dumpsys accessibility) \
  || { echo "FAIL: adb -s $id shell dumpsys accessibility failed (is adb on PATH?)"; exit 1; }
case $a11y in *'Ui Automation['*)
  echo "FAIL: another UiAutomation client is connected (dumpsys accessibility shows Ui Automation[); stop Appium, Maestro or uiautomator events and rerun"
  exit 1 ;;
esac

# 4. By serial: the K24 contract on every node of the live screen. Prints the summary for the ok line.
out=$(node dist/cli.js ui-tree --device "$id") || { echo "FAIL: ui-tree by serial exited non-zero: $out"; exit 1; }
summary=$(printf '%s' "$out" | node -e '
  const out = require("fs").readFileSync(0, "utf8");
  const fail = (reason) => { console.log(reason); process.exit(1); };
  if (out.includes("\n")) fail("stdout is not one line");
  let result;
  try { result = JSON.parse(out); } catch { fail("stdout is not JSON"); }
  if (Object.keys(result).join() !== "device,rotation,root") fail("the top-level keys are not device, rotation, root");
  if (result.device !== process.argv[1]) fail(`device is not ${process.argv[1]}`);
  if (![0, 90, 180, 270].includes(result.rotation)) fail("rotation is not 0, 90, 180 or 270");
  if (typeof result.root.package !== "string" || !result.root.package) fail("root has no package");
  const KEYS = ["class", "package", "text", "contentDesc", "resourceId", "hint", "checkable", "checked", "clickable",
    "longClickable", "focusable", "focused", "scrollable", "selected", "password", "enabled", "bounds", "children"];
  const FLAGS = ["checkable", "checked", "clickable", "longClickable", "focusable", "focused", "scrollable", "selected", "password"];
  const STRINGS = ["package", "text", "contentDesc", "resourceId", "hint"];
  let nodes = 0;
  let labelled = false;
  const walk = (node) => {
    nodes++;
    if (typeof node.class !== "string" || !node.class) fail("a node has no class");
    const bounds = node.bounds;
    if (!Array.isArray(bounds) || bounds.length !== 4 || !bounds.every(Number.isInteger)) fail(`bounds of ${node.class} are not four integers`);
    for (const key of Object.keys(node)) if (!KEYS.includes(key)) fail(`${node.class} has ${key}, which is not a contract field`);
    for (const flag of FLAGS) if (flag in node && node[flag] !== true) fail(`${flag} of ${node.class} is present but not true`);
    if ("enabled" in node && node.enabled !== false) fail(`enabled of ${node.class} is present but not false`);
    for (const key of STRINGS) if (key in node && (typeof node[key] !== "string" || !node[key])) fail(`${key} of ${node.class} is not a non-empty string`);
    if (node.text || node.contentDesc) labelled = true;
    if ("children" in node) {
      if (!Array.isArray(node.children) || !node.children.length) fail(`children of ${node.class} is not a non-empty array`);
      node.children.forEach(walk);
    }
  };
  walk(result.root);
  if (!labelled) fail("no node has text or contentDesc");
  console.log(`rotation ${result.rotation}, ${nodes} nodes, ${Buffer.byteLength(out)} B, root ${result.root.package}`);
' "$id") || { echo "FAIL: $summary: $out"; exit 1; }

# 5. By AVD name.
res=$(node dist/cli.js ui-tree --device "$name") || { echo "FAIL: ui-tree by AVD name exited non-zero: $res"; exit 1; }
[ "$(printf '%s' "$res" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).device)')" = "$id" ] \
  || { echo "FAIL: AVD name $name did not resolve to $id: $res"; exit 1; }

# 6. Busy: `uiautomator events` holds the one UiAutomation slot.
adb -s "$id" shell uiautomator events >/dev/null 2>&1 &
events=$!
tries=0
until adb -s "$id" shell dumpsys accessibility | grep -q 'Ui Automation\['; do
  tries=$((tries + 1))
  [ "$tries" -lt 50 ] || { echo "FAIL: uiautomator events did not register within 10 s"; exit 1; }
  sleep 0.2
done
if busy=$(node dist/cli.js ui-tree --device "$id" 2>/dev/null); then
  echo "FAIL: ui-tree with another UiAutomation client exited 0"; exit 1
fi
[ "$(printf '%s' "$busy" | code_of)" = AUTOMATION_BUSY ] || { echo "FAIL: expected AUTOMATION_BUSY, got: $busy"; exit 1; }
# Killing the local client ends the device process too (measured); pkill covers the case where it does not.
kill "$events" 2>/dev/null || true
wait "$events" 2>/dev/null || true
adb -s "$id" shell pkill uiautomator >/dev/null 2>&1 || true
events=
tries=0
while adb -s "$id" shell dumpsys accessibility | grep -q 'Ui Automation\['; do
  tries=$((tries + 1))
  [ "$tries" -lt 50 ] || { echo "FAIL: the UiAutomation slot was still held 10 s after uiautomator events stopped"; exit 1; }
  sleep 0.2
done

# 7. An unknown target.
if miss=$(node dist/cli.js ui-tree --device nope 2>/dev/null); then echo "FAIL: unknown device exited 0"; exit 1; fi
[ "$(printf '%s' "$miss" | code_of)" = DEVICE_NOT_FOUND ] || { echo "FAIL: expected DEVICE_NOT_FOUND, got: $miss"; exit 1; }

# 8. ui-tree declares only --device.
if bad=$(node dist/cli.js ui-tree --out x 2>/dev/null); then echo "FAIL: ui-tree --out exited 0"; exit 1; fi
[ "$(printf '%s' "$bad" | code_of)" = INVALID_ARGS ] || { echo "FAIL: expected INVALID_ARGS, got: $bad"; exit 1; }

# 9. Parsing, failure classification and the WebView re-read against a fake adb: none of these can be produced on
# demand on a live screen. ANDROID_HOME makes $tmp/sdk/platform-tools/adb karagoz's first adb candidate.
fake=$tmp/fake
fx=$tmp/fx
mkdir -p "$tmp/sdk/platform-tools" "$fake" "$fx"
cat > "$tmp/sdk/platform-tools/adb" <<'EOF'
#!/bin/sh
# Fake adb for smoke 1.3: answers from the files in $FAKE. dump1 is the first uiautomator read, dump2 the second.
case "$*" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n\n' ;;
  *'exec-out uiautomator dump /dev/tty')
    n=$(($(cat "$FAKE/reads") + 1))
    echo "$n" > "$FAKE/reads"
    cat "$FAKE/dump$n" ;;
  *'shell dumpsys accessibility') cat "$FAKE/a11y" ;;
  *) echo "fake adb: unexpected arguments: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/sdk/platform-tools/adb"
busy_a11y='Ui Automation[eventTypes=TYPES_ALL_MASK, notificationTimeout=0]'
idle_a11y='ACCESSIBILITY MANAGER (dumpsys accessibility)'

# Runs ui-tree against the fake adb. $1: the dumpsys accessibility text; $2: the first read; $3: the second, if any.
run_fake() {
  printf '%s\n' "$1" > "$fake/a11y"
  echo 0 > "$fake/reads"
  cp "$2" "$fake/dump1"
  rm -f "$fake/dump2"
  [ -z "$3" ] || cp "$3" "$fake/dump2"
  ANDROID_HOME="$tmp/sdk" FAKE="$fake" node dist/cli.js ui-tree --device emulator-5554 2>/dev/null
}
# Fails unless $got is exactly the line in file $2 and the dump was read $3 times. $1: the fixture.
# printf, not echo: this machine's sh echo expands the \n and \" inside the JSON (K9).
tree_is() {
  [ "$got" = "$(cat "$2")" ] || { printf 'FAIL: fixture %s: expected %s, got: %s\n' "$1" "$(cat "$2")" "$got"; exit 1; }
  [ "$(cat "$fake/reads")" = "$3" ] || { echo "FAIL: fixture $1: $(cat "$fake/reads") reads, expected $3"; exit 1; }
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

# a. Vendor noise before the XML, the status line after it, both quote styles, every entity form, dropped attributes.
cat > "$fx/a.xml" <<'EOF'
java.io.FileNotFoundException: /dev/tty at java.io.FileInputStream.<init>(FileInputStream.java:160)
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="1"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,0][2400,1080]" drawing-order="0" hint=""><node index="0" text='a &amp; b &lt; c " d &apos; e&#10;f &#128512;' resource-id="com.example:id/label" class="android.widget.TextView" package="com.example" content-desc="" checkable="false" checked="false" clickable="false" enabled="false" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,2391][1080,2337]" drawing-order="1" hint="" /><node NAF="true" index="1" text="" resource-id="" class="android.widget.Button" package="com.other" content-desc="Save &gt; &quot;x&quot; &#x41;" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="true" password="false" selected="false" bounds="[10,20][30,40]" drawing-order="2" hint="Hint"/></node></hierarchy>UI hierchary dumped to: /dev/tty
EOF
cat > "$fx/a.json" <<'EOF'
{"device":"emulator-5554","rotation":90,"root":{"class":"android.widget.FrameLayout","package":"com.example","bounds":[0,0,2400,1080],"children":[{"class":"android.widget.TextView","text":"a & b < c \" d ' e\nf 😀","resourceId":"com.example:id/label","enabled":false,"bounds":[0,2391,1080,2337]},{"class":"android.widget.Button","package":"com.other","contentDesc":"Save > \"x\" A","hint":"Hint","clickable":true,"longClickable":true,"focusable":true,"bounds":[10,20,30,40]}]}}
EOF
got=$(run_fake "$idle_a11y" "$fx/a.xml") || { echo "FAIL: fixture a exited non-zero: $got"; exit 1; }
tree_is a "$fx/a.json" 1

# b, c. uiautomator's own failure text wins over a busy slot; dumpsys is not consulted for it.
printf 'ERROR: could not get idle state.\n' > "$fx/b.txt"
if got=$(run_fake "$busy_a11y" "$fx/b.txt"); then echo "FAIL: fixture b exited 0"; exit 1; fi
error_is b CAPTURE_FAILED "the screen did not go idle within uiautomator's 10 s wait (an animation or live content kept changing it); uiautomator: ERROR: could not get idle state."
printf 'ERROR: null root node returned by UiTestAutomationBridge.\n' > "$fx/c.txt"
if got=$(run_fake "$busy_a11y" "$fx/c.txt"); then echo "FAIL: fixture c exited 0"; exit 1; fi
error_is c CAPTURE_FAILED "no focused window to read (is the screen off, is an app still starting, or is the app in a work profile or Secure Folder, which adb cannot read?); uiautomator: ERROR: null root node returned by UiTestAutomationBridge."

# d, e. Killed: the slot decides between AUTOMATION_BUSY and CAPTURE_FAILED.
printf 'Killed \n' > "$fx/killed.txt"
if got=$(run_fake "$busy_a11y" "$fx/killed.txt"); then echo "FAIL: fixture d exited 0"; exit 1; fi
error_is d AUTOMATION_BUSY "another UiAutomation client holds the device (Appium, Maestro, uiautomator events, or a second karagoz call); only one can be connected at a time"
if got=$(run_fake "$idle_a11y" "$fx/killed.txt"); then echo "FAIL: fixture e exited 0"; exit 1; fi
error_is e CAPTURE_FAILED "uiautomator was killed while reading this screen; the cause is in adb -s emulator-5554 logcat -b crash"

# f, g. Both markers present, but the fragment is not KXmlSerializer's grammar.
printf '<hierarchy rotation="0"><node class="a &foo; b" package="p" bounds="[0,0][1,1]" /></hierarchy>' > "$fx/f.xml"
if got=$(run_fake "$idle_a11y" "$fx/f.xml"); then echo "FAIL: fixture f exited 0"; exit 1; fi
error_is f CAPTURE_FAILED 'cannot parse uiautomator output: ' prefix
printf '<hierarchy rotation="0"><node class="a" package="p" bounds="[0,0][1,1]"></hierarchy>' > "$fx/g.xml"
if got=$(run_fake "$idle_a11y" "$fx/g.xml"); then echo "FAIL: fixture g exited 0"; exit 1; fi
error_is g CAPTURE_FAILED 'cannot parse uiautomator output: ' prefix

# h. A stream cut before </hierarchy> has no tree: its own text is the message.
printf '%s\n' "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\"><node class=\"a\"" > "$fx/h.xml"
if got=$(run_fake "$idle_a11y" "$fx/h.xml"); then echo "FAIL: fixture h exited 0"; exit 1; fi
error_is h CAPTURE_FAILED "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\"><node class=\"a\""

# i, j. A WebView with no children is read once more: the second tree wins, and a failed second read keeps the first.
cat > "$fx/web-empty.xml" <<'EOF'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node class="android.widget.FrameLayout" package="dev.karagoz.probe" bounds="[0,0][1080,2400]"><node class="android.webkit.WebView" package="dev.karagoz.probe" bounds="[0,63][1080,2337]" /></node></hierarchy>UI hierchary dumped to: /dev/tty
EOF
cat > "$fx/web-full.xml" <<'EOF'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node class="android.widget.FrameLayout" package="dev.karagoz.probe" bounds="[0,0][1080,2400]"><node class="android.webkit.WebView" package="dev.karagoz.probe" bounds="[0,63][1080,2337]"><node class="android.view.View" package="dev.karagoz.probe" text="Web heading" bounds="[42,105][1038,180]" /></node></node></hierarchy>UI hierchary dumped to: /dev/tty
EOF
cat > "$fx/web-full.json" <<'EOF'
{"device":"emulator-5554","rotation":0,"root":{"class":"android.widget.FrameLayout","package":"dev.karagoz.probe","bounds":[0,0,1080,2400],"children":[{"class":"android.webkit.WebView","bounds":[0,63,1080,2337],"children":[{"class":"android.view.View","text":"Web heading","bounds":[42,105,1038,180]}]}]}}
EOF
cat > "$fx/web-empty.json" <<'EOF'
{"device":"emulator-5554","rotation":0,"root":{"class":"android.widget.FrameLayout","package":"dev.karagoz.probe","bounds":[0,0,1080,2400],"children":[{"class":"android.webkit.WebView","bounds":[0,63,1080,2337]}]}}
EOF
got=$(run_fake "$idle_a11y" "$fx/web-empty.xml" "$fx/web-full.xml") || { echo "FAIL: fixture i exited non-zero: $got"; exit 1; }
tree_is i "$fx/web-full.json" 2
got=$(run_fake "$idle_a11y" "$fx/web-empty.xml" "$fx/killed.txt") || { echo "FAIL: fixture j exited non-zero: $got"; exit 1; }
tree_is j "$fx/web-empty.json" 2

# 10. Nothing of ours is left running on the device.
if left=$(adb -s "$id" shell pidof uiautomator); then echo "FAIL: a uiautomator process is left on the device: $left"; exit 1; fi

echo "ok: $id, $summary"
