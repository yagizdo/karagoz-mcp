#!/bin/sh
# Step 3.5: on macOS install, launch, terminate and uninstall reach a booted iOS simulator through simctl in K28's
# shapes (K36). Fakes prove every argument check before any call, the wrong-platform file, launch's output check,
# APP_NOT_FOUND from get_app_container, "found nothing to terminate" as success, SYSTEM_APP with no uninstall sent,
# INSTALL_FAILED and UNINSTALL_FAILED with simctl's <domain>:<code>, target resolution and each verb's timeout message
# over a hung simctl (terminate, install, uninstall).
# Precondition: macOS with Xcode. A booted simulator on its home screen is used when one is running and no phone is
# attached, else the real part prints SKIP. It builds smoke/fixtures/input-ios, installs it as .app and .ipa,
# launches, terminates and uninstalls dev.karagoz.probe, tries a bundle with no Info.plist, then checks the app is gone,
# the home screen is on the page it recorded and listapps is as before. System apps never reach the real simulator.
# Fake simctl comes through DEVELOPER_DIR, fake adb through ANDROID_HOME, all under env -i; the adb server on the
# default port is never touched.
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
reason_of() { node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.reason ?? "none")'; }
real() { env -i HOME="$tmp/home-real" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
tree() { real ui-tree --device "$booted"; }
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
home_back() {
  i=0
  until [ "$(tree | q home)" = "$home" ]; do
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
    "$framework" uninstall "$booted" dev.karagoz.probe >/dev/null 2>&1
  fi
  ! "$framework" get_app_container "$booted" dev.karagoz.probe >/dev/null 2>&1 || { echo "FAIL: the test app is still installed"; return 1; }
  [ "$(apps)" = "$apps" ] || { echo "FAIL: listapps differs from before the run"; return 1; }
  out=$(real key HOME --device "$booted")
  if [ "$(printf '%s' "$out" | code_of)" = NOT_SUPPORTED ]; then
    echo "note: home screen not checked (no key HOME before Xcode 27)"
    return 0
  fi
  home_back
}
trap 'set +e; pkill -f "sleep 97\.51"; restore; st=$?; rm -rf "$tmp"; [ "$st" = 0 ] || exit 1' EXIT

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them. Each records its arguments.
fake="$tmp/fake"
mkdir -p "$tmp/sdk/platform-tools" "$tmp/dev/usr/bin" "$tmp/nosim" "$tmp/home" "$tmp/dir.ipa" \
  "$fake/Probe.app" "$fake/Device.app" "$fake/Plain.app" "$fake/Hang.app"
: > "$tmp/x.txt"
: > "$tmp/a.apk"
: > "$tmp/file.app"
cat > "$tmp/sdk/platform-tools/adb" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/adb-calls"
case "\$*" in
  devices) /bin/cat "$fake/adb-devices" ;;
  *) exit 1 ;;
esac
FAKE
# The device-build refusal as Xcode 27 prints it: three description lines, the last one past 300 characters.
cat > "$fake/device.err" <<'ERR'
An error was encountered processing the command (domain=IXUserPresentableErrorDomain, code=4):
App installation failed: “Probe” Needs to Be Updated
This app needs to be updated by the developer to work on this version of iOS.
The executable at /Users/someone/Library/Developer/CoreSimulator/Devices/A1/data/Library/Caches/com.apple.mobile.installd.staging/temp.Zq1wXk/extracted/Probe.app/Probe does not contain code for any platform and CPU architecture combination that is runnable on this device. The executable has code for these platforms and architectures: [iOS, arm64]. This device can run code for these platforms: iOS-simulator
Underlying error (domain=IXUserPresentableErrorDomain, code=4):
	App installation failed: “Probe” Needs to Be Updated
Underlying error (domain=MIInstallerErrorDomain, code=4):
	Failed to verify executable for app
ERR
cat > "$tmp/dev/usr/bin/simctl" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/calls"
err() { printf 'An error was encountered processing the command (domain=%s, code=%s):\n' "\$1" "\$2" >&2; shift 2; printf '%s\n' "\$@" >&2; }
case "\$*" in
  "list devices --json") /bin/cat "$fake/list.json" ;;
  "launch A1 dev.karagoz.probe-dash") echo 'dev.karagoz.probe-dash: 4242' ;;
  "launch A1 dev.karagoz.odd") echo garbage ;;
  "launch A1 dev.karagoz.refused")
    err FBSOpenApplicationServiceErrorDomain 1 'Simulator device failed to launch dev.karagoz.refused.' \
      'The request to open "dev.karagoz.refused" failed.' 'The request was denied by service delegate (SBMainWorkspace).'
    exit 1 ;;
  "launch A1 "*) err FBSOpenApplicationServiceErrorDomain 4 "Simulator device failed to launch \$3." "The request to open \"\$3\" failed."; exit 4 ;;
  "get_app_container A1 dev.karagoz.nope") err NSPOSIXErrorDomain 2 'The operation couldn’t be completed. No such file or directory'; exit 2 ;;
  "get_app_container A1 com.apple.Preferences")
    echo '/Library/Developer/CoreSimulator/Volumes/iOS_X/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/Applications/Preferences.app' ;;
  "get_app_container A1 "*) echo "/Users/someone/Library/Developer/CoreSimulator/Devices/A1/data/Containers/Bundle/Application/0C1E/\$3.app" ;;
  "terminate A1 dev.karagoz.idle")
    err NSPOSIXErrorDomain 3 'Simulator device failed to terminate dev.karagoz.idle.' 'found nothing to terminate'
    exit 3 ;;
  # exec: the timeout kills only the direct child, and a forked sleep would outlive the run.
  "terminate A1 dev.karagoz.hang") exec /bin/sleep 97.51 ;;
  "terminate A1 "*) ;;
  "uninstall A1 dev.karagoz.stuck")
    err IXErrorDomain 7 'Simulator device failed to uninstall dev.karagoz.stuck.' 'The operation could not be completed.'
    printf 'Underlying error (domain=IXErrorDomain, code=7):\n\tBusy\n' >&2
    exit 7 ;;
  "install A1 $fake/Device.app") /bin/cat "$fake/device.err" >&2; exit 4 ;;
  "install A1 $fake/Plain.app") echo 'simctl broke' >&2; exit 1 ;;
  # exec, as for the hung terminate.
  "install A1 $fake/Hang.app") exec /bin/sleep 97.51 ;;
  "uninstall A1 dev.karagoz.hang") exec /bin/sleep 97.51 ;;
  *) echo "fake simctl: unexpected arguments: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$tmp/dev/usr/bin/simctl"
a1='{"udid":"A1","name":"iPhone 17","state":"Booted","isAvailable":true}'
a2='{"udid":"A2","name":"iPhone 17 Pro","state":"Booting","isAvailable":true}'
sims() { echo "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[$1]}}" > "$fake/list.json"; }
android() { printf 'List of devices attached\n%s\n' "$1" > "$fake/adb-devices"; }
sims "$a1,$a2"
android ''

dev="$tmp/dev"
# karagoz with only the fakes. Sets $out and $st, and clears both call logs.
call() {
  rm -f "$fake/calls" "$fake/adb-calls"
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
reason_is() { # <label> <reason>
  [ "$(printf '%s' "$out" | reason_of)" = "$2" ] || fail "$1: expected the reason $2, got: $out"
}
# The simctl or adb call log, one call per line, or "none".
log() { if [ -e "$fake/$1" ]; then cat "$fake/$1"; else echo none; fi; }
has_call() { # <label> <log> <call>
  grep -qxF "$3" "$fake/$2" 2>/dev/null || fail "$1: no '$3' in $2: $(log "$2" | tr '\n' ';')"
}
lacks_call() { # <label> <log> <prefix>
  ! grep -q "^$3" "$fake/$2" 2>/dev/null || fail "$1: '$3' was sent: $(log "$2" | tr '\n' ';')"
}

# a. Argument checks, before any call: not even the device listing.
nothing_sent() { [ "$(log calls)" = none ] && [ "$(log adb-calls)" = none ] || fail "$1 reached a tool: $(log calls) / $(log adb-calls)"; }
call install "$tmp/x.txt"
refuses INVALID_ARGS "install x.txt" "'$tmp/x.txt' is not an .apk, .app or .ipa file"; nothing_sent "install x.txt"
call install "$tmp/missing.app"
refuses INVALID_ARGS "install missing.app" "no file at '$tmp/missing.app'"; nothing_sent "install missing.app"
call install "$tmp/file.app"
refuses INVALID_ARGS "install a file named .app" "'$tmp/file.app' is not a directory"; nothing_sent "install file.app"
call install "$tmp/dir.ipa"
refuses INVALID_ARGS "install a directory named .ipa" "'$tmp/dir.ipa' is not a file"; nothing_sent "install dir.ipa"
for value in 'a b' 'a..b'; do
  call launch "$value"
  refuses INVALID_ARGS "launch '$value'" "'$value' is not a package name"; nothing_sent "launch '$value'"
done
call terminate 'x/y'
refuses INVALID_ARGS "terminate 'x/y'" "'x/y' is not a package name"; nothing_sent "terminate 'x/y'"

# b. A file for the other platform: the target resolves, nothing is sent to it.
call install "$tmp/a.apk" --device A1
refuses INVALID_ARGS "apk on a simulator" "'$tmp/a.apk' is an Android app; A1 is an iOS simulator"
[ "$(log calls)" = "list devices --json" ] || fail "apk on a simulator sent: $(log calls)"
android "$(printf 'emulator-5554\tdevice')"
call install "$fake/Probe.app" --device emulator-5554
refuses INVALID_ARGS ".app on an emulator" "'$fake/Probe.app' is an iOS app; emulator-5554 is an Android device"
[ "$(log adb-calls)" = devices ] || fail ".app on an emulator sent: $(log adb-calls)"
android ''

# c. launch: simctl's "<id>: <pid>" is the success; no installed check follows it.
call launch dev.karagoz.probe-dash --device A1
succeeds launch '{"device":"A1","package":"dev.karagoz.probe-dash","activity":null}'
has_call launch calls "launch A1 dev.karagoz.probe-dash"
lacks_call launch calls get_app_container

# d. A failed launch asks get_app_container: not installed is APP_NOT_FOUND, installed keeps simctl's text.
call launch dev.karagoz.nope --device A1
refuses APP_NOT_FOUND "launch not installed" "app 'dev.karagoz.nope' is not installed on A1"
has_call "launch not installed" calls "get_app_container A1 dev.karagoz.nope"
call launch dev.karagoz.refused --device A1
refuses SIMCTL_FAILED "launch refused"
case "$(printf '%s' "$out" | message_of)" in *"denied by service delegate"*) ;; *) fail "launch refused lost simctl's text: $out" ;; esac
call launch dev.karagoz.odd --device A1
refuses SIMCTL_FAILED "launch odd output" "unexpected simctl output: garbage"
lacks_call "launch odd output" calls get_app_container

# e. terminate and uninstall check first and send nothing for a missing app.
for verb in terminate uninstall; do
  call "$verb" dev.karagoz.nope --device A1
  refuses APP_NOT_FOUND "$verb not installed" "app 'dev.karagoz.nope' is not installed on A1"
  lacks_call "$verb not installed" calls "$verb "
done

# f. An installed app that is not running terminates as done, as on Android.
call terminate dev.karagoz.idle --device A1
succeeds "terminate idle" '{"device":"A1","package":"dev.karagoz.idle"}'
call terminate dev.karagoz.probe --device A1
succeeds "terminate" '{"device":"A1","package":"dev.karagoz.probe"}'
has_call terminate calls "terminate A1 dev.karagoz.probe"

# g. A system app is refused before simctl's uninstall: a success would remove it until the simulator is erased.
call uninstall com.apple.Preferences --device A1
refuses UNINSTALL_FAILED "system app" "'com.apple.Preferences' is a system app; a simulator does not remove system apps"
reason_is "system app" SYSTEM_APP
lacks_call "system app" calls "uninstall "

# h. simctl's refusals: the description lines, uncut, with <domain>:<code> as the reason; no header is SIMCTL_FAILED.
call install "$fake/Device.app" --device A1
want=$(sed -n '2,4p' "$fake/device.err" | paste -sd ' ' -)
[ "${#want}" -gt 300 ] || fail "the device-build message is only ${#want} characters"
refuses INSTALL_FAILED "device build" "$want"
reason_is "device build" IXUserPresentableErrorDomain:4
call uninstall dev.karagoz.stuck --device A1
refuses UNINSTALL_FAILED "uninstall refused" "Simulator device failed to uninstall dev.karagoz.stuck. The operation could not be completed."
reason_is "uninstall refused" IXErrorDomain:7
call install "$fake/Plain.app" --device A1
refuses SIMCTL_FAILED "install without a header" "simctl broke"

# i. Target resolution (K21): not booted, unknown, no simctl, two simulators, nothing at all.
call launch x --device A2
refuses DEVICE_NOT_READY "booting simulator"
call launch x --device nope
refuses DEVICE_NOT_FOUND "unknown device"
dev="$tmp/nosim"
call launch x --device A1
refuses DEVICE_NOT_FOUND "no simctl"
dev="$tmp/dev"
call launch x
refuses DEVICE_AMBIGUOUS "two simulators"
sims ''
call launch x
refuses NO_DEVICE "no device"
sims "$a1,$a2"

# j. A hung simctl is killed after 30 s, 31 s for an install of a .app; each verb names a debugger-stopped app first.
hung() { # <label> <request> <seconds> <karagoz arguments>
  label=$1 request=$2 seconds=$3
  shift 3
  start=$(date +%s)
  call "$@"
  took=$(($(date +%s) - start))
  refuses SIMCTL_TIMEOUT "$label" "simctl did not answer within ${seconds}s. If a debugger such as Xcode has the app stopped (a breakpoint or a pause), the simulator holds the $request until the app continues or the debug session ends, then finishes it; until then other calls to this simulator can wait too. Otherwise the simulator service may still be starting (the first call after login can take several seconds) or be stuck."
  [ "$took" -ge 29 ] && [ "$took" -le 41 ] || fail "$label took ${took}s"
  sleep 1
  ! pgrep -f 'sleep 97\.51' >/dev/null || fail "$label: the hung simctl outlived karagoz"
}
hung "hung terminate" stop 30 terminate dev.karagoz.hang --device A1
t1=$took
hung "hung install" install 31 install "$fake/Hang.app" --device A1
t2=$took
hung "hung uninstall" removal 30 uninstall dev.karagoz.hang --device A1
fakes="fakes: arguments, other platform, launch, not installed, idle, system app, refusals, targets, hung terminate/install/uninstall (${t1}/${t2}/${took}s)"

# Real simulator: Probe as .app and .ipa, each effect read back, then everything as recorded.
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
mkdir -p "$tmp/bad" "$tmp/ipa/Payload"
cp -R "$tmp/Probe.app" "$tmp/bad/Probe.app"
rm "$tmp/bad/Probe.app/Info.plist"
cp -R "$tmp/Probe.app" "$tmp/ipa/Payload/"
# zip, not ditto: ditto adds ._ AppleDouble entries.
(cd "$tmp/ipa" && zip -qr "$tmp/Probe.ipa" Payload)
r() { out=$(real "$@" --device "$booted") && st=0 || st=$?; }
started=1

r install "$tmp/Probe.app"
succeeds "real install" "{\"device\":\"$booted\",\"path\":\"$tmp/Probe.app\"}"
"$framework" get_app_container "$booted" dev.karagoz.probe >/dev/null 2>&1 || fail "real install: no app container"
r install "$tmp/Probe.app"
succeeds "real install again" "{\"device\":\"$booted\",\"path\":\"$tmp/Probe.app\"}"
r install "$tmp/Probe.ipa"
succeeds "real install .ipa" "{\"device\":\"$booted\",\"path\":\"$tmp/Probe.ipa\"}"

# launch returns at spawn; the app reaches the front within a second or so.
for label in "real launch" "real launch again"; do
  r launch dev.karagoz.probe
  succeeds "$label" "{\"device\":\"$booted\",\"package\":\"dev.karagoz.probe\",\"activity\":null}"
  i=0
  until [ "$(tree | q root)" = Probe ]; do
    i=$((i + 1))
    [ "$i" -lt 10 ] || fail "$label: Probe is not in front"
    sleep 0.5
  done
done

for label in "real terminate" "real terminate again"; do
  r terminate dev.karagoz.probe
  succeeds "$label" "{\"device\":\"$booted\",\"package\":\"dev.karagoz.probe\"}"
  i=0
  # A failed ui-tree read leaves q with no root; retry it instead of reading it as "not Probe".
  while ! root=$(tree | q root) || [ "$root" = Probe ]; do
    i=$((i + 1))
    [ "$i" -lt 10 ] || fail "$label: Probe is still in front or ui-tree fails"
    sleep 0.5
  done
done

r install "$tmp/bad/Probe.app"
refuses INSTALL_FAILED "real install without Info.plist"
reason_is "real install without Info.plist" IXErrorDomain:13

r uninstall dev.karagoz.probe
succeeds "real uninstall" "{\"device\":\"$booted\",\"package\":\"dev.karagoz.probe\"}"
! "$framework" get_app_container "$booted" dev.karagoz.probe >/dev/null 2>&1 || fail "real uninstall: the app container is still there"
for verb in uninstall launch terminate; do
  r "$verb" dev.karagoz.probe
  refuses APP_NOT_FOUND "real $verb after uninstall" "app 'dev.karagoz.probe' is not installed on $booted"
done

echo "ok: real $booted: install .app and .ipa, launch, terminate, refused bundle, uninstall, $fakes"
