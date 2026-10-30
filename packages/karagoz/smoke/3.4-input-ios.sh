#!/bin/sh
# Step 3.4: on macOS tap, long-press, double-tap, swipe, key and the element tap (tap --text, --id) reach a booted iOS
# simulator through the helper's DTUHID modes and text through its XCUIAutomation mode, in K25's and K26's shapes, with the tree's pixels
# turned into the unrotated portrait panel for every rotation (K35). Fakes prove the helper's argv, each helper exit's
# K5 code, the timeout, DEVICE_NOT_READY and the iOS-less key before any compile, text's character check, that it
# puts app accessibility back and that two texts on one server run in turn, and element matching on a fake tree; the
# real part drives a test app and reads every effect back with ui-tree. Below CoreSimulator 1155.4 the four go to
# karagoz's runner inside the simulator instead (K49): fakes prove its unsigned build, start, points, keys, ports, the
# accessibility write-back and uninstall-runner; on such a Mac the real part runs through it and removes it after.
# Precondition: macOS with Xcode. A booted simulator on its home screen is used when one is running and no phone is
# attached, else the real part prints SKIP. It builds smoke/fixtures/input-ios, installs, drives and uninstalls it,
# presses HOME and checks that the home screen is on the page it recorded (below CoreSimulator 1155.4 only that it is
# in front) and the app is gone. Fake swiftc, simctl and devicectl come through
# DEVELOPER_DIR, fake adb through ANDROID_HOME, all under env -i with a temporary HOME; the adb server on the default
# port is never touched.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iOS simulators need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
framework=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl
# Below CoreSimulator 1155.4 the real part goes through karagoz's runner, which restore() removes again (K49).
runner_mac=no
if node -e 'const [a, b] = [process.argv[1], "1155.4"].map((v) => v.split(".").map(Number));
  const i = [0, 1, 2].find((k) => (a[k] ?? 0) !== (b[k] ?? 0)); process.exit(i !== undefined && (a[i] ?? 0) < (b[i] ?? 0) ? 0 : 1)' \
  "$(/usr/bin/plutil -extract CFBundleVersion raw "${framework%/bin/simctl}/Info.plist" 2>/dev/null)"; then
  runner_mac=yes
fi
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
tree() { real ui-tree --device "$booted" --detail full; }
# One fact from a ui-tree line on stdin: whether a node with an identifier is listed, its label, bounds center or left
# edge and middle, the
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
    left: () => `${b[0]} ${(b[1] + b[3]) / 2}`,
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
# With "any", only that the home screen is in front: karagoz's runner presses HOME by bringing it there, which leaves
# its page as it is (K49).
home_back() {
  i=0
  until got=$(tree | q home) && { [ "$got" = "$home" ] || { [ "$1" = any ] && [ "${got#Page }" != "$got" ]; }; }; do
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
  if [ "$runner_mac" = yes ]; then home_back any; else home_back; fi
  back=$?
  if [ "$runner_mac" = yes ]; then
    out=$(real uninstall-runner --device "$booted")
    [ "$out" = "{\"device\":\"$booted\",\"apps\":[\"com.karagozmcp.runner.xctrunner\"],\"profiles\":[]}" ] \
      || { echo "FAIL: uninstall-runner on $booted: $out"; return 1; }
  fi
  return $back
}
trap 'set +e; pkill -f "sleep 97\.48"; pkill -f "runner\.cjs $fake"; restore; st=$?; rm -rf "$tmp"; [ "$st" = 0 ] || exit 1' EXIT

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
# A CoreSimulator with dtuhidd for these fakes, whatever this Mac has; section 11 gives an older one.
printf '<plist><dict><key>CFBundleVersion</key><string>1174.9.2</string></dict></plist>\n' | tee "$tmp/dev/usr/Info.plist" > "$tmp/nocc/usr/Info.plist"
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
call long-press 603 1171 --duration 700 --device A1
succeeds "long-press" '{"device":"A1","x":603,"y":1171,"duration":700}'
argv_is "long-press" "tap 0.5 0.446606 700"
call double-tap 603 1171 --device A1
succeeds "double-tap" '{"device":"A1","x":603,"y":1171}'
argv_is "double-tap" "doubletap 0.5 0.446606 50 100"

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
# argv cannot carry an unpaired surrogate (Node reads it as U+FFFD), so it comes as MCP JSON.
out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev" \
  "$node_bin" -e '
const server = require("node:child_process").spawn(process.execPath, ["dist/cli.js", "mcp"]);
const send = (m) => server.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
require("node:readline").createInterface({ input: server.stdout }).on("line", (line) => {
  const { id, result } = JSON.parse(line);
  if (id === 1) {
    send({ method: "notifications/initialized" });
    send({ id: 2, method: "tools/call", params: { name: "text", arguments: { text: "a\ud800", device: "A1" } } });
    return;
  }
  console.log(result.content[0].text);
  server.kill();
});
send({ id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "smoke", version: "0" } } });
setTimeout(() => { console.log("no answer within 10 s"); process.exit(1); }, 10_000).unref();
' 2>/dev/null) || fail "unpaired surrogate: $out"
[ "$(printf '%s' "$out" | code_of)" = TEXT_UNSUPPORTED ] || fail "unpaired surrogate: expected TEXT_UNSUPPORTED, got: $out"
[ "$(printf '%s' "$out" | message_of)" = "cannot type 'U+D800' on an iOS simulator: an unpaired surrogate; nothing was typed" ] \
  || fail "unpaired surrogate text: $out"
[ ! -e "$fake/argv" ] && [ ! -e "$fake/appax.log" ] || fail "an unpaired surrogate reached the simulator"
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
# Xcode 27 or later gives a simulator on an older iOS runtime no automation session, and Xcode 26 gives none at all: text
# refuses at once, before the setting is read or the helper compiles. With no version.plist, as above, it goes on.
rm -f "$fake/seq"
cp "$fake/list.json" "$tmp/list.saved"
sed 's/iOS-27-0/iOS-26-2/' "$tmp/list.saved" > "$fake/list.json"
printf '<plist><dict><key>CFBundleShortVersionString</key><string>27.1</string><key>ProductBuildVersion</key><string>27B1</string></dict></plist>\n' > "$tmp/version.plist"
run_in "$tmp/home5" text ok --device A1
refuses NOT_SUPPORTED "text on iOS 26.2 with Xcode 27.1"
says "text on iOS 26.2 with Xcode 27.1" "'text' on an iOS 26.2 simulator needs an iOS 27 or later simulator"
[ ! -e "$fake/argv" ] && [ ! -e "$fake/seq" ] && [ ! -e "$tmp/home5/Library" ] \
  || fail "text on iOS 26.2 with Xcode 27.1 read the setting or reached the helper"
printf '<plist><dict><key>CFBundleShortVersionString</key><string>26.2</string><key>ProductBuildVersion</key><string>17C52</string></dict></plist>\n' > "$tmp/version.plist"
run_in "$tmp/home5" text ok --device A1
refuses NOT_SUPPORTED "text with Xcode 26.2"
says "text with Xcode 26.2" "'text' on iOS simulators needs Xcode 27 or later"
[ ! -e "$fake/argv" ] && [ ! -e "$fake/seq" ] && [ ! -e "$tmp/home5/Library" ] \
  || fail "text with Xcode 26.2 read the setting or reached the helper"
mv "$tmp/list.saved" "$fake/list.json"
rm "$tmp/version.plist"

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
call long-press --id press-button --duration 700 --device A1
succeeds "long-press --id" '{"device":"A1","x":603,"y":966,"duration":700,"element":{"role":"Button","label":"Press","identifier":"press-button","bounds":[48,900,1158,1032]}}'
argv_is "long-press --id" "tap 0.5 0.368421 700"
call double-tap --id press-button --device A1
succeeds "double-tap --id" '{"device":"A1","x":603,"y":966,"element":{"role":"Button","label":"Press","identifier":"press-button","bounds":[48,900,1158,1032]}}'
argv_is "double-tap --id" "doubletap 0.5 0.368421 50 100"
call tap --text Buds --device A1; argv_is "direction marks" "tap 0.164179 0.469108 0"
call tap --text Row --device A1
refuses ELEMENT_AMBIGUOUS "two Rows"
[ "$(printf '%s' "$out" | message_of)" = "2 nodes match label or value 'Row': StaticText [48,1500,1158,1632], StaticText [48,1650,1158,1782]; tap one by its coordinates" ] \
  || fail "ELEMENT_AMBIGUOUS text: $out"
[ ! -e "$fake/argv" ] || fail "an ambiguous match tapped"
cp "$fake/tree.json" "$tmp/tree.saved"
cat > "$fake/tree.json" <<'TREE'
{"screen":{"width":1206,"height":2622,"scale":3},"root":{"role":"AXApplication","label":"Probe","frame":[0,0,402,874],"children":[
{"role":"AXStaticText","label":"Row","frame":[16,600,370,30]},
{"role":"AXStaticText","label":"Row","frame":[16,640,370,30]},
{"role":"AXStaticText","label":"Row","frame":[16,680,370,30]},
{"role":"AXStaticText","label":"Row","frame":[16,720,370,30]},
{"role":"AXStaticText","label":"Row","frame":[16,760,370,30]},
{"role":"AXStaticText","label":"Row","frame":[16,800,370,30]}]}}
TREE
call tap --text Row --device A1
refuses ELEMENT_AMBIGUOUS "six Rows"
[ "$(printf '%s' "$out" | message_of)" = "6 nodes match label or value 'Row': StaticText [48,1800,1158,1890], StaticText [48,1920,1158,2010], StaticText [48,2040,1158,2130], StaticText [48,2160,1158,2250], StaticText [48,2280,1158,2370], and 1 more; tap one by its coordinates" ] \
  || fail "ELEMENT_AMBIGUOUS text with more than five: $out"
mv "$tmp/tree.saved" "$fake/tree.json"
call tap --text Hidden --device A1
refuses ELEMENT_NOT_FOUND "zero-area node"
case "$(printf '%s' "$out" | message_of)" in "no node with label or value 'Hidden' in the frontmost app (1 read in "[0-9]*.[0-9]" s)") ;; *) fail "ELEMENT_NOT_FOUND text: $out" ;; esac
call tap --id nope --timeout 1500 --device A1
refuses ELEMENT_NOT_FOUND "--timeout"
says "--timeout" "no node with identifier 'nope'"
case "$(printf '%s' "$out" | message_of)" in "no node with identifier 'nope' in the frontmost app ("[0-9]*" reads in "[0-9]*.[0-9]" s)") ;; *) fail "ELEMENT_NOT_FOUND after several reads: $out" ;; esac
[ "$(/usr/bin/wc -l < "$fake/reads")" -ge 2 ] || fail "--timeout 1500 read the tree fewer than 2 times: $out"
[ ! -e "$fake/argv" ] || fail "a missing element tapped"
helper "if [ \$# -eq 2 ]; then echo 'ax: no frontmost application' >&2; exit 3; fi; shift 2; echo \"\$*\" > '$fake/argv'"
call tap --text Press --device A1
refuses CAPTURE_FAILED "unreadable tree"
[ ! -e "$fake/argv" ] || fail "an unreadable tree tapped"

# 11. Runner path: below CoreSimulator 1155.4 tap, swipe, text and key go to karagoz's runner inside the simulator,
# built without signing and started by the first call, on a loopback port of its own per simulator; its xcodebuild runs
# under sh, which turns app accessibility back on when it exits. uninstall-runner takes such a simulator (K49). The fake
# xcodebuild builds as in 4.4 and becomes the fake runner.
rdev="$tmp/rdev"
runner_fixtures=$(pwd)/smoke/fixtures/runner
mkdir -p "$rdev/usr/bin" "$tmp/rhome"
printf '<plist><dict><key>CFBundleVersion</key><string>1051.17.7</string></dict></plist>\n' > "$rdev/usr/Info.plist"
cp "$tmp/dev/usr/bin/devicectl" "$rdev/usr/bin/devicectl"
cat > "$rdev/usr/bin/simctl" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/rsimctl"
case "\$*" in
  "list devices --json") /bin/cat "$fake/list.json" ;;
  "getenv "*" SIMULATOR_MAINSCREEN_WIDTH") echo 1206 ;;
  "getenv "*" SIMULATOR_MAINSCREEN_HEIGHT") echo 2622 ;;
  "getenv "*" SIMULATOR_MAINSCREEN_SCALE") echo 3.000000 ;;
  "spawn "*" defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true") ;;
  "listapps A1") /bin/cat "$fake/listapps" ;;
  "uninstall A1 com.karagozmcp.runner.xctrunner") ;;
  *) exit 1 ;;
esac
FAKE
cat > "$rdev/usr/bin/xcodebuild" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/xcodebuild"
case "\$*" in
  *build-for-testing*)
    [ ! -e "$fake/build-fails" ] || { echo "error: the fake build failed"; exit 65; }
    while [ \$# -gt 0 ]; do [ "\$1" = -derivedDataPath ] && dd=\$2; shift; done
    /bin/mkdir -p "\$dd/Build/Products/Debug-iphonesimulator/KaragozRunner-Runner.app"
    /bin/cp "$runner_fixtures/KaragozRunner.xctestrun" "\$dd/Build/Products/KaragozRunner_iphonesimulator26.2-arm64.xctestrun"
    ;;
  *test-without-building*)
    while [ \$# -gt 0 ]; do [ "\$1" = -xctestrun ] && xr=\$2; shift; done
    exec "$node_bin" "$runner_fixtures/runner.cjs" "$fake" "\$xr"
    ;;
esac
FAKE
chmod +x "$rdev/usr/bin/simctl" "$rdev/usr/bin/devicectl" "$rdev/usr/bin/xcodebuild"
cp "$fake/list.json" "$tmp/list.saved"
echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-2":[{"udid":"A1","name":"iPhone 17","state":"Booted","isAvailable":true},{"udid":"A3","name":"iPhone 17 Pro","state":"Booted","isAvailable":true}]}}' > "$fake/list.json"
rot rot0
: > "$fake/inputs"
rcall() { # <home> <karagoz arguments>: karagoz with the runner fakes; sets $out and $st
  home_dir=$1
  shift
  out=$(env -i HOME="$home_dir" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$rdev" \
    "$node_bin" dist/cli.js "$@" 2>/dev/null) && st=0 || st=$?
}
sent() { /usr/bin/tail -1 "$fake/inputs"; }
count() { /usr/bin/grep -c -- "$1" "$fake/$2" 2>/dev/null || true; }
port_of() { cat "$tmp/rhome/Library/Caches/karagoz/runner/$1.port"; }
rcall "$tmp/rhome" tap 603 1311 --device A1
succeeds "runner tap" '{"device":"A1","x":603,"y":1311}'
[ "$(sent)" = '/tap {"x":201,"y":437,"orientation":1}' ] || fail "runner tap sent: $(sent)"
[ "$(count build-for-testing xcodebuild)" = 1 ] && [ "$(count test-without-building xcodebuild)" = 1 ] \
  || fail "runner tap: expected one build and one start: $(cat "$fake/xcodebuild")"
build_line=$(/usr/bin/grep build-for-testing "$fake/xcodebuild")
case $build_line in *"-destination id=A1"*) ;; *) fail "runner build: no simulator destination: $build_line" ;; esac
case $build_line in *DEVELOPMENT_TEAM* | *-allowProvisioning*) fail "runner build: signing settings: $build_line" ;; esac
rcall "$tmp/rhome" long-press 603 1311 --duration 700 --device A1
[ "$(sent)" = '/tap {"x":201,"y":437,"duration":700,"orientation":1}' ] || fail "runner long press sent: $(sent)"
rcall "$tmp/rhome" double-tap 603 1311 --device A1
succeeds "runner double-tap" '{"device":"A1","x":603,"y":1311}'
[ "$(sent)" = '/double-tap {"x":201,"y":437,"hold":50,"gap":100,"orientation":1}' ] || fail "runner double tap sent: $(sent)"
[ "$(count build-for-testing xcodebuild)" = 1 ] && [ "$(count test-without-building xcodebuild)" = 1 ] \
  || fail "second runner call built or started again: $(cat "$fake/xcodebuild")"
rcall "$tmp/rhome" swipe 603 2000 603 600 --duration 500 --device A1
succeeds "runner swipe" '{"device":"A1","x1":603,"y1":2000,"x2":603,"y2":600,"duration":500}'
[ "$(sent)" = '/swipe {"x1":201,"y1":666.667,"x2":201,"y2":200,"duration":500,"orientation":1}' ] \
  || fail "runner swipe sent: $(sent)"
printf '<plist><dict><key>CFBundleShortVersionString</key><string>26.2</string><key>ProductBuildVersion</key><string>17C52</string></dict></plist>\n' > "$tmp/version.plist"
rcall "$tmp/rhome" text "çğş 😀" --device A1
succeeds "runner text on Xcode 26.2" '{"device":"A1","text":"çğş 😀"}'
[ "$(sent)" = '/text {"text":"çğş 😀","speed":120}' ] || fail "runner text sent: $(sent)"
rm "$tmp/version.plist"
rcall "$tmp/rhome" key HOME --device A1
succeeds "runner key HOME" '{"device":"A1","key":"KEYCODE_HOME","code":3}'
[ "$(sent)" = '/button {"button":"home"}' ] || fail "runner key HOME sent: $(sent)"
rcall "$tmp/rhome" key A --device A1
[ "$(sent)" = '/text {"text":"a","speed":120}' ] || fail "runner key A sent: $(sent)"
before=$(/usr/bin/wc -l < "$fake/inputs")
for name in POWER VOLUME_UP DPAD_UP; do
  rcall "$tmp/rhome" key "$name" --device A1
  refuses INVALID_ARGS "runner key $name"
  says "runner key $name" "'$name' has no key on this simulator"
done
[ "$(/usr/bin/wc -l < "$fake/inputs")" = "$before" ] || fail "a key the runner lacks was sent: $(sent)"
# A second simulator gets a runner and a port of its own; the first one's still answers.
rcall "$tmp/rhome" tap 603 1311 --device A3
succeeds "runner tap on A3" '{"device":"A3","x":603,"y":1311}'
[ "$(port_of A1)" != "$(port_of A3)" ] || fail "A1 and A3 share port $(port_of A1)"
rcall "$tmp/rhome" key HOME --device A1
[ "$st" = 0 ] && [ "$(count test-without-building xcodebuild)" = 2 ] || fail "A1 after A3: exit $st, $(cat "$fake/xcodebuild")"
# A runner that ended leaves its port behind: the sh around xcodebuild writes app accessibility back, and the next call
# starts a runner on a new port.
old_port=$(port_of A1)
pkill -f "runner\.cjs $fake .*session-A1\.xctestrun"
i=0
until /usr/bin/grep -q '^spawn A1 defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true$' "$fake/rsimctl"; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || fail "no accessibility write-back after the runner ended: $(cat "$fake/rsimctl")"
  sleep 0.25
done
rcall "$tmp/rhome" tap 603 1311 --device A1
succeeds "runner tap after the runner ended" '{"device":"A1","x":603,"y":1311}'
[ "$(count test-without-building xcodebuild)" = 3 ] && [ "$(port_of A1)" != "$old_port" ] \
  || fail "no new start on a new port: port $(port_of A1), $(cat "$fake/xcodebuild")"
touch "$fake/build-fails"
rcall "$tmp/rhome2" tap 603 1311 --device A1
refuses HELPER_FAILED "runner build fails"
says "runner build fails" "the runner build failed: error: the fake build failed (log: "
rm "$fake/build-fails"
printf '    "com.karagozmcp.runner.xctrunner" =     {\n        CFBundleIdentifier = "com.karagozmcp.runner.xctrunner";\n    };\n' > "$fake/listapps"
rcall "$tmp/rhome" uninstall-runner --device A1
succeeds "runner uninstall" '{"device":"A1","apps":["com.karagozmcp.runner.xctrunner"],"profiles":[]}'
/usr/bin/grep -q '^uninstall A1 com.karagozmcp.runner.xctrunner$' "$fake/rsimctl" || fail "runner uninstall ran no simctl uninstall"
: > "$fake/listapps"
rcall "$tmp/rhome" uninstall-runner --device A1
succeeds "runner uninstall, nothing there" '{"device":"A1","apps":[],"profiles":[]}'
rcall "$tmp/rhome" install-runner --device A1
refuses NOT_SUPPORTED "install-runner on a simulator"
call uninstall-runner --device A1
refuses NOT_SUPPORTED "uninstall-runner on a simulator with dtuhidd"
pkill -f "runner\.cjs $fake" || true
mv "$tmp/list.saved" "$fake/list.json"

fakes="fakes: ratios, rotations, swipe, keys, iOS-less key, exits, hung (${took}s), booting, no compiler, text, element tap, runner path"

# 12. Real simulator: the test app, each effect read back with ui-tree, then the home screen as recorded.
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
  refuses NOT_SUPPORTED "real text on Xcode < 27"
  says "real text on Xcode < 27" "'text' on iOS simulators needs Xcode 27 or later"
  real_ok="real: no dtuhidd, text NOT_SUPPORTED"
else
  succeeds "real tap" "{\"device\":\"$booted\",\"x\":$1,\"y\":$2}"
  wait_for "real tap" "Tap me 1" label tap-button
  set -- $(tree | q center long-target)
  out=$(real long-press "$1" "$2" --duration 700 --device "$booted") && st=0 || st=$?
  succeeds "real long press" "{\"device\":\"$booted\",\"x\":$1,\"y\":$2,\"duration\":700}"
  wait_for "real long press" "Long 1" label long-target
  set -- $(tree | q center double-target)
  out=$(real double-tap "$1" "$2" --device "$booted") && st=0 || st=$?
  succeeds "real double tap" "{\"device\":\"$booted\",\"x\":$1,\"y\":$2}"
  wait_for "real double tap" "Double 1" label double-target
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
  # "hello" starts the field's text; its middle sits about 68 px right of the field's left edge. ENTER ends the name
  # field's editing, so the keyboard no longer hides the word field.
  real key ENTER --device "$booted" >/dev/null || fail "real key ENTER"
  wait_for "the word field after ENTER" yes has word-field
  set -- $(tree | q left word-field)
  real tap "$(($1 + 900))" "$2" --device "$booted" >/dev/null || fail "real tap on the word field"
  sleep 1
  wait_for "the word field above the keyboard" yes has word-field
  set -- $(tree | q left word-field)
  out=$(real double-tap "$(($1 + 68))" "$2" --device "$booted") || fail "real double-tap on a word: $out"
  wait_for "real double tap on a word" "selected:hello" label selection
  out=$(real key HOME --device "$booted") && st=0 || st=$?
  succeeds "real key HOME" "{\"device\":\"$booted\",\"key\":\"KEYCODE_HOME\",\"code\":3}"
  wait_for "real key HOME" " " root
  real_ok="real $booted: tap, long press, double tap, swipe, tap --id, tap --text, text, DEL, word selection, HOME"
  [ "$runner_mac" = no ] || real_ok="$real_ok, through the runner, removed after"
fi

echo "ok: $real_ok, $fakes"
