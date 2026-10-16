#!/bin/sh
# Step 2.6: `logs` on a physical phone: the default read returns whole records, --package finds com.android.shell's
# uid, and a line written through adb comes back with a --since on the phone's clock and not with the next --since in
# the chain.
# Precondition: the build only; a phone is optional, and no emulator is needed.
# What reaches a phone: reads (`adb devices`, the getprop of `devices`, `date +%s`, and karagoz `logs`: `logcat -d -B`
# with and without -t, `pm list packages -U --user 0 com.android.shell`); one `log -t KaragozSmoke -p i <token>` line
# in the main log, written as the shell user. It installs, starts and stops nothing, sends no input and writes no
# setting; the line ages out of the log like any other. The adb server on the default port is never stopped or
# restarted.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

serial=
# Prints one field of a success result. Fails unless stdout is one JSON line with that field.
field() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  const value = JSON.parse(out)[process.argv[1]];
  if (value === undefined) process.exit(1);
  console.log(value);
' "$1"; }
# Prints .error.code, or not-json, never the message. The envelope must be exactly one line (K5).
code_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
# Prints FAIL with the serial replaced by <phone>, then exits 1.
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
# Sets $out to karagoz's stdout for the phone, or fails with the error code.
run() { out=$(node dist/cli.js "$@" --device "$serial" 2>/dev/null) || fail "$1 exited non-zero: $(printf '%s' "$out" | code_of)"; }
# Prints "<records carrying $1, or -1 if one is not an I line tagged KaragozSmoke> <largest time>" of $out.
marked() { printf '%s' "$out" | node -e '
  const { records } = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const mine = records.filter((r) => r.message === process.argv[1]);
  const ok = mine.every((r) => r.tag === "KaragozSmoke" && r.level === "I");
  console.log(`${ok ? mine.length : -1} ${Math.max(0, ...records.map((r) => r.time))}`);
' "$1"; }

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

# 3. The default read: 1 to 30 whole records.
run logs
n=$(printf '%s' "$out" | node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  const { records, omitted } = JSON.parse(out);
  const whole = (r) => typeof r.time === "number" && Number.isInteger(r.pid) && Number.isInteger(r.tid) &&
    ["V", "D", "I", "W", "E", "F", "?"].includes(r.level) && typeof r.tag === "string" && typeof r.message === "string";
  if (!Array.isArray(records) || records.length < 1 || records.length > 30 || !Number.isInteger(omitted)) process.exit(1);
  if (!records.every(whole)) process.exit(1);
  console.log(records.length);
') || fail "logs: not one JSON line with 1 to 30 whole records"

# 4. com.android.shell has uid 2000 on every Android.
run logs --package com.android.shell --lines 1
[ "$(printf '%s' "$out" | field uid)" = 2000 ] || fail "logs --package com.android.shell: uid is not 2000"

# 5. The phone's clock, not the computer's: a phone ran 10 s behind (K29 2.6 note). The log daemon may take a moment.
now=$(adb -s "$serial" shell date +%s 2>/dev/null | tr -d '\r')
case "$now" in '' | *[!0-9]*) fail "date +%s on the phone printed no number" ;; esac
since=$((now - 1))
token=k26$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')
adb -s "$serial" shell log -t KaragozSmoke -p i "$token" >/dev/null 2>&1 || fail "log -t KaragozSmoke failed"
tries=0
while :; do
  run logs --package com.android.shell --since "$since"
  set -- $(marked "$token")
  [ "$1" = 0 ] || break
  tries=$((tries + 1))
  [ "$tries" -lt 10 ] || fail "the KaragozSmoke line did not come back within 10 reads"
  sleep 1
done
[ "$1" = 1 ] || fail "expected one I line tagged KaragozSmoke with the token, got $1"

# 6. The largest time as the next --since leaves the line out.
run logs --package com.android.shell --since "$2"
set -- $(marked "$token")
[ "$1" = 0 ] || fail "the chained --since returned the KaragozSmoke line again"

echo "ok: physical default $n, package 2000, marker, chain"
