#!/bin/sh
# Step 3.6: on macOS `logs` reads a booted iOS simulator's unified log with one `simctl spawn <udid> log show --style
# ndjson` and prints K29's shape with subsystem and category (K37). Fakes prove the argument checks before any call,
# Android's order for an iOS-only package name, the bound and predicate argv, the record mapping (levels, tag, Z
# offset, week-year dates), --lines, --since, APP_NOT_FOUND, log's own errors, malformed output, the hung read's
# timeout and target resolution. The real part launches a test app with a marker argument it logs and reads it back:
# the default read, --package, --lines, a --since chain with no repeat, the reader's own line left out, and launchd's
# exit line after terminate.
# Precondition: macOS with Xcode. A booted simulator on its home screen is used when one is running and no phone is
# attached, else the real part prints SKIP. It builds smoke/fixtures/input-ios, installs, launches, terminates and
# uninstalls dev.karagoz.probe, then checks the app is gone, the home screen is on the page it recorded and listapps is
# as before. Below CoreSimulator 1155.4 the HOME press installs karagoz's runner, which the smoke removes again, and
# only that the home screen is in front is checked. Nothing changes the log configuration. Fake simctl comes through DEVELOPER_DIR, fake adb through
# ANDROID_HOME, all under env -i; the adb server on the default port is never touched.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iOS simulators need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
framework=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl
booted=
started=
home=
apps=
fail() { echo "FAIL: $*"; exit 1; }
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }
# The records of a success result, one JSON line each. Fails unless stdout is one JSON line with records.
records_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  const { records } = JSON.parse(out);
  if (!Array.isArray(records)) process.exit(1);
  for (const record of records) console.log(JSON.stringify(record));
'; }
real() { env -i HOME="$tmp/home-real" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
tree() { real ui-tree --device "$booted" --detail full; }
# The root's label, or the home screen's page.
q() { node -e '
  const root = JSON.parse(require("fs").readFileSync(0, "utf8")).root;
  const all = [];
  const walk = (n) => { all.push(n); (n.children ?? []).forEach(walk); };
  walk(root);
  console.log(process.argv[1] === "root" ? root.label ?? "" : all.find((n) => n.identifier === "spotlight-pill")?.value ?? "");
' "$1"; }
# The installed bundle ids, sorted.
apps() {
  "$framework" listapps "$booted" > "$tmp/apps.plist"
  plutil -convert json -o - "$tmp/apps.plist" | node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(0, "utf8"))).sort().join(" "))'
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
# Puts the simulator back: Probe goes if it is there, HOME is pressed, the home screen must be on the recorded page
# and listapps must list what it listed before.
restore() {
  [ -n "$started" ] || return 0
  if "$framework" get_app_container "$booted" dev.karagoz.probe >/dev/null 2>&1; then
    "$framework" terminate "$booted" dev.karagoz.probe >/dev/null 2>&1
    "$framework" uninstall "$booted" dev.karagoz.probe >/dev/null 2>&1
  fi
  ! "$framework" get_app_container "$booted" dev.karagoz.probe >/dev/null 2>&1 || { echo "FAIL: the test app is still installed"; return 1; }
  [ "$(apps)" = "$apps" ] || { echo "FAIL: listapps differs from before the run"; return 1; }
  out=$(real key HOME --device "$booted")
  if [ "$(printf '%s' "$out" | code_of)" = NOT_SUPPORTED ]; then
    echo "note: home screen not checked (no key HOME before Xcode 27)"
    return 0
  fi
  # Below CoreSimulator 1155.4 that HOME went through karagoz's runner, which the first key installed (K49).
  if "$framework" listapps "$booted" 2>/dev/null | grep -q '"com.karagozmcp.runner.xctrunner"'; then
    home_back any
    back=$?
    out=$(real uninstall-runner --device "$booted")
    "$framework" listapps "$booted" 2>/dev/null | grep -q '"com.karagozmcp.runner.xctrunner"' \
      && { echo "FAIL: karagoz's runner is still installed: $out"; return 1; }
    return $back
  fi
  home_back
}
trap 'set +e; pkill -f "sleep 97\.61"; restore; st=$?; rm -rf "$tmp"; [ "$st" = 0 ] || exit 1' EXIT

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them. simctl logs each call, and the
# spawn call's arguments one per line, so a predicate's spaces and quotes stay visible.
fake="$tmp/fake"
mkdir -p "$tmp/sdk/platform-tools" "$tmp/dev/usr/bin" "$tmp/nosim" "$tmp/home" "$fake"
cat > "$tmp/sdk/platform-tools/adb" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/adb-calls"
case "\$*" in
  devices) /bin/cat "$fake/adb-devices" ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/dev/usr/bin/simctl" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/calls"
case "\$1 \$2" in
  "list devices") /bin/cat "$fake/list.json" ;;
  "get_app_container A1")
    if [ "\$3" = dev.karagoz.missing ]; then
      printf 'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2):\nNo such file or directory\n' >&2
      exit 2
    fi
    /bin/cat "$fake/container" ;;
  "spawn A1")
    for a in "\$@"; do printf '%s\n' "\$a"; done > "$fake/argv"
    [ ! -e "$fake/stderr" ] || /bin/cat "$fake/stderr" >&2
    # exec: the timeout kills only the direct child, and a forked sleep would outlive the run.
    if [ -e "$fake/hang" ]; then /bin/cat "$fake/hang"; exec /bin/sleep 97.61; fi
    /bin/cat "$fake/ndjson"
    exit "\$(/bin/cat "$fake/exit" 2>/dev/null || echo 0)" ;;
  *) echo "fake simctl: unexpected arguments: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$tmp/dev/usr/bin/simctl"
a1='{"udid":"A1","name":"iPhone 17","state":"Booted","isAvailable":true}'
a2='{"udid":"A2","name":"iPhone 17 Pro","state":"Booting","isAvailable":true}'
sims() { echo "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[$1]}}" > "$fake/list.json"; }
android() { printf 'List of devices attached\n%s\n' "$1" > "$fake/adb-devices"; }
# What log show prints next: $1 as ndjson (nothing when empty), no stderr, exit 0.
answer() {
  if [ -n "$1" ]; then printf '%s\n' "$1"; fi > "$fake/ndjson"
  rm -f "$fake/stderr" "$fake/hang" "$fake/exit"
}
finished='{"count":0,"finished":1}'
sims "$a1,$a2"
android ''
answer "$finished"

dev="$tmp/dev"
# karagoz with only the fakes. Sets $out and $st, and clears the call logs.
call() {
  rm -f "$fake/calls" "$fake/adb-calls" "$fake/argv"
  out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$dev" \
    "$node_bin" dist/cli.js "$@" 2>/dev/null) && st=0 || st=$?
}
succeeds() { # <label> <expected stdout>
  [ "$st" = 0 ] && [ "$out" = "$2" ] || fail "$1: exit $st, got $out, expected $2"
}
refuses() { # <code> <label> [<message>]
  [ "$st" -ne 0 ] || fail "$2 exited 0: $out"
  [ "$(printf '%s' "$out" | code_of)" = "$1" ] || fail "$2: expected $1, got: $out"
  [ $# -lt 3 ] || [ "$(printf '%s' "$out" | message_of)" = "$3" ] || fail "$2: expected the message '$3', got: $out"
}
log() { if [ -e "$fake/$1" ]; then cat "$fake/$1"; else echo none; fi; }
argv_is() { # <label> <spawn argument>...
  label=$1
  shift
  printf '%s\n' "$@" > "$fake/want"
  cmp -s "$fake/want" "$fake/argv" || fail "$label: simctl got '$(log argv | tr '\n' '|')', expected '$(tr '\n' '|' < "$fake/want")'"
}
show() { echo spawn A1 log show --style ndjson --info --debug; }
p0='type == logEvent AND NOT (process == "log" AND composedMessage BEGINSWITH "log run noninteractively")'

# a. Argument checks, before any call: not even the device listing.
nothing_sent() { [ "$(log calls)" = none ] && [ "$(log adb-calls)" = none ] || fail "$1 reached a tool: $(log calls) / $(log adb-calls)"; }
call logs --package 'a;b'
refuses INVALID_ARGS "--package 'a;b'" "'a;b' is not a package name"; nothing_sent "--package 'a;b'"
call logs --since x
refuses INVALID_ARGS "--since x" "--since must be Unix time in seconds (got 'x')"; nothing_sent "--since x"
call logs --lines 0
refuses INVALID_ARGS "--lines 0" "--lines must be a whole number from 1 to 999999999 (got '0')"; nothing_sent "--lines 0"

# b. A name only iOS allows: the target comes first, then Android's own check (K37).
sims ''
call logs --package com.foo-bar
refuses NO_DEVICE "com.foo-bar with no device"
android "$(printf 'emulator-5554\tdevice')"
call logs --package com.foo-bar
refuses INVALID_ARGS "com.foo-bar on Android" "'com.foo-bar' is not a package name"
[ "$(log adb-calls)" = devices ] || fail "com.foo-bar on Android sent: $(log adb-calls)"
android ''
sims "$a1,$a2"

# c. The bound and the predicate. The container path holds a quote and a backslash, which the predicate escapes.
call logs --device A1
succeeds "no flags" '{"device":"A1","records":[],"omitted":0}'
argv_is "no flags" $(show) --last 1m --predicate "$p0"
call logs --since 1792047461.304527 --device A1
argv_is "--since" $(show) --start @1792047461 --predicate "$p0"
printf '%s\n' '/c/Pro"b\e.app' > "$fake/container"
pp='type == logEvent AND (processImagePath CONTAINS "/Pro\"b\\e.app/" OR (process == "launchd_sim" AND subsystem CONTAINS "UIKitApplication:dev.karagoz.probe[" AND composedMessage BEGINSWITH "exited "))'
call logs --package dev.karagoz.probe --device A1
succeeds "--package" '{"device":"A1","package":"dev.karagoz.probe","records":[],"omitted":0}'
argv_is "--package" $(show) --last 1h --predicate "$pp"
call logs --package dev.karagoz.probe --since 1792047461 --device A1
argv_is "--package --since" $(show) --start @1792047461 --predicate "$pp"

# d. Mapping: levels, tag from the image path, missing fields, a multi-line message, offsets, extra keys ignored.
# log prints a week-year: late December can carry next year, early January last year (K37).
year=$(node -e 'console.log(new Date().getUTCFullYear())')
answer "$(cat <<EOF
{"timestamp":"2026-10-15 09:57:41.304361+0300","processID":11,"threadID":101,"messageType":"Debug","processImagePath":"/x/Probe.app/Probe","subsystem":"dev.karagoz.probe","category":"smoke","eventMessage":"debug","traceID":7}
{"timestamp":"2026-10-15 09:57:41.304527+0300","processID":12,"threadID":102,"messageType":"Info","processImagePath":"/usr/libexec/locationd","subsystem":"com.apple.locationd","category":"","eventMessage":"info"}
{"timestamp":"2026-10-15 06:57:41.000001Z","processID":13,"threadID":103,"messageType":"Default","processImagePath":"","eventMessage":"line1\nline2"}
{"timestamp":"2026-10-15 04:57:42.999999-0200","processID":14,"threadID":104,"messageType":"Error","subsystem":"s","category":"c","eventMessage":"error"}
{"timestamp":"2026-10-15 09:57:43.000010+0300","processID":15,"threadID":105,"messageType":"Fault","processImagePath":"/x/Probe.app/PlugIns/W.appex/W","subsystem":"","category":"","eventMessage":"fault"}
{"timestamp":"2026-10-15 09:57:43.000010+0300","processID":16,"threadID":106,"messageType":"Bogus","processImagePath":"/bin/x","subsystem":"","category":"","eventMessage":"odd"}
{"timestamp":"$((year + 1))-12-30 10:00:00.000001Z","processID":17,"threadID":107,"messageType":"Default","processImagePath":"/bin/y","eventMessage":"december"}
{"timestamp":"$((year - 2))-01-02 10:00:00.000002Z","processID":18,"threadID":108,"messageType":"Default","processImagePath":"/bin/y","eventMessage":"january"}
{"timestamp":"$((year + 1))-12-26 10:00:00.000003Z","processID":19,"threadID":109,"messageType":"Default","processImagePath":"/bin/y","eventMessage":"december 26"}
$finished
EOF
)"
call logs --device A1
[ "$st" = 0 ] || fail "mapping exited $st: $out"
recs=$(printf '%s' "$out" | records_of) || fail "mapping: not one JSON line with records: $out"
want=$(cat <<'EOF'
{"time":1792047461.304361,"pid":11,"tid":101,"level":"D","tag":"Probe","subsystem":"dev.karagoz.probe","category":"smoke","message":"debug"}
{"time":1792047461.304527,"pid":12,"tid":102,"level":"I","tag":"locationd","subsystem":"com.apple.locationd","category":"","message":"info"}
{"time":1792047461.000001,"pid":13,"tid":103,"level":"I","tag":"","subsystem":"","category":"","message":"line1\nline2"}
{"time":1792047462.999999,"pid":14,"tid":104,"level":"E","tag":"","subsystem":"s","category":"c","message":"error"}
{"time":1792047463.00001,"pid":15,"tid":105,"level":"F","tag":"W","subsystem":"","category":"","message":"fault"}
{"time":1792047463.00001,"pid":16,"tid":106,"level":"?","tag":"x","subsystem":"","category":"","message":"odd"}
EOF
)
want="$want
$(node -e '
  const y = Number(process.argv[1]);
  const at = (year, month, day, us) => (Date.UTC(year, month - 1, day, 10) / 1000 * 1e6 + us) / 1e6;
  const rec = (time, pid, message) => ({ time, pid, tid: pid + 90, level: "I", tag: "y", subsystem: "", category: "", message });
  console.log(JSON.stringify(rec(at(y, 12, 30, 1), 17, "december")));
  console.log(JSON.stringify(rec(at(y - 1, 1, 2, 2), 18, "january")));
  console.log(JSON.stringify(rec(at(y, 12, 26, 3), 19, "december 26")));
' "$year")"
[ "$recs" = "$want" ] || fail "mapping: got
$recs
expected
$want"
[ "$out" = "{\"device\":\"A1\",\"records\":[$(printf '%s\n' "$want" | paste -sd , -)],\"omitted\":0}" ] || fail "mapping envelope: $out"

# e. --lines keeps the newest and counts the rest; a record's time passed back as --since excludes that record.
answer "$(for i in 1 2 3 4 5; do
  printf '{"timestamp":"2026-10-15 09:57:41.00000%s+0300","processID":%s,"threadID":%s,"messageType":"Info","processImagePath":"/bin/z","eventMessage":"m%s"}\n' "$i" "$i" "$i" "$i"
done; echo "$finished")"
call logs --lines 2 --device A1
[ "$st" = 0 ] || fail "--lines 2 exited $st: $out"
[ "$(printf '%s' "$out" | records_of | sed 's/.*"message":"\([^"]*\)"}/\1/' | paste -sd ' ' -)" = "m4 m5" ] || fail "--lines 2: $out"
case $out in *'"omitted":3}') ;; *) fail "--lines 2: omitted is not 3: $out" ;; esac
call logs --device A1
t3=$(printf '%s' "$out" | records_of | sed -n 3p | sed 's/^{"time":\([0-9.]*\),.*/\1/')
call logs --since "$t3" --device A1
[ "$(printf '%s' "$out" | records_of | sed 's/.*"message":"\([^"]*\)"}/\1/' | paste -sd ' ' -)" = "m4 m5" ] || fail "--since $t3: $out"
case $out in *'"omitted":0}') ;; *) fail "--since $t3: omitted is not 0: $out" ;; esac
answer "$finished"
call logs --since 1792047461 --device A1
succeeds "nothing found" '{"device":"A1","records":[],"omitted":0}'

# f. An app that is not installed stops before log runs.
call logs --package dev.karagoz.missing --device A1
refuses APP_NOT_FOUND "not installed" "app 'dev.karagoz.missing' is not installed on A1"
! grep -q '^spawn ' "$fake/calls" || fail "not installed: log show ran"

# g. log's own error: its stderr without the getpwuid_r line every call prints.
answer ''
printf '%s\n' 'getpwuid_r did not find a match for uid 501' 'log: Bad predicate (x): x' > "$fake/stderr"
echo 64 > "$fake/exit"
call logs --device A1
refuses SIMCTL_FAILED "log exits 64" "log: Bad predicate (x): x"

# h. Output that is not log show's ndjson.
answer "$(printf '%s\n' 'not json' "$finished")"
call logs --device A1
refuses SIMCTL_FAILED "not json" "unexpected log output: not json"
answer '{"timestamp":"2026-10-15 09:57:41.000001+0300","processID":1,"threadID":1,"messageType":"Info","eventMessage":"x"}'
call logs --device A1
refuses SIMCTL_FAILED "no summary line" "log show ended without its summary line"

# i. A hung read is killed after 30 s, also when it leaves half a line behind. The message suggests --package only
# when it was not given.
answer "$finished"
for part in '' '{"timestamp":"2026'; do
  printf '%s' "$part" > "$fake/hang"
  start=$(date +%s)
  if [ -z "$part" ]; then
    call logs --device A1
    timeout_text='log show did not finish within 30s. Pass a later --since, or --package, to read less of the simulator log.'
  else
    call logs --package dev.karagoz.probe --device A1
    timeout_text='log show did not finish within 30s. Pass a later --since to read less of the simulator log.'
  fi
  took=$(($(date +%s) - start))
  refuses SIMCTL_TIMEOUT "hung log show '$part'" "$timeout_text"
  [ "$took" -ge 29 ] && [ "$took" -le 40 ] || fail "hung log show '$part' took ${took}s"
  sleep 1
  ! pgrep -f 'sleep 97\.61' >/dev/null || fail "the hung simctl outlived karagoz"
done
rm -f "$fake/hang"

# j. A booting simulator; k. no simctl leaves A1 unlisted.
call logs --device A2
refuses DEVICE_NOT_READY "booting simulator"
dev="$tmp/nosim"
call logs --device A1
refuses DEVICE_NOT_FOUND "no simctl"
dev="$tmp/dev"

# l. --package keeps a record only when its process ran this install's build: the log prints the path of the first
# install of a build (K37), so the folder name picks candidates and the file's LC_UUID decides. W is a fat binary.
app="$tmp/apps/Probe.app"
mkdir -p "$app/PlugIns/W.appex"
node -e '
  const fs = require("fs");
  const thin = (uuid) => {
    const b = Buffer.alloc(56);
    b.writeUInt32LE(0xfeedfacf, 0); b.writeUInt32LE(1, 16); b.writeUInt32LE(24, 20);
    b.writeUInt32LE(0x1b, 32); b.writeUInt32LE(24, 36); Buffer.from(uuid.replace(/-/g, ""), "hex").copy(b, 40);
    return b;
  };
  const [dir, probe, x86, arm] = process.argv.slice(1);
  fs.writeFileSync(`${dir}/Probe`, thin(probe));
  const fat = Buffer.alloc(8192 + 56);
  fat.writeUInt32BE(0xcafebabe, 0); fat.writeUInt32BE(2, 4);
  fat.writeUInt32BE(4096, 16); fat.writeUInt32BE(56, 20); thin(x86).copy(fat, 4096);
  fat.writeUInt32BE(8192, 36); fat.writeUInt32BE(56, 40); thin(arm).copy(fat, 8192);
  fs.writeFileSync(`${dir}/PlugIns/W.appex/W`, fat);
' "$app" 6DA4FE03-DAB4-3781-A289-AF1ECEBCFD0B 11111111-2222-3333-4444-555555555555 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
printf '%s\n' "$app" > "$fake/container"
rec() { # <pid> <path> <uuid>
  printf '{"timestamp":"2026-10-15 09:57:41.00000%s+0300","processID":%s,"threadID":1,"messageType":"Default","processImagePath":"%s","processImageUUID":"%s","eventMessage":"m%s"}\n' "$1" "$1" "$2" "$3" "$1"
}
answer "$(
  rec 1 /old/25CA/Probe.app/Probe 6DA4FE03-DAB4-3781-A289-AF1ECEBCFD0B
  rec 2 /other/X/Probe.app/Probe 0F0F0F0F-0000-0000-0000-000000000000
  rec 3 /old/25CA/Probe.app/PlugIns/W.appex/W AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  rec 4 /old/25CA/Probe.app/PlugIns/Gone.appex/Gone 6DA4FE03-DAB4-3781-A289-AF1ECEBCFD0B
  rec 5 /sbin/launchd_sim 99999999-0000-0000-0000-000000000000
  echo "$finished"
)"
call logs --package dev.karagoz.probe --device A1
[ "$st" = 0 ] || fail "build filter exited $st: $out"
[ "$(printf '%s' "$out" | records_of | sed 's/.*"message":"\([^"]*\)"}/\1/' | paste -sd ' ' -)" = "m1 m3 m5" ] || fail "build filter: $out"
call logs --package dev.karagoz.probe --lines 1 --device A1
case $out in *'"message":"m5"}],"omitted":2}') ;; *) fail "build filter --lines 1: $out" ;; esac
answer "$finished"
fakes="fakes: arguments, android order, argv, mapping, lines, since, not installed, log error, malformed, hung (${took}s), targets, build filter"

# Real simulator: Probe logs each launch argument with Logger.notice, so a marker comes back as its own record.
phone=$({ command -v adb >/dev/null && adb devices | awk 'NR > 1 && $1 != "" && $1 !~ /^emulator-/'; ioreg -p IOUSB -w0 | grep -iE 'iPhone|iPad'; } || true)
booted=$("$framework" list devices --json | node -e '
  const { devices } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const d = Object.entries(devices).filter(([k]) => k.startsWith("com.apple.CoreSimulator.SimRuntime.iOS-")).flatMap(([, l]) => l)
    .find((d) => d.isAvailable === true && d.state === "Booted");
  console.log(d ? d.udid : "");
')
if [ -n "$phone" ]; then
  echo "SKIP: a phone is attached, the real part does not run"
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
! "$framework" get_app_container "$booted" dev.karagoz.probe >/dev/null 2>&1 \
  || fail "dev.karagoz.probe is already installed on $booted (left by an interrupted run?); uninstall it first"
apps=$(apps)
sh smoke/fixtures/input-ios/build.sh "$tmp"
r() { out=$(real logs --device "$booted" "$@") || fail "logs $*: $out"; }
# Checks $out against one rule; argv after the rule name are its values. Exit 1 prints the reason.
check() { printf '%s' "$out" | node -e '
  const out = require("fs").readFileSync(0, "utf8");
  const { records, omitted } = JSON.parse(out);
  const [rule, a, b] = process.argv.slice(1);
  const has = (m) => records.find((r) => r.message === m);
  const bad = (why) => { console.log(why); process.exit(1); };
  if (rule === "has") { if (!has(a)) bad(`no record with the message ${a}`); }
  if (rule === "marker") {
    const r = has(a);
    if (r.tag !== "Probe" || r.subsystem !== "dev.karagoz.probe" || r.category !== "smoke" || r.level !== "I") bad(`marker record: ${JSON.stringify(r)}`);
    if (records.some((r) => r.tag === "log" && r.message.startsWith("log run noninteractively"))) bad("the reader'"'"'s own record came back");
  }
  if (rule === "own" && records.some((r) => r.tag !== "Probe" && r.tag !== "launchd_sim")) bad(`another process: ${JSON.stringify(records.find((r) => r.tag !== "Probe" && r.tag !== "launchd_sim"))}`);
  if (rule === "one" && (records.length !== 1 || !(omitted > 0))) bad(`expected one record and omitted > 0: ${out.slice(0, 300)}`);
  if (rule === "latest") console.log(JSON.stringify(Math.max(...records.map((r) => r.time))));
  if (rule === "after") {
    if (records.some((r) => !(r.time > Number(a)))) bad(`a record is not after ${a}`);
    if (has(b)) bad(`the earlier marker ${b} came back`);
    if (!records.some((r) => r.tag === "launchd_sim" && r.message.startsWith("exited "))) bad("no launchd exited line");
  }
' "$@"; }
# Reads with the arguments after $1 until a record's message is $1, for up to 10 s.
wait_for() {
  m=$1
  shift
  i=0
  until r "$@" && check has "$m" >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 20 ] || fail "logs $*: no record with the message $m after 10 s"
    sleep 0.5
  done
}
started=1
# An app launch writes ~2,400 records in the second after its first line (measured): the newest 1000 missed the marker.
many=100000

"$framework" install "$booted" "$tmp/Probe.app"
m1="karagoz-smoke-$$-$(date +%s)-one"
"$framework" launch "$booted" dev.karagoz.probe "$m1" >/dev/null
wait_for "$m1" --lines "$many"
why=$(check marker "$m1") || fail "default read: $why"

r --package dev.karagoz.probe --lines "$many"
why=$(check has "$m1") || fail "--package: $why"
why=$(check own) || fail "--package: $why"
t=$(check latest)
r --package dev.karagoz.probe --lines 1
why=$(check one) || fail "--package --lines 1: $why"
[ -z "${KARAGOZ_EXAMPLE:-}" ] || printf '%s\n' "$out" > "$KARAGOZ_EXAMPLE"

# Chain: after terminate and a second launch, --since the largest time so far returns only what came later.
"$framework" terminate "$booted" dev.karagoz.probe >/dev/null
m2="karagoz-smoke-$$-$(date +%s)-two"
"$framework" launch "$booted" dev.karagoz.probe "$m2" >/dev/null
wait_for "$m2" --package dev.karagoz.probe --since "$t" --lines "$many"
why=$(check after "$t" "$m1") || fail "--since $t: $why"

echo "ok: real $booted: default, package, lines, chain, exit line, $fakes"
