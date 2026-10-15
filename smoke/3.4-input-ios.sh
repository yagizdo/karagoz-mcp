#!/bin/sh
# Step 3.4: on macOS tap, swipe, key and the element tap (tap --text, --id) reach a booted iOS simulator through the
# helper's DTUHID modes and text through its XCUIAutomation mode, in K25's and K26's shapes, with the tree's pixels
# turned into the unrotated portrait panel for every rotation (K35). Fakes prove the helper's argv, each helper exit's
# K5 code, the timeout, DEVICE_NOT_READY and the iOS-less key before any compile, text's character check, that it
# puts app accessibility back and that two texts on one server run in turn, and element matching on a fake tree; the
# real part drives a test app and reads every effect back with ui-tree.
# Precondition: macOS with Xcode. A booted simulator on its home screen is used when one is running and no phone is
# attached, else the real part prints SKIP. It builds smoke/fixtures/input-ios, installs, drives and uninstalls it,
# presses HOME and checks that the home screen is on the page it recorded and the app is gone. Fake swiftc, simctl and devicectl come through
# DEVELOPER_DIR, fake adb through ANDROID_HOME, all under env -i with a temporary HOME; the adb server on the default
# port is never touched.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iOS simulators need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
framework=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl
booted=
installed=
home=
fail() { echo "FAIL: $*"; exit 1; }
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }
real() { env -i HOME="$tmp/home-real" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
tree() { real ui-tree --device "$booted"; }
# One fact from a ui-tree line on stdin: whether a node with an identifier is listed, its label or bounds center, the
# top edge of the node labelled <id> (or "gone"), the root's label or size, or the home screen's page.
q() { node -e '
  const [mode, id] = process.argv.slice(1);
  const root = JSON.parse(require("fs").readFileSync(0, "utf8")).root;
  const all = [];
  const walk = (n) => { all.push(n); (n.children ?? []).forEach(walk); };
  walk(root);
  const node = all.find((n) => n.identifier === id);
  const b = node?.bounds ?? [];
  console.log({
    has: () => (node ? "yes" : "no"),
    label: () => node?.label ?? "",
    center: () => `${(b[0] + b[2]) / 2} ${(b[1] + b[3]) / 2}`,
    top: () => String(all.find((n) => n.label === id)?.bounds[1] ?? "gone"),
    root: () => root.label ?? "",
    size: () => `${root.bounds[2]} ${root.bounds[3]}`,
    home: () => all.find((n) => n.identifier === "spotlight-pill")?.value ?? "",
  }[mode]());
' "$@"; }
# Polls ui-tree for up to 5 s until `q <mode> <id>` prints <want>.
wait_for() { # <label> <want> <mode> [<id>]
  i=0
  until got=$(tree | q "$3" "$4") && [ "$got" = "$2" ]; do
    i=$((i + 1))
    [ "$i" -lt 10 ] || fail "$1: $3 $4 is '$got', expected '$2'"
    sleep 0.5
  done
}
home_back() {
  i=0
  until [ "$(tree | q home)" = "$home" ]; do
    i=$((i + 1))
    [ "$i" -lt 20 ] || { echo "FAIL: the home screen is $(tree | q home), recorded $home"; return 1; }
    sleep 0.5
  done
}
# Puts the simulator back: the app goes, HOME is pressed, the home screen must be on the recorded page. Widgets list
# more or fewer nodes as their processes load accessibility, so only the page is compared.
restore() {
  [ -n "$installed" ] || return 0
  "$framework" terminate "$booted" dev.karagoz.probe >/dev/null 2>&1
  "$framework" uninstall "$booted" dev.karagoz.probe >/dev/null 2>&1
  ! "$framework" get_app_container "$booted" dev.karagoz.probe >/dev/null 2>&1 || { echo "FAIL: the test app is still installed"; return 1; }
  out=$(real key HOME --device "$booted")
  if [ "$(printf '%s' "$out" | code_of)" = NOT_SUPPORTED ]; then
    echo "note: home screen not checked (no key HOME before Xcode 27)"
    return 0
  fi
  home_back
}
trap 'set +e; pkill -f "sleep 97\.48"; restore; st=$?; rm -rf "$tmp"; [ "$st" = 0 ] || exit 1' EXIT

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them. Files under $fake steer them. The
# fake swiftc logs each compile and writes a binary that runs $fake/helper.
fake="$tmp/fake"
toolchain="$tmp/dev/Toolchains/XcodeDefault.xctoolchain/usr/bin"
mkdir -p "$tmp/sdk/platform-tools" "$tmp/dev/usr/bin" "$toolchain" "$tmp/nocc/usr/bin" "$tmp/home" "$fake"
cat > "$tmp/sdk/platform-tools/adb" <<FAKE
#!/bin/sh
case "\$*" in
  devices) printf 'List of devices attached\n\n' ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/dev/usr/bin/simctl" <<FAKE
#!/bin/sh
case "\$*" in
  "list devices --json") /bin/cat "$fake/list.json" ;;
  "getenv A1 SIMULATOR_MAINSCREEN_WIDTH") echo 1206 ;;
  "getenv A1 SIMULATOR_MAINSCREEN_HEIGHT") echo 2622 ;;
  "spawn A1 defaults read com.apple.Accessibility ApplicationAccessibilityEnabled") echo read >> "$fake/seq"; /bin/cat "$fake/appax" ;;
  "spawn A1 defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true") echo write >> "$fake/appax.log"; echo write >> "$fake/seq" ;;
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
cat > "$toolchain/swiftc" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/swiftc.log"
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
printf '#!/bin/sh\nexec /bin/sh "%s/helper" "\$@"\n' "$fake" > "\$out"
/bin/chmod +x "\$out"
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$tmp/dev/usr/bin/simctl" "$tmp/dev/usr/bin/devicectl" "$toolchain/swiftc"
cp "$tmp/dev/usr/bin/simctl" "$tmp/nocc/usr/bin/simctl"
echo "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[{\"udid\":\"A1\",\"name\":\"iPhone 17\",\"state\":\"Booted\",\"isAvailable\":true},{\"udid\":\"A2\",\"name\":\"iPhone 17 Pro\",\"state\":\"Booting\",\"isAvailable\":true}]}}" > "$fake/list.json"
helper() { printf '%s\n' "$1" > "$fake/helper"; }
# A helper that prints $fake/tree.json in tree mode (no input arguments) and counts the reads; in an input mode it
# records its arguments after the developer dir and UDID, then runs $1.
logs() { helper "if [ \$# -eq 2 ]; then echo read >> '$fake/reads'; /bin/cat '$fake/tree.json'; exit 0; fi; shift 2; echo \"\$*\" > '$fake/argv'; $1"; }
rot() { echo "echo '{\"result\":{\"displays\":[{\"primary\":true,\"currentOrientation\":\"$1\"}]}}'" > "$fake/devicectl"; }
compiles() { [ -e "$fake/swiftc.log" ] && /usr/bin/wc -l < "$fake/swiftc.log" | tr -d ' ' || echo 0; }
# karagoz with only the fakes; <home> picks the cache directory. Sets $out and $st, and clears the recorded argv.
run_in() {
  home_dir=$1
  shift
  rm -f "$fake/argv" "$fake/reads" "$fake/appax.log"
  out=$(env -i HOME="$home_dir" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev" \
    "$node_bin" dist/cli.js "$@" 2>/dev/null) && st=0 || st=$?
}
call() { run_in "$tmp/home" "$@"; }
succeeds() { # <label> <expected stdout>
  [ "$st" = 0 ] && [ "$out" = "$2" ] || fail "$1: exit $st, got $out, expected $2"
}
refuses() { # <code> <label>
  [ "$st" -ne 0 ] || fail "$2 exited 0: $out"
  [ "$(printf '%s' "$out" | code_of)" = "$1" ] || fail "$2: expected $1, got: $out"
}
says() { # <label> <text>
  case "$(printf '%s' "$out" | message_of)" in *"$2"*) ;; *) fail "$1: message lacks '$2': $out" ;; esac
}
argv_is() { # <label> <helper arguments after the UDID>
  [ "$(cat "$fake/argv" 2>/dev/null)" = "$2" ] || fail "$1: helper got '$(cat "$fake/argv" 2>/dev/null)', expected '$2'"
}

# 1. Pixels to ratios of the 1206x2622 panel, rounded to 6 decimals; K25's output with the UDID.
rot rot0; logs 'exit 0'
call tap 603 1171 --device A1
succeeds tap '{"device":"A1","x":603,"y":1171}'
argv_is tap "tap 0.5 0.446606 0"
[ "$(compiles)" = 1 ] || fail "the first call compiled $(compiles) times"
call tap 603 1171 --duration 700 --device A1
succeeds "tap --duration" '{"device":"A1","x":603,"y":1171,"duration":700}'
argv_is "tap --duration" "tap 0.5 0.446606 700"

# 2. Each interface rotation maps to the unrotated panel; an unreadable rotation counts as portrait.
rot rot270; call tap 1311 901 --device A1; argv_is "rotation 90" "tap 0.252902 0.5 0"
rot rot90; call tap 100 200 --device A1; argv_is "rotation 270" "tap 0.165837 0.961861 0"
rot rot180; call tap 100 200 --device A1; argv_is "rotation 180" "tap 0.917081 0.923722 0"
echo 'exit 1' > "$fake/devicectl"; call tap 100 200 --device A1; argv_is "no rotation" "tap 0.082919 0.076278 0"
rot rot0

# 3. swipe states its default duration, as on Android.
call swipe 603 2228.7 603 917.7 --device A1
succeeds swipe '{"device":"A1","x1":603,"y1":2228.7,"x2":603,"y2":917.7,"duration":300}'
argv_is swipe "swipe 0.5 0.85 0.5 0.35 300"

# 4. Keys: hardware buttons on the consumer page, keyboard keys by usage; "7" is code 7, KEYCODE_0.
call key HOME --device A1
succeeds "key HOME" '{"device":"A1","key":"KEYCODE_HOME","code":3}'
argv_is "key HOME" "button 12 64"
call key POWER --device A1; argv_is "key POWER" "button 12 48"
call key DEL --device A1; argv_is "key DEL" "key 42"
call key 7 --device A1
succeeds "key 7" '{"device":"A1","key":"KEYCODE_0","code":7}'
argv_is "key 7" "key 39"

# 5. A key with no iOS meaning is refused before anything compiles or runs.
run_in "$tmp/home2" key BACK --device A1
refuses INVALID_ARGS "key BACK"
case "$(printf '%s' "$out" | message_of)" in "'BACK' has no iOS simulator key"*"swipe from the left edge") ;; *) fail "key BACK text: $out" ;; esac
[ ! -e "$fake/argv" ] && [ ! -e "$tmp/home2/Library" ] || fail "key BACK reached the helper"

# 6. Helper exits: 4 no dtuhidd, 5 dtuhidd silent, 2 this Xcode's interface, 7 the input failed, a signal, a hang.
logs 'exit 4'
call tap 1 1 --device A1
refuses NOT_SUPPORTED "exit 4"
[ "$(printf '%s' "$out" | message_of)" = "'tap' on iOS simulators needs Xcode 27 or later" ] || fail "exit 4 text: $out"
call key HOME --device A1
says "exit 4 on key" "'key' on iOS simulators needs Xcode 27"
logs "echo 'ax: dtuhidd did not answer: no reply within 4 s' >&2; exit 5"
call swipe 1 1 2 2 --device A1
refuses DEVICE_NOT_READY "exit 5"
says "exit 5" "may still be starting after boot"
logs "echo 'ax: no xpc_endpoint_create_mach_port_4sim' >&2; exit 2"
call tap 1 1 --device A1
refuses HELPER_FAILED "exit 2"
says "exit 2" "no xpc_endpoint_create_mach_port_4sim"
says "exit 2" "update karagoz"
logs "echo 'ax: cannot connect to dtuhidd' >&2; exit 7"
call tap 1 1 --device A1
refuses HELPER_FAILED "exit 7"
says "exit 7" "cannot connect to dtuhidd"
helper 'kill -SEGV $$'
call tap 1 1 --device A1
refuses HELPER_FAILED "crashed helper"
says "crashed helper" "SIGSEGV"
helper "exec /bin/sleep 97.48"
start=$(date +%s)
call tap 1 1 --device A1
took=$(($(date +%s) - start))
refuses HELPER_FAILED "hung helper"
says "hung helper" "did not answer within 30 s"
[ "$took" -ge 29 ] && [ "$took" -le 36 ] || fail "hung helper took ${took}s"
sleep 1
! pgrep -f 'sleep 97\.48' >/dev/null || fail "the hung helper outlived karagoz"

# 7. A booting simulator is not ready, and nothing is compiled for it.
run_in "$tmp/home3" tap 1 1 --device A2
refuses DEVICE_NOT_READY "booting simulator"
[ ! -e "$tmp/home3/Library" ] || fail "a booting simulator compiled the helper"

# 8. No compiler: a developer dir with simctl but no swiftc.
out=$(env -i HOME="$tmp/home4" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/nocc" \
  "$node_bin" dist/cli.js tap 1 1 --device A1 2>/dev/null) && st=0 || st=$?
refuses HELPER_FAILED "no swiftc"
says "no swiftc" "swiftc not found"

# 9. text: any Unicode, newline and tab; other control characters refused before anything runs. testmanagerd turns app
# accessibility off when the session ends, so a 1 read before is written back, also after a failure.
echo 1 > "$fake/appax"; logs 'exit 0'
call text "çğş it's -- ok" --device A1
succeeds text '{"device":"A1","text":"çğş it'"'"'s -- ok"}'
argv_is text "type 120 çğş it's -- ok"
[ "$(cat "$fake/appax.log" 2>/dev/null)" = write ] || fail "text did not put app accessibility back"
call text "$(printf 'a\nb\tc')" --device A1
[ "$st" = 0 ] && [ "$(cat "$fake/argv")" = "$(printf 'type 120 a\nb\tc')" ] || fail "newline and tab: exit $st, helper got $(cat "$fake/argv")"
call text "$(printf 'a\001b\033')" --device A1
refuses TEXT_UNSUPPORTED "control characters"
[ "$(printf '%s' "$out" | message_of)" = "cannot type 'U+0001', 'U+001B' on an iOS simulator: control characters other than newline and tab; nothing was typed" ] \
  || fail "TEXT_UNSUPPORTED text: $out"
[ ! -e "$fake/argv" ] && [ ! -e "$fake/appax.log" ] || fail "control characters reached the simulator"
echo 0 > "$fake/appax"
call text ok --device A1
[ "$st" = 0 ] && [ ! -e "$fake/appax.log" ] || fail "text wrote app accessibility that was off: exit $st"
echo 1 > "$fake/appax"
logs "echo 'ax: Ensure no other tests are running' >&2; exit 6"
call text ok --device A1
refuses AUTOMATION_BUSY "exit 6"
says "exit 6" "Ensure no other tests are running"
[ "$(cat "$fake/appax.log" 2>/dev/null)" = write ] || fail "a refused session did not put app accessibility back"
logs "echo 'ax: synthesis failed' >&2; exit 7"
call text ok --device A1
refuses HELPER_FAILED "text exit 7"
says "text exit 7" "synthesis failed"
# Two texts sent together to one MCP server run one after the other: a second one reading the setting while the first
# session's end has turned it off would skip its own write-back and leave it off.
rm -f "$fake/seq"
helper "echo start >> '$fake/seq'; /bin/sleep 0.3; echo end >> '$fake/seq'"
errors=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev" \
  "$node_bin" -e '
const server = require("node:child_process").spawn(process.execPath, ["dist/cli.js", "mcp"]);
const send = (m) => server.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
const calls = new Set([2, 3]);
require("node:readline").createInterface({ input: server.stdout }).on("line", (line) => {
  const { id, result } = JSON.parse(line);
  if (id === 1) {
    send({ method: "notifications/initialized" });
    for (const n of calls) send({ id: n, method: "tools/call", params: { name: "text", arguments: { text: "ok", device: "A1" } } });
    return;
  }
  if (result?.isError) console.log(result.content[0].text);
  calls.delete(id);
  if (!calls.size) server.kill();
});
send({ id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "smoke", version: "0" } } });
setTimeout(() => { console.log("no answer within 10 s"); process.exit(1); }, 10_000).unref();
' 2>/dev/null) || fail "two texts at once: $errors"
[ -z "$errors" ] || fail "two texts at once: $errors"
[ "$(cat "$fake/seq")" = "$(printf 'read\nstart\nend\nwrite\nread\nstart\nend\nwrite')" ] \
  || fail "two texts at once overlapped: $(tr '\n' ' ' < "$fake/seq")"

# 10. Element tap: the matching node's bounds center, tapped through the same transform; --text is label or value with
# direction marks ignored, --id is the identifier; zero-area nodes never match (K26 on iOS).
cat > "$fake/tree.json" <<'TREE'
{"screen":{"width":1206,"height":2622,"scale":3},"root":{"role":"AXApplication","label":"Probe","frame":[0,0,402,874],"children":[
{"role":"AXTextField","value":"Name","identifier":"name-field","frame":[16,100,370,44]},
{"role":"AXButton","label":"Press","identifier":"press-button","frame":[16,300,370,44],"children":[{"role":"AXStaticText","label":"inner","frame":[20,310,10,10]}]},
{"role":"AXStaticText","label":"\u200eBuds\u200e","frame":[16,400,100,20]},
{"role":"AXStaticText","label":"Row","frame":[16,500,370,44]},
{"role":"AXStaticText","label":"Row","frame":[16,550,370,44]},
{"role":"AXButton","label":"Hidden","frame":[16,600,0,44]}]}}
TREE
logs 'exit 0'
call tap --text Press --device A1
succeeds "tap --text" '{"device":"A1","x":603,"y":966,"element":{"role":"Button","label":"Press","identifier":"press-button","bounds":[48,900,1158,1032]}}'
argv_is "tap --text" "tap 0.5 0.368421 0"
call tap --text Name --device A1; argv_is "tap --text on a value" "tap 0.5 0.139588 0"
call tap --id press-button --duration 700 --device A1
succeeds "tap --id --duration" '{"device":"A1","x":603,"y":966,"duration":700,"element":{"role":"Button","label":"Press","identifier":"press-button","bounds":[48,900,1158,1032]}}'
argv_is "tap --id --duration" "tap 0.5 0.368421 700"
call tap --text Buds --device A1; argv_is "direction marks" "tap 0.164179 0.469108 0"
call tap --text Row --device A1
refuses ELEMENT_AMBIGUOUS "two Rows"
[ "$(printf '%s' "$out" | message_of)" = "2 nodes match label or value 'Row': StaticText [48,1500,1158,1632], StaticText [48,1650,1158,1782]; tap one by its coordinates" ] \
  || fail "ELEMENT_AMBIGUOUS text: $out"
[ ! -e "$fake/argv" ] || fail "an ambiguous match tapped"
call tap --text Hidden --device A1
refuses ELEMENT_NOT_FOUND "zero-area node"
case "$(printf '%s' "$out" | message_of)" in "no node with label or value 'Hidden' in the frontmost app (1 read in "*) ;; *) fail "ELEMENT_NOT_FOUND text: $out" ;; esac
call tap --id nope --timeout 1500 --device A1
refuses ELEMENT_NOT_FOUND "--timeout"
says "--timeout" "no node with identifier 'nope'"
[ "$(/usr/bin/wc -l < "$fake/reads")" -ge 2 ] || fail "--timeout 1500 read the tree fewer than 2 times: $out"
[ ! -e "$fake/argv" ] || fail "a missing element tapped"
helper "if [ \$# -eq 2 ]; then echo 'ax: no frontmost application' >&2; exit 3; fi; shift 2; echo \"\$*\" > '$fake/argv'"
call tap --text Press --device A1
refuses CAPTURE_FAILED "unreadable tree"
[ ! -e "$fake/argv" ] || fail "an unreadable tree tapped"

fakes="fakes: ratios, rotations, swipe, keys, iOS-less key, exits, hung (${took}s), booting, no compiler, text, element tap"

# 11. Real simulator: the test app, each effect read back with ui-tree, then the home screen as recorded.
phone=$({ command -v adb >/dev/null && adb devices | awk 'NR > 1 && $1 != "" && $1 !~ /^emulator-/'; ioreg -p IOUSB -w0 | grep -iE 'iPhone|iPad'; } || true)
booted=$("$framework" list devices --json | node -e '
  const { devices } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const d = Object.entries(devices).filter(([k]) => k.startsWith("com.apple.CoreSimulator.SimRuntime.iOS-")).flatMap(([, l]) => l)
    .find((d) => d.isAvailable === true && d.state === "Booted");
  console.log(d ? d.udid : "");
')
if [ -n "$phone" ]; then
  echo "SKIP: a phone is attached, the real part does not run"
  booted=
  echo "ok: real skipped, $fakes"
  exit 0
fi
if [ -z "$booted" ]; then
  echo "SKIP: no booted simulator"
  echo "ok: real skipped, $fakes"
  exit 0
fi
home=$(tree | q home)
case $home in "Page "*) ;; *) fail "put $booted on its home screen first (no spotlight-pill)" ;; esac
sh smoke/fixtures/input-ios/build.sh "$tmp"
installed=1
"$framework" install "$booted" "$tmp/Probe.app"
"$framework" launch "$booted" dev.karagoz.probe >/dev/null
wait_for launch Probe root

set -- $(tree | q center tap-button)
out=$(real tap "$1" "$2" --device "$booted") && st=0 || st=$?
if [ "$(printf '%s' "$out" | code_of)" = NOT_SUPPORTED ]; then
  echo "note: no dtuhidd (Xcode < 27), touch and key not checked"
  out=$(real text "çğş it's -- ok" --device "$booted") && st=0 || st=$?
  echo "note: text on Xcode < 27 exited $st, echo not checked (no focus without dtuhidd)"
  real_ok="real: no dtuhidd"
else
  succeeds "real tap" "{\"device\":\"$booted\",\"x\":$1,\"y\":$2}"
  wait_for "real tap" "Tap me 1" label tap-button
  set -- $(tree | q center long-target)
  out=$(real tap "$1" "$2" --duration 700 --device "$booted") && st=0 || st=$?
  succeeds "real long press" "{\"device\":\"$booted\",\"x\":$1,\"y\":$2,\"duration\":700}"
  wait_for "real long press" "Long 1" label long-target
  before=$(tree | q top "Row 1")
  [ "$before" != gone ] || fail "real swipe: Row 1 is not on screen before the swipe"
  set -- $(tree | q size)
  x=$(($1 / 2)) low=$(($2 * 85 / 100)) high=$(($2 * 35 / 100))
  out=$(real swipe "$x" "$low" "$x" "$high" --duration 1000 --device "$booted") && st=0 || st=$?
  succeeds "real swipe" "{\"device\":\"$booted\",\"x1\":$x,\"y1\":$low,\"x2\":$x,\"y2\":$high,\"duration\":1000}"
  # The list moved up by at least half the drag, or Row 1 left the screen.
  i=0
  until after=$(tree | q top "Row 1") && { [ "$after" = gone ] || [ "$(echo "$before - $after >= ($low - $high) / 2" | bc)" = 1 ]; }; do
    i=$((i + 1))
    [ "$i" -lt 10 ] || fail "real swipe: Row 1's top went from $before to $after"
    sleep 0.5
  done
  real swipe "$x" "$high" "$x" "$low" --device "$booted" >/dev/null || fail "real swipe back"
  real swipe "$x" "$high" "$x" "$low" --device "$booted" >/dev/null || fail "real swipe back"
  wait_for "real swipe back" yes has name-field
  out=$(real tap --id tap-button --device "$booted") || fail "real tap --id: $out"
  wait_for "real tap --id" "Tap me 2" label tap-button
  out=$(real tap --text Press --device "$booted") || fail "real tap --text: $out"
  wait_for "real tap --text" "pressed 1" label press-count
  set -- $(tree | q center name-field)
  real tap "$1" "$2" --device "$booted" >/dev/null || fail "real tap on the field"
  out=$(real text "çğş it's -- ok" --device "$booted") && st=0 || st=$?
  succeeds "real text" "{\"device\":\"$booted\",\"text\":\"çğş it's -- ok\"}"
  wait_for "real text" "echo:çğş it's -- ok" label echo
  real key DEL --device "$booted" >/dev/null || fail "real key DEL"
  wait_for "real key DEL" "echo:çğş it's -- o" label echo
  out=$(real key HOME --device "$booted") && st=0 || st=$?
  succeeds "real key HOME" "{\"device\":\"$booted\",\"key\":\"KEYCODE_HOME\",\"code\":3}"
  wait_for "real key HOME" " " root
  real_ok="real $booted: tap, long press, swipe, tap --id, tap --text, text, DEL, HOME"
fi

echo "ok: $real_ok, $fakes"
