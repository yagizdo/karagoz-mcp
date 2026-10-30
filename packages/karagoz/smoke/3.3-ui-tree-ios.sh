#!/bin/sh
# Step 3.3: on macOS `ui-tree` reads a booted iOS simulator's frontmost app through a helper karagoz compiles into
# ~/Library/Caches/karagoz/<key>/ax, in K24's skeleton with iOS names, bounds in screenshot pixels and rotation from
# devicectl (K34), compact by default and every element with --detail full (K54). Fakes prove the field mapping, the
# compact rule, the mini scale, the cache key, every HELPER_FAILED and CAPTURE_FAILED path, the 30 s timeout,
# DEVICE_NOT_READY before any compile, and a null rotation without devicectl.
# Precondition: macOS with Xcode. A booted simulator is used when one is running, else that step prints SKIP; nothing
# here boots, installs or changes anything in it, and no emulator is needed. Fake swiftc, simctl and devicectl come
# through DEVELOPER_DIR, fake adb through ANDROID_HOME, all under env -i with a temporary HOME; the adb server on the
# default port is never touched.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iOS simulators need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
cp dist/ax-helper.swift "$tmp/ax-helper.swift"
trap 'set +e; pkill -f "sleep 97\.47"; cp "$tmp/ax-helper.swift" dist/ax-helper.swift; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }
# devicectl's displays JSON on stdin to karagoz's rotation, by the same table; anything unreadable is null.
rotation_of() { node -e '
  try {
    const d = JSON.parse(require("fs").readFileSync(0, "utf8")).result.displays;
    const o = (d.find((x) => x.primary === true) ?? d[0]).currentOrientation;
    console.log(JSON.stringify({ rot0: 0, rot90: 270, rot180: 180, rot270: 90 }[o] ?? null));
  } catch { console.log("null") }
'; }
now_ms() { node -e 'console.log(Date.now())'; }

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
[ -e "$fake/swiftc-fails" ] && { echo "error: fake compile" >&2; exit 1; }
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
printf '#!/bin/sh\nexec /bin/sh "%s/helper" "\$@"\n' "$fake" > "\$out"
/bin/chmod +x "\$out"
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$tmp/dev/usr/bin/simctl" "$tmp/dev/usr/bin/devicectl" "$toolchain/swiftc"
cp "$tmp/dev/usr/bin/simctl" "$tmp/nocc/usr/bin/simctl"
build() { printf '<plist><dict><key>ProductBuildVersion</key><string>%s</string></dict></plist>\n' "$1" > "$tmp/version.plist"; }
build 27A266a
sims() { echo "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[$1]}}" > "$fake/list.json"; }
a1='{"udid":"A1","name":"iPhone 17","state":"Booted","isAvailable":true}'
a2='{"udid":"A2","name":"iPhone 17 Pro","state":"Booting","isAvailable":true}'
helper() { printf '%s\n' "$1" > "$fake/helper"; }
rot() { echo "echo '{\"result\":{\"displays\":[{\"primary\":true,\"currentOrientation\":\"$1\"}]}}'" > "$fake/devicectl"; }
compiles() { [ -e "$fake/swiftc.log" ] && /usr/bin/wc -l < "$fake/swiftc.log" | tr -d ' ' || echo 0; }
no_tmp() { [ -z "$(find "$tmp/home/Library/Caches/karagoz" -name '*.tmp' 2>/dev/null)" ] || fail "$1 left a *.tmp file"; }
# karagoz with only the fakes. A variable for one call goes inside the substitution: an assignment before a shell
# function call outlives the call in sh.
k() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev" \
  "$node_bin" dist/cli.js "$@" 2>/dev/null; }
refuses() { # <code> <label> <karagoz output> <exit>
  [ "$4" -ne 0 ] || fail "$2 exited 0: $3"
  [ "$(printf '%s' "$3" | code_of)" = "$1" ] || fail "$2: expected $1, got: $3"
}
says() { # <label> <karagoz output> <text>
  case "$(printf '%s' "$2" | message_of)" in *"$3"*) ;; *) fail "$1: message lacks '$3': $2" ;; esac
}
ok=""

# 1. Real Mac: the first booted simulator, read twice in full by UDID with the selected Xcode and a fake adb that lists
# nothing, then once compact. The first call compiles; the second reuses the binary and is fast; the compact read has
# no element outside the screen; no helper process is left.
framework=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl
booted=$("$framework" list devices --json | node -e '
  const { devices } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const d = Object.entries(devices).filter(([k]) => k.startsWith("com.apple.CoreSimulator.SimRuntime.iOS-")).flatMap(([, l]) => l)
    .find((d) => d.isAvailable === true && d.state === "Booted");
  console.log(d ? d.udid : "");
')
if [ -n "$booted" ]; then
  real() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
  out=$(real ui-tree --device "$booted" --detail full) || fail "real ui-tree exited non-zero: $out"
  pixels=$(real screenshot --device "$booted" | node -e 'const p = JSON.parse(require("fs").readFileSync(0, "utf8")).pixels; console.log(`${p.width} ${p.height}`)')
  rotation=$(/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl device info \
    displays --device "$booted" --json-output - -q 2>/dev/null | rotation_of)
  # $1: compact or full.
  contract() { node -e '
    const [udid, rot, w, h, detail] = process.argv.slice(1);
    const text = require("fs").readFileSync(0, "utf8");
    const fail = (m) => { console.log("FAIL: real simulator: " + m + ": " + text.slice(0, 300)); process.exit(1); };
    if (text.includes("\n")) fail("not one line");
    const r = JSON.parse(text);
    if (Object.keys(r).join(",") !== "device,rotation,root") fail("keys");
    if (r.device !== udid) fail("device");
    if (r.rotation !== JSON.parse(rot)) fail("rotation differs from devicectl: " + rot);
    if (r.root.role !== "Application") fail("root role");
    if (JSON.stringify(r.root.bounds) !== JSON.stringify([0, 0, Number(w), Number(h)])) fail("root bounds are not the screenshot pixels " + w + "x" + h);
    const order = ["role", "label", "identifier", "value", "focused", "selected", "enabled", "bounds", "children"];
    const walk = (n) => {
      const keys = Object.keys(n);
      if (keys.join(",") !== order.filter((k) => keys.includes(k)).join(",")) fail("node keys " + keys);
      const b = n.bounds;
      if (b.length !== 4 || !b.every(Number.isFinite) || b[2] < b[0] || b[3] < b[1]) fail("bounds " + JSON.stringify(b));
      if (detail === "compact" && n !== r.root && (b[2] <= b[0] || b[3] <= b[1] || b[2] <= 0 || b[3] <= 0 || b[0] >= Number(w) || b[1] >= Number(h))) {
        fail("compact: " + n.role + " is off screen: " + JSON.stringify(b));
      }
      (n.children ?? []).forEach(walk);
    };
    walk(r.root);
  ' "$booted" "$rotation" $pixels "$1"; }
  printf '%s' "$out" | contract full || exit 1
  bin=$(ls "$tmp"/home/Library/Caches/karagoz/*/ax)
  before=$(stat -f %m "$bin")
  start=$(now_ms)
  out=$(real ui-tree --device "$booted" --detail full) || fail "second real ui-tree exited non-zero: $out"
  real_ms=$(( $(now_ms) - start ))
  [ "$real_ms" -lt 1500 ] || fail "second real ui-tree took ${real_ms} ms"
  [ "$(stat -f %m "$bin")" = "$before" ] || fail "the second call rebuilt the helper"
  out=$(real ui-tree --device "$booted") || fail "compact real ui-tree exited non-zero: $out"
  printf '%s' "$out" | contract compact || exit 1
  ! pgrep -f 'Caches/karagoz/.*/ax' >/dev/null || fail "a helper process outlived karagoz"
  ok="real ${pixels% *}x${pixels#* } (second ${real_ms} ms)"
  rm -rf "$tmp/home/Library"
else
  echo "SKIP: no booted simulator"
  ok="real skipped"
fi

# 2. Mapping, on a points tree: subrole over role without AX, empty strings dropped, flags only when they differ from
# the default, bounds = frame x scale rounded to 0.01 and not clipped, K24 field order, rotation from devicectl.
sims "$a1"; rot rot270
cat > "$fake/tree.json" <<'TREE'
{"screen":{"width":1206,"height":2622,"scale":3},"root":{"role":"AXApplication","label":"Fixture","frame":[0,0,402,874],"children":[
{"role":"AXCheckBox","subrole":"AXSwitch","label":"Wi-Fi","value":"1","frame":[24.333333333333314,88.00000000000001,168.33333333333334,191]},
{"role":"AXButton","label":"Delete","identifier":"delete","enabled":false,"frame":[16,300,100,44]},
{"role":"AXButton","label":"","selected":true,"focused":true,"frame":[0,400,402,50]},
{"role":"AXStaticText","label":"Below","frame":[10,900,100,20],"children":[{"role":"AXGroup","subrole":"","identifier":"","frame":[10,900,1,1]}]}]}}
TREE
helper "/bin/cat '$fake/tree.json'"
out=$(k ui-tree --device A1 --detail full) || fail "mapping exited non-zero: $out"
[ "$out" = '{"device":"A1","rotation":90,"root":{"role":"Application","label":"Fixture","bounds":[0,0,1206,2622],"children":[{"role":"Switch","label":"Wi-Fi","value":"1","bounds":[73,264,578,837]},{"role":"Button","label":"Delete","identifier":"delete","enabled":false,"bounds":[48,900,348,1032]},{"role":"Button","focused":true,"selected":true,"bounds":[0,1200,1206,1350]},{"role":"StaticText","label":"Below","bounds":[30,2700,330,2760],"children":[{"role":"Group","bounds":[30,2700,33,2703]}]}]}}' ] \
  || fail "mapping gave $out"
[ "$(compiles)" = 1 ] || fail "the first call compiled $(compiles) times"

# 2b. Compact: an unlabeled Group goes and its children move up; an element below the screen goes.
cat > "$fake/compact.json" <<'TREE'
{"screen":{"width":1206,"height":2622,"scale":3},"root":{"role":"AXApplication","label":"Fixture","frame":[0,0,402,874],"children":[
{"role":"AXGroup","frame":[0,100,402,100],"children":[{"role":"AXStaticText","label":"Hello","frame":[10,110,100,20]},{"role":"AXButton","label":"OK","frame":[200,110,100,40]}]},
{"role":"AXStaticText","label":"Below","frame":[10,900,100,20]}]}}
TREE
helper "/bin/cat '$fake/compact.json'"
out=$(k ui-tree --device A1) || fail "compact exited non-zero: $out"
[ "$out" = '{"device":"A1","rotation":90,"root":{"role":"Application","label":"Fixture","bounds":[0,0,1206,2622],"children":[{"role":"StaticText","label":"Hello","bounds":[30,330,330,390]},{"role":"Button","label":"OK","bounds":[600,330,900,450]}]}}' ] \
  || fail "compact gave $out"

# 3. The 1080x2340 panel (12 mini, 13 mini) scales by 1080/375, as screenshot does.
helper "echo '{\"screen\":{\"width\":1080,\"height\":2340,\"scale\":3},\"root\":{\"role\":\"AXApplication\",\"frame\":[0,0,375,812.5],\"children\":[{\"role\":\"AXButton\",\"frame\":[10,10,100,20]}]}}'"
line=$(k ui-tree --device A1 | node -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")).root; console.log(JSON.stringify([r.bounds, r.children[0].bounds]))')
[ "$line" = '[[0,0,1080,2340],[28.8,28.8,316.8,86.4]]' ] || fail "mini gave $line"

# 4. Cache: same key, no compile; a new Xcode build or a changed source compiles again.
out=$(k ui-tree --device A1) || fail "cached call exited non-zero: $out"
[ "$(compiles)" = 1 ] || fail "a cached call compiled"
build 27A300b
out=$(k ui-tree --device A1) || fail "new build exited non-zero: $out"
[ "$(compiles)" = 2 ] || fail "a new Xcode build did not compile"
echo '// changed' >> dist/ax-helper.swift
out=$(k ui-tree --device A1) || fail "changed source exited non-zero: $out"
[ "$(compiles)" = 3 ] || fail "a changed source did not compile"
cp "$tmp/ax-helper.swift" dist/ax-helper.swift
no_tmp "a compile"

# 5. No compiler: a developer dir with simctl but no swiftc.
out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/nocc" \
  "$node_bin" dist/cli.js ui-tree --device A1 2>/dev/null) && st=0 || st=$?
refuses HELPER_FAILED "no swiftc" "$out" "$st"
says "no swiftc" "$out" "$tmp/nocc/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"

# 6. A failing compile carries swiftc's own error and leaves no temporary file.
build 27A400c; touch "$fake/swiftc-fails"
out=$(k ui-tree --device A1) && st=0 || st=$?
refuses HELPER_FAILED "failing compile" "$out" "$st"
says "failing compile" "$out" "error: fake compile"
no_tmp "a failed compile"
rm "$fake/swiftc-fails"; build 27A266a

# 7. Helper exits: 2 is this Xcode's interface, 3 is this screen, a signal is a crash, bad output cannot be parsed.
helper "echo 'ax: no AXPTranslator' >&2; exit 2"
out=$(k ui-tree --device A1) && st=0 || st=$?
refuses HELPER_FAILED "helper exit 2" "$out" "$st"
says "helper exit 2" "$out" "no AXPTranslator"
says "helper exit 2" "$out" "update karagoz"
helper "echo 'ax: no frontmost application' >&2; exit 3"
out=$(k ui-tree --device A1) && st=0 || st=$?
refuses CAPTURE_FAILED "helper exit 3" "$out" "$st"
says "helper exit 3" "$out" "ax: no frontmost application"
helper "echo garbage"
out=$(k ui-tree --device A1) && st=0 || st=$?
refuses CAPTURE_FAILED "garbage output" "$out" "$st"
says "garbage output" "$out" "cannot parse"
helper "echo '{\"screen\":{\"width\":1206,\"height\":2622,\"scale\":3},\"root\":{\"role\":\"AXApplication\"}}'"
out=$(k ui-tree --device A1) && st=0 || st=$?
refuses CAPTURE_FAILED "node without a frame" "$out" "$st"
says "node without a frame" "$out" "cannot parse"
helper 'kill -SEGV $$'
out=$(k ui-tree --device A1) && st=0 || st=$?
refuses HELPER_FAILED "crashed helper" "$out" "$st"
says "crashed helper" "$out" "SIGSEGV"

# 7b. An app opened while app accessibility was off reads as a root with no size and no children: karagoz turns the
# setting back on and asks for a restart. With the setting on, the same root comes back as it is; a real root is
# never checked.
rot rot0
empty='{"screen":{"width":1206,"height":2622,"scale":3},"root":{"role":"AXApplication","frame":[0,0,0,0]}}'
helper "echo '$empty'"
rm -f "$fake/seq" "$fake/appax.log"; echo 0 > "$fake/appax"
out=$(k ui-tree --device A1) && st=0 || st=$?
refuses CAPTURE_FAILED "empty root, setting off" "$out" "$st"
says "empty root, setting off" "$out" "restart the app"
[ "$(cat "$fake/appax.log" 2>/dev/null)" = write ] || fail "empty root, setting off: not written back"
rm -f "$fake/seq" "$fake/appax.log"; echo 1 > "$fake/appax"
out=$(k ui-tree --device A1) && st=0 || st=$?
[ "$st" = 0 ] && [ "$out" = '{"device":"A1","rotation":0,"root":{"role":"Application","bounds":[0,0,0,0]}}' ] \
  || fail "empty root, setting on: exit $st, $out"
[ ! -e "$fake/appax.log" ] || fail "empty root, setting on: written"
helper "echo '{\"screen\":{\"width\":1206,\"height\":2622,\"scale\":3},\"root\":{\"role\":\"AXApplication\",\"frame\":[0,0,402,874]}}'"
rm -f "$fake/seq"; echo 0 > "$fake/appax"
out=$(k ui-tree --device A1) && st=0 || st=$?
[ "$st" = 0 ] && [ ! -e "$fake/seq" ] || fail "a sized root read the setting: exit $st, $out"

# 8. A hung helper ends at the 30 s timeout and leaves no process behind.
helper "exec /bin/sleep 97.47"
start=$(date +%s)
out=$(k ui-tree --device A1) && st=0 || st=$?
took=$(( $(date +%s) - start ))
refuses CAPTURE_FAILED "hung helper" "$out" "$st"
[ "$took" -ge 29 ] && [ "$took" -le 40 ] || fail "hung helper took ${took}s"
sleep 1
! pgrep -f 'sleep 97\.47' >/dev/null || fail "the hung helper outlived karagoz"

# 9. A booting simulator is not ready, and nothing is compiled for it.
sims "$a1,$a2"
before=$(compiles)
out=$(env -i HOME="$tmp/home2" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$tmp/dev" \
  "$node_bin" dist/cli.js ui-tree --device A2 2>/dev/null) && st=0 || st=$?
refuses DEVICE_NOT_READY "booting simulator" "$out" "$st"
[ "$(compiles)" = "$before" ] && [ ! -e "$tmp/home2/Library" ] || fail "a booting simulator compiled the helper"

# 10. Without devicectl the tree still reads, with rotation null.
sims "$a1"; helper "/bin/cat '$fake/tree.json'"; rm "$tmp/dev/usr/bin/devicectl"
line=$(k ui-tree --device A1 | node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(0, "utf8")).rotation))')
[ "$line" = null ] || fail "no devicectl gave rotation $line"

echo "ok: $ok, mapping, compact, mini, cache, no compiler, compile failure, helper exits, empty root, hung (${took}s), booting, no devicectl"
