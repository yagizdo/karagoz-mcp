#!/bin/sh
# Step 4.5: install, launch, open-url, terminate and uninstall reach a paired iPhone through devicectl in K28's shapes
# (K43). Fakes prove each refusal read from devicectl's JSON error chain (INSTALL_FAILED and UNINSTALL_FAILED with the
# deepest <domain>:<code>, the re-sign sentence on a code-signing refusal), APP_NOT_FOUND for each verb, a locked
# iPhone, an unmapped launch failure, terminate by the app's bundle path (every process under it, a gone pid as done,
# nothing running as done), SYSTEM_APP with no removal sent, the wrong-platform file, a slow first call, a hung install
# and the held launch of a stopped app.
# Precondition: macOS. Fake adb, simctl and devicectl come through ANDROID_HOME and DEVELOPER_DIR under env -i. The real
# step installs Probe (built for the phone, signed by fixtures/input-ios/sign.sh) on a paired iPhone through karagoz,
# launches and terminates it and Settings, uninstalls Probe and reads each effect back, else it prints SKIP; the EXIT
# trap removes Probe. Nothing but dev.karagoz.probe reaches the phone's uninstall. Before that, open-url opens Settings
# with and without --app and terminates it. Fakes also prove open-url's two devicectl calls and their failures.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iPhones need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; pkill -f "sleep 97\\.45"; [ -n "$probe_phone" ] && unprobe; rm -rf "$tmp"' EXIT
probe_phone=
fail() { echo "FAIL: $*"; exit 1; }
code_of() { "$node_bin" -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }
reason_of() { "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.reason ?? "none")'; }

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them. Files under $fake steer devicectl.
fake="$tmp/fake"
dev="$tmp/dev"
mkdir -p "$tmp/sdk/platform-tools" "$dev/usr/bin" "$tmp/home" "$fake"
printf '#!/bin/sh\ncase "$*" in devices) printf "List of devices attached\\n\\n" ;; *) exit 1 ;; esac\n' > "$tmp/sdk/platform-tools/adb"
printf '#!/bin/sh\necho %s\n' "'{\"devices\":{}}'" > "$dev/usr/bin/simctl"
cat > "$dev/usr/bin/devicectl" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/calls"
case "\$*" in
  "list devices --json-output - -q") /bin/cat "$fake/list.json" ;;
  "device install app --device P1 "*"/Hang.app --json-output - -q") exec /bin/sleep 97.45 ;;
  "device install app --device P1 "*".app --json-output - -q" | "device install app --device P1 "*".ipa --json-output - -q")
    f=\${6##*/}
    [ -e "$fake/install-\$f" ] || { /bin/cat "$fake/installed"; exit 0; }
    /bin/cat "$fake/install-\$f"; exit 1 ;;
  "device process launch --device P1 --payload-url "*" --json-output - -q")
    case \$8 in dev.karagoz.nope) /bin/cat "$fake/launch-dev.karagoz.nope"; exit 1 ;; *) /bin/cat "$fake/launched" ;; esac ;;
  "device process openURL --device P1 "*" --json-output - -q")
    case \$6 in
      karagoz-x://locked) /bin/cat "$fake/locked.err" >&2; exit 1 ;;
      karagoz-x://none) /bin/cat "$fake/open-none"; exit 1 ;;
      *) echo '{"result":{}}' ;;
    esac ;;
  "device process launch --device P1 "*" --json-output - -q")
    [ -e "$fake/slow" ] && /bin/sleep 4
    case \$6 in
      dev.karagoz.held) exec /bin/sleep 97.45 ;;
      dev.karagoz.locked) /bin/cat "$fake/locked.err" >&2; exit 1 ;;
      dev.karagoz.odd) echo '{"result":{"process":{}}}' ;;
      dev.karagoz.nope | dev.karagoz.weird) /bin/cat "$fake/launch-\$6"; exit 1 ;;
      *) /bin/cat "$fake/launched" ;;
    esac ;;
  "device info apps --device P1 --bundle-id "*" --include-all-apps --json-output - -q")
    if [ -e "$fake/app-\$7" ]; then /bin/cat "$fake/app-\$7"; else echo '{"result":{"apps":[]}}'; fi ;;
  "device info processes --device P1 --json-output - -q") /bin/cat "$fake/processes" ;;
  "device process terminate --device P1 --pid "*" --kill --json-output - -q")
    case \$7 in 7001 | 7002) /bin/cat "$fake/kill-\$7"; exit 1 ;; *) echo '{"result":{}}' ;; esac ;;
  "device uninstall app --device P1 dev.karagoz.refused --json-output - -q") /bin/cat "$fake/uninstall-refused"; exit 1 ;;
  "device uninstall app --device P1 "*" --json-output - -q") echo '{"result":{"uninstalledApplications":[]}}' ;;
  *) echo "fake devicectl: unexpected arguments: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$dev/usr/bin/simctl" "$dev/usr/bin/devicectl"
echo '{"result":{"devices":[{"visibilityClass":"default","properties":{"hardware":{"udid":"P1","reality":"physical","platform":"iOS","marketingName":"iPhone 14 Pro Max"},"connection":{"pairingState":"paired","state":"connected","transportType":"wired"}}}]}}' > "$fake/list.json"

# chain <file> <domain> <code> <description> <failure reason> [...]: devicectl's failed JSON, outermost error first.
chain() { f=$1; shift; "$node_bin" -e '
  const a = process.argv.slice(1);
  let error;
  for (let i = a.length - 4; i >= 0; i -= 4) {
    const info = {};
    if (a[i + 2]) info.NSLocalizedDescription = { string: a[i + 2] };
    if (a[i + 3]) info.NSLocalizedFailureReason = { string: a[i + 3] };
    if (error) info.NSUnderlyingError = { error };
    error = { domain: a[i], code: +a[i + 1], userInfo: info };
  }
  console.log(JSON.stringify({ error, info: { outcome: "failed" } }));
' "$@" > "$fake/$f"; }
core=com.apple.dt.CoreDeviceError
refused="Failed to install the app on the device."
verify() { # <file> <bundle> <MIS code and text>
  chain "$1" $core 3002 "$refused" '' IXUserPresentableErrorDomain 14 "Unable to Install “Probe”" \
    "This app cannot be installed because its integrity could not be verified." \
    MIInstallerErrorDomain 13 "Failed to verify code signature of /var/installd/x/extracted/$2 : $3" ''
}
verify install-Sim.app Sim.app "0xe8008014 (The executable contains an invalid signature.)"
verify install-Unsigned.app Unsigned.app "0xe800801c (No code signature found.)"
verify install-Profile.app Profile.app "0xe8008015 (A valid provisioning profile for this executable was not found.)"
chain install-NoPlist.app $core 3002 "$refused" '' $core 3000 "The item at NoPlist.app is not a valid bundle." \
  "Failed to get the identifier for the app to be installed."
echo '{"result":{"installedApplications":[{"bundleID":"dev.karagoz.probe"}]},"info":{"outcome":"success"}}' > "$fake/installed"
echo '{"result":{"process":{"executable":"file:///private/var/containers/Bundle/Application/AAAA/Probe.app/Probe","processIdentifier":6590}}}' > "$fake/launched"
chain launch-dev.karagoz.nope $core 10002 "The application failed to launch." \
  "The requested application dev.karagoz.nope is not installed." NSOSStatusErrorDomain -10814 '' ''
chain launch-dev.karagoz.weird $core 10002 "The application failed to launch." '' \
  FBSOpenApplicationServiceErrorDomain 1 'The request to open "dev.karagoz.weird" failed.' \
  "The request was denied by service delegate (SBMainWorkspace) for reason: Security." \
  FBSOpenApplicationErrorDomain 3 '' \
  "The application could not be launched because its profile has not been explicitly trusted by the user."
printf '%s\n' 'ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))' \
  '       NSLocalizedFailureReason = Unable to launch dev.karagoz.locked because the device was not, or could not be, unlocked.' \
  > "$fake/locked.err"
chain open-none $core 10006 "The URL could not be opened." '' $core 10006 '' "No app handles karagoz-x://none."
gone="Failed to send signal 9 to process."
chain kill-7001 $core 10014 "$gone" "No such process; the process may have already terminated." NSPOSIXErrorDomain 3 '' ''
chain kill-7002 $core 10014 "$gone" "Operation not permitted." NSPOSIXErrorDomain 1 '' ''
chain uninstall-refused $core 3003 "Failed to uninstall the app." '' MIInstallerErrorDomain 9 "Could not remove the app." ''
app() { # <id> <url>
  echo "{\"result\":{\"apps\":[{\"bundleIdentifier\":\"$1\",\"url\":\"$2\",\"removable\":true}]}}" > "$fake/app-$1"
}
c=file:///private/var/containers/Bundle/Application
for a in probe:AAAA/Probe multi:BBBB/Multi gone:CCCC/Gone stuck:DDDD/Stuck idle:EEEE/Idle refused:FFFF/Refused; do
  app "dev.karagoz.${a%%:*}" "$c/${a#*:}.app/"
done
app com.apple.Preferences file:///Applications/Preferences.app/
p() { echo "{\"executable\":\"$1\",\"processIdentifier\":$2}"; }
echo "{\"result\":{\"runningProcesses\":[$(p "$c/AAAA/Probe.app/Probe" 6590),$(p "$c/BBBB/Multi.app/Multi" 7101),$(p "$c/BBBB/Multi.app/PlugIns/W.appex/W" 7102),$(p "$c/BBBB/Multi.appx/x" 7103),$(p "$c/CCCC/Gone.app/Gone" 7001),$(p "$c/DDDD/Stuck.app/Stuck" 7002),$(p file:///Applications/Preferences.app/Preferences 5695)]}}" > "$fake/processes"
for f in Probe.app Sim.app Unsigned.app Profile.app NoPlist.app Hang.app; do mkdir "$fake/$f"; done
: > "$fake/Probe.ipa"
: > "$fake/x.apk"

# karagoz with only the fakes. Sets $out and $st, and clears the call log.
call() {
  rm -f "$fake/calls"
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
log() { if [ -e "$fake/calls" ]; then cat "$fake/calls"; else echo none; fi; }
calls_of() { grep -c "^$1" "$fake/calls" 2>/dev/null || true; }
lacks_call() { # <label> <prefix>
  [ "$(calls_of "$2")" = 0 ] || fail "$1: '$2' was sent: $(log | tr '\n' ';')"
}

# a. install: .app and .ipa as they are; each refusal with the phone's deepest cause; the wrong-platform file.
call install "$fake/Probe.app" --device P1
succeeds "install .app" "{\"device\":\"P1\",\"path\":\"$fake/Probe.app\"}"
call install "$fake/Probe.ipa" --device P1
succeeds "install .ipa" "{\"device\":\"P1\",\"path\":\"$fake/Probe.ipa\"}"
resign=" karagoz installs an app as it was built and does not re-sign it: build it for this iPhone (Xcode or Flutter sign it with a profile that includes this iPhone)."
for c2 in "Sim.app:0xe8008014 (The executable contains an invalid signature.)" \
  "Unsigned.app:0xe800801c (No code signature found.)" \
  "Profile.app:0xe8008015 (A valid provisioning profile for this executable was not found.)"; do
  f=${c2%%:*}
  call install "$fake/$f" --device P1
  refuses INSTALL_FAILED "install $f" "$refused Failed to verify code signature of /var/installd/x/extracted/$f : ${c2#*:}$resign"
  reason_is "install $f" MIInstallerErrorDomain:13
done
call install "$fake/NoPlist.app" --device P1
refuses INSTALL_FAILED "install NoPlist.app" "$refused Failed to get the identifier for the app to be installed."
reason_is "install NoPlist.app" com.apple.dt.CoreDeviceError:3000
call install "$fake/missing.app" --device P1
refuses INVALID_ARGS "install missing.app" "no file at '$fake/missing.app'"
call install "$fake/x.apk" --device P1
refuses INVALID_ARGS "install x.apk" "'$fake/x.apk' is an Android app; P1 is an iPhone"
lacks_call "install x.apk" "device install"

# b. launch: no check before it; the not-installed, locked and unmapped refusals from its own failure.
call launch dev.karagoz.probe --device P1
succeeds "launch" '{"device":"P1","package":"dev.karagoz.probe","activity":null}'
[ "$(log)" = "list devices --json-output - -q
device process launch --device P1 dev.karagoz.probe --json-output - -q" ] || fail "launch calls: $(log | tr '\n' ';')"
call launch dev.karagoz.nope --device P1
refuses APP_NOT_FOUND "launch not installed" "app 'dev.karagoz.nope' is not installed on P1"
call launch dev.karagoz.locked --device P1
refuses DEVICE_NOT_READY "launch locked" "device P1 is not ready: it is locked. Unlock the iPhone and try again."
call launch dev.karagoz.weird --device P1
refuses DEVICECTL_FAILED "launch untrusted" "The application failed to launch. The application could not be launched because its profile has not been explicitly trusted by the user."
reason_is "launch untrusted" none
call launch dev.karagoz.odd --device P1
refuses DEVICECTL_FAILED "launch without a pid" 'unexpected devicectl output: {"result":{"process":{}}}'
: > "$fake/slow"
start=$(date +%s)
call launch dev.karagoz.probe --device P1
cold=$(($(date +%s) - start))
rm "$fake/slow"
succeeds "launch on a cold tunnel" '{"device":"P1","package":"dev.karagoz.probe","activity":null}'
[ "$cold" -ge 4 ] || fail "the slow launch took ${cold}s"

# c. terminate: every process under the app's bundle with --kill, none for a look-alike path; gone and idle are done.
call terminate dev.karagoz.multi --device P1
succeeds "terminate two processes" '{"device":"P1","package":"dev.karagoz.multi"}'
[ "$(calls_of 'device process terminate')" = 2 ] && grep -q -- '--pid 7101 --kill' "$fake/calls" &&
  grep -q -- '--pid 7102 --kill' "$fake/calls" || fail "terminate multi: $(log | tr '\n' ';')"
call terminate dev.karagoz.probe --device P1
succeeds "terminate" '{"device":"P1","package":"dev.karagoz.probe"}'
call terminate dev.karagoz.gone --device P1
succeeds "terminate a gone process" '{"device":"P1","package":"dev.karagoz.gone"}'
call terminate dev.karagoz.idle --device P1
succeeds "terminate not running" '{"device":"P1","package":"dev.karagoz.idle"}'
lacks_call "terminate not running" "device process terminate"
call terminate dev.karagoz.stuck --device P1
refuses DEVICECTL_FAILED "terminate refused" "$gone Operation not permitted."
call terminate com.apple.Preferences --device P1
succeeds "terminate Settings" '{"device":"P1","package":"com.apple.Preferences"}'
call terminate dev.karagoz.nope --device P1
refuses APP_NOT_FOUND "terminate not installed" "app 'dev.karagoz.nope' is not installed on P1"
lacks_call "terminate not installed" "device process terminate"

# d. uninstall: looked up first; a system app is refused before any removal.
call uninstall dev.karagoz.probe --device P1
succeeds "uninstall" '{"device":"P1","package":"dev.karagoz.probe"}'
grep -qxF "device uninstall app --device P1 dev.karagoz.probe --json-output - -q" "$fake/calls" || fail "uninstall calls: $(log | tr '\n' ';')"
call uninstall com.apple.Preferences --device P1
refuses UNINSTALL_FAILED "system app" "'com.apple.Preferences' is a system app; an iPhone does not remove system apps"
reason_is "system app" SYSTEM_APP
lacks_call "system app" "device uninstall"
call uninstall dev.karagoz.nope --device P1
refuses APP_NOT_FOUND "uninstall not installed" "app 'dev.karagoz.nope' is not installed on P1"
lacks_call "uninstall not installed" "device uninstall"
call uninstall dev.karagoz.refused --device P1
refuses UNINSTALL_FAILED "uninstall refused" "Failed to uninstall the app. Could not remove the app."
reason_is "uninstall refused" MIInstallerErrorDomain:9

# d2. open-url: openURL without --app, launch --payload-url with it; the URL reaches devicectl as one argument.
url='karagoz-probe://open/p?a=1&b=2;c#frag'
call open-url "$url" --device P1
succeeds "open-url" "{\"device\":\"P1\",\"url\":\"$url\"}"
[ "$(log)" = "list devices --json-output - -q
device process openURL --device P1 $url --json-output - -q" ] || fail "open-url calls: $(log | tr '\n' ';')"
call open-url "$url" --app dev.karagoz.probe --device P1
succeeds "open-url --app" "{\"device\":\"P1\",\"url\":\"$url\",\"app\":\"dev.karagoz.probe\"}"
[ "$(log)" = "list devices --json-output - -q
device process launch --device P1 --payload-url $url dev.karagoz.probe --json-output - -q" ] ||
  fail "open-url --app calls: $(log | tr '\n' ';')"
call open-url "$url" --app dev.karagoz.nope --device P1
refuses APP_NOT_FOUND "open-url --app not installed" "app 'dev.karagoz.nope' is not installed on P1"
call open-url karagoz-x://locked --device P1
refuses DEVICE_NOT_READY "open-url locked" "device P1 is not ready: it is locked. Unlock the iPhone and try again."
call open-url karagoz-x://none --device P1
refuses DEVICECTL_FAILED "open-url refused" "The URL could not be opened. No app handles karagoz-x://none."

# e. A hung devicectl is killed: 31 s for an install of a .app; a launch held by a stopped app says so after 30 s.
hung() { # <label> <seconds> <message> <karagoz arguments>
  label=$1 seconds=$2 message=$3
  shift 3
  start=$(date +%s)
  call "$@"
  took=$(($(date +%s) - start))
  refuses DEVICECTL_TIMEOUT "$label" "$message"
  [ "$took" -ge $((seconds - 1)) ] && [ "$took" -le $((seconds + 10)) ] || fail "$label took ${took}s"
  sleep 1
  ! pgrep -f 'sleep 97\.45' > /dev/null || fail "$label: the hung devicectl outlived karagoz"
}
hung "hung install" 31 "devicectl did not answer within 31s. CoreDevice's service may still be starting or be stuck." \
  install "$fake/Hang.app" --device P1
t1=$took
hung "held launch" 30 "devicectl did not answer within 30s. If a debugger has the app stopped (a breakpoint, a pause or a start that waits for one), the iPhone holds the launch until the app continues. Otherwise CoreDevice's service may still be starting or be stuck." \
  launch dev.karagoz.held --device P1

fakes="fakes: install, refusals, wrong platform, launch, not installed, locked, unmapped, cold (${cold}s), terminate by path, gone, idle, uninstall, system app, open-url, hung install/launch (${t1}/${took}s)"

# f. A real paired iPhone, runner or not. Real tools and HOME; only codes and Probe's id are printed.
real() { env -i HOME="$HOME" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
installed() { /usr/bin/xcrun devicectl device info apps --device "$phone" --bundle-id dev.karagoz.probe --json-output - -q 2> /dev/null |
  /usr/bin/grep -q '"bundleIdentifier"'; }
unprobe() {
  /usr/bin/xcrun devicectl device uninstall app --device "$probe_phone" dev.karagoz.probe -q > /dev/null 2>&1
  ! installed || echo "FAIL: Probe is still on the iPhone"
}
# pids <bundle path part>: the running processes whose executable sits in it, space-separated.
pids() { /usr/bin/xcrun devicectl device info processes --device "$phone" --json-output - -q 2> /dev/null | "$node_bin" -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8")).result.runningProcesses;
  console.log(r.filter((p) => p.executable.includes(process.argv[1])).map((p) => p.processIdentifier).join(" "));
' "$1"; }
phone=$(real devices | "$node_bin" -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  console.log(r.devices.find((d) => d.kind === "physical" && d.state === "paired")?.id ?? "");
')
# open-url on the phone opens Settings only: a system app that keeps no history of the URL, installed on every iPhone.
# A locked phone skips it. Terminating Settings leaves the home screen in front.
open_ok=
if [ -n "$phone" ]; then
  mask() { printf '%s' "$1" | sed "s/$phone/XXXXXXXX-XXXXXXXXXXXXXXXX/g"; }
  is_out() { [ "$1" = "$2" ] || fail "$3: got $(mask "$1"), expected $(mask "$2")"; }
  if out=$(real open-url App-prefs: --device "$phone"); then
    is_out "$out" "{\"device\":\"$phone\",\"url\":\"App-prefs:\"}" "real open-url"
    [ -n "$(pids /Preferences.app/Preferences)" ] || fail "real open-url: no Settings process"
    real terminate com.apple.Preferences --device "$phone" > /dev/null || fail "real open-url: terminate Settings failed"
    is_out "$(real open-url App-prefs: --app com.apple.Preferences --device "$phone")" \
      "{\"device\":\"$phone\",\"url\":\"App-prefs:\",\"app\":\"com.apple.Preferences\"}" "real open-url --app"
    [ -n "$(pids /Preferences.app/Preferences)" ] || fail "real open-url --app: no Settings process"
    real terminate com.apple.Preferences --device "$phone" > /dev/null || fail "real open-url --app: terminate Settings failed"
    open_ok="real open-url: Settings, Settings by --app, "
  elif [ "$(printf '%s' "$out" | code_of)" = DEVICE_NOT_READY ]; then
    echo "SKIP: the iPhone is not ready for open-url (locked?)"
  else
    fail "real open-url: $(mask "$out")"
  fi
fi
signed=
if [ -n "$phone" ]; then
  mkdir "$tmp/probe"
  sh smoke/fixtures/input-ios/build.sh "$tmp/probe" iphoneos > /dev/null || fail "building Probe for the iPhone failed"
  app=$tmp/probe/Probe.app
  sh smoke/fixtures/input-ios/sign.sh "$app" "$phone" && signed=1 || [ $? = 2 ] || fail "signing Probe failed"
fi
if [ -z "$phone" ]; then
  echo "SKIP: no paired iPhone"
  real_ok="real skipped"
elif [ -z "$signed" ]; then
  echo "SKIP: no provisioning profile here covers dev.karagoz.probe on the iPhone with an identity in the keychain"
  real_ok="real skipped (no profile)"
else
  probe_phone=$phone
  is_out "$(real install "$app" --device "$phone")" "{\"device\":\"$phone\",\"path\":\"$app\"}" "real install"
  installed || fail "real install: Probe is not listed"
  launched="{\"device\":\"$phone\",\"package\":\"dev.karagoz.probe\",\"activity\":null}"
  is_out "$(real launch dev.karagoz.probe --device "$phone")" "$launched" "real launch"
  first=$(pids /Probe.app/Probe)
  [ -n "$first" ] || fail "real launch: no Probe process"
  is_out "$(real launch dev.karagoz.probe --device "$phone")" "$launched" "real launch again"
  is_out "$(pids /Probe.app/Probe)" "$first" "real launch again: the pid"
  stopped="{\"device\":\"$phone\",\"package\":\"dev.karagoz.probe\"}"
  is_out "$(real terminate dev.karagoz.probe --device "$phone")" "$stopped" "real terminate"
  is_out "$(pids /Probe.app/Probe)" "" "real terminate: Probe processes left"
  is_out "$(real terminate dev.karagoz.probe --device "$phone")" "$stopped" "real terminate, not running"
  is_out "$(real launch com.apple.Preferences --device "$phone")" \
    "{\"device\":\"$phone\",\"package\":\"com.apple.Preferences\",\"activity\":null}" "real launch Settings"
  [ -n "$(pids /Preferences.app/Preferences)" ] || fail "real launch Settings: no process"
  is_out "$(real terminate com.apple.Preferences --device "$phone")" \
    "{\"device\":\"$phone\",\"package\":\"com.apple.Preferences\"}" "real terminate Settings"
  is_out "$(pids /Preferences.app/Preferences)" "" "real terminate Settings: processes left"
  is_out "$(real uninstall dev.karagoz.probe --device "$phone")" "$stopped" "real uninstall"
  ! installed || fail "real uninstall: Probe is still listed"
  if out=$(real uninstall dev.karagoz.probe --device "$phone"); then fail "real uninstall again exited 0: $(mask "$out")"; fi
  is_out "$(printf '%s' "$out" | code_of)" APP_NOT_FOUND "real uninstall again"
  real_ok="real Probe: install, launch, same pid, terminate, not running, Settings, uninstall, not installed"
fi

echo "ok: $open_ok$real_ok, $fakes"
