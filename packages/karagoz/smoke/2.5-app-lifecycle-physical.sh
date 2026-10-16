#!/bin/sh
# Step 2.5: install, launch, terminate and uninstall on a physical phone, with the smoke's own test app: each verb
# prints its JSON line, an upgrade installs, a downgrade and a file that is not an APK are refused with Android's code,
# and a package with no launcher activity or none installed is refused with karagoz's code.
# Precondition: the build only; a phone is optional, and no emulator is needed. If a phone is used: state device, and
# a JDK and Android SDK build-tools with one platform on this machine (as smoke 1.5).
# What reaches a phone: reads (`adb devices`, the getprop of `devices`, `pm path`, `pidof`, and the `cmd package
# query-activities` of `launch`); `adb install -r --no-incremental` of dev.karagoz.smoke (two 8.5 KB versions built
# on this run, and a one-byte file Android refuses); `am start` and `am force-stop` of dev.karagoz.smoke; `cmd package
# uninstall dev.karagoz.smoke`; on exit, `adb uninstall dev.karagoz.smoke` and `input keyevent 3` (HOME). Play Protect
# may scan the test app and, with "Improve harmful app detection" on, send it to Google; it holds a manifest only. It
# starts and stops no other app, writes no setting, and leaves the phone on its home screen. After an install that
# times out it sends nothing more: the prompt on the screen is the owner's. The adb server on the default port is never
# stopped or restarted.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

tmp=$(mktemp -d)
serial=
held=
# set +e: errexit stays on inside the trap. A held install leaves the phone alone.
trap 'set +e; rm -rf "$tmp"; if [ -n "$serial" ] && [ -z "$held" ]; then adb -s "$serial" uninstall dev.karagoz.smoke; adb -s "$serial" shell input keyevent 3; fi >/dev/null 2>&1' EXIT
# Prints one field of a success result. Fails unless stdout is one JSON line.
field() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  const value = JSON.parse(out)[process.argv[1]];
  if (value === undefined) process.exit(1);
  console.log(value);
' "$1"; }
# Prints .error.code and, when set, .error.reason of a one-line envelope; not-one-line or not-json otherwise. Never
# the message: it can quote a path.
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { const e = JSON.parse(out).error; console.log(out.includes("\n") ? "not-one-line" : e.reason ? `${e.code} ${e.reason}` : e.code) } catch { console.log("not-json") }
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
# Sets held when an install timed out: the phone may be showing a prompt, and the trap must leave it alone.
held_if_timeout() {
  [ "$1" != install ] || [ "$(printf '%s' "$out" | code_of)" != ADB_TIMEOUT ] || held=1
}
# Runs karagoz on the phone with the arguments; sets out. A failure prints the verb and the error code only.
run() {
  out=$(node dist/cli.js "$@" --device "$serial" 2>/dev/null) || { held_if_timeout "$1"; fail "$1 exited non-zero: $(printf '%s' "$out" | code_of)"; }
}
# Fails unless karagoz with the arguments after $1 exits non-zero with a one-line envelope whose code (and reason)
# is $1; sets out.
refuses() {
  want=$1
  shift
  if out=$(node dist/cli.js "$@" --device "$serial" 2>/dev/null); then fail "$1 exited 0; expected $want"; fi
  [ "$(printf '%s' "$out" | code_of)" = "$want" ] || { held_if_timeout "$1"; fail "$1: expected $want, got $(printf '%s' "$out" | code_of)"; }
}
# True when pm path lists the package $1.
installed() {
  path=$(adb -s "$serial" shell pm path "$1" 2>/dev/null) || true
  case $path in package:*) ;; *) false ;; esac
}
# True when the smoke's app has a process. pidof exits 1 when nothing matches, so its output decides.
running() {
  pid=$(adb -s "$serial" shell pidof dev.karagoz.smoke 2>/dev/null) || true
  [ -n "$pid" ]
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

# 3. The APKs, as smoke 1.5 builds them, before serial is set: a failed build leaves the phone alone. 4. A leftover
# from an interrupted run is the smoke's own app.
sh smoke/fixtures/app-lifecycle/build.sh "$tmp"
serial=$phone
if installed dev.karagoz.smoke; then adb -s "$serial" uninstall dev.karagoz.smoke >/dev/null 2>&1 || true; fi

# 5. install. A timeout means the phone may be holding the install on a prompt (K28 2.5 note).
if ! out=$(node dist/cli.js install "$tmp/smoke.apk" --device "$serial" 2>/dev/null); then
  case $(printf '%s' "$out" | code_of) in
    ADB_TIMEOUT)
      held=1
      fail "install timed out; the phone may show an install prompt: answer it on the phone, then run adb uninstall dev.karagoz.smoke" ;;
    *) fail "install exited non-zero: $(printf '%s' "$out" | code_of)" ;;
  esac
fi
[ "$out" = "{\"device\":\"$serial\",\"path\":\"$tmp/smoke.apk\"}" ] || fail "install printed another result"
installed dev.karagoz.smoke || fail "pm path finds no dev.karagoz.smoke after install"

# 6. launch. A slow phone may need a few seconds before the process shows.
run launch dev.karagoz.smoke
[ "$(printf '%s' "$out" | field activity)" = dev.karagoz.smoke/android.app.Activity ] || fail "launch reported another activity"
i=0
until running; do
  i=$((i + 1))
  [ "$i" -lt 10 ] || fail "no dev.karagoz.smoke process within 10 s after launch"
  sleep 1
done

# 7. terminate, twice: a package that is installed but not running succeeds too.
run terminate dev.karagoz.smoke
[ "$out" = "{\"device\":\"$serial\",\"package\":\"dev.karagoz.smoke\"}" ] || fail "terminate printed another result"
if running; then fail "dev.karagoz.smoke still runs after terminate"; fi
run terminate dev.karagoz.smoke

# 8. An upgrade installs; the old version on top of it is refused with Android's code.
run install "$tmp/smoke-v2.apk"
refuses "INSTALL_FAILED INSTALL_FAILED_VERSION_DOWNGRADE" install "$tmp/smoke.apk"

# 9. A file that is not an APK.
refuses "INSTALL_FAILED INSTALL_PARSE_FAILED_NOT_APK" install "$tmp/bad.apk"

# 10. An installed package with no launcher activity; nothing is started.
if installed com.android.shell; then
  refuses APP_NOT_LAUNCHABLE launch com.android.shell
  launchable="not launchable"
else
  echo "note: not-launchable step skipped"
  launchable="not launchable skipped"
fi

# 11. uninstall, then every verb that takes a package finds it gone.
run uninstall dev.karagoz.smoke
[ "$out" = "{\"device\":\"$serial\",\"package\":\"dev.karagoz.smoke\"}" ] || fail "uninstall printed another result"
if installed dev.karagoz.smoke; then fail "pm path still finds dev.karagoz.smoke after uninstall"; fi
for verb in launch terminate uninstall; do
  refuses APP_NOT_FOUND "$verb" dev.karagoz.smoke
done

echo "ok: physical install, launch, terminate, upgrade, downgrade refused, not an apk, $launchable, uninstall, not found 3"
