#!/bin/sh
# Step 1.6: `logs` reads the device log as one JSON line, a record's largest time passed back as --since returns only
# newer records, --lines keeps the newest, and bad arguments fail with the JSON envelope before any device call. A fake
# adb covers logcat's error text, a cut stream, invalid UTF-8, time rounding and the default cap.
# Precondition: an emulator is running with state device. The only write is log records tagged KaragozSmoke; no log
# buffer is cleared, resized or reconfigured.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

tmp=$(mktemp -d)
id=
# set +e: errexit stays on inside the trap.
trap 'set +e; rm -rf "$tmp"' EXIT
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
# Prints one field of a success result. Fails unless stdout is one JSON line with that field.
field() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  const value = JSON.parse(out)[process.argv[1]];
  if (value === undefined) process.exit(1);
  console.log(value);
' "$1"; }
# Prints the records of a success result one per line as JSON. Fails unless stdout is one JSON line with records.
records_of() { node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  const { records } = JSON.parse(out);
  if (!Array.isArray(records)) process.exit(1);
  for (const record of records) console.log(JSON.stringify(record));
'; }
# Fails unless `node dist/cli.js` with the arguments after $2 exits non-zero with a one-line envelope whose code is $1
# and, when $2 is not empty, whose message is exactly $2. Leaves the envelope in $got.
refuses() {
  want=$1 msg=$2
  shift 2
  if got=$(node dist/cli.js "$@" 2>/dev/null); then echo "FAIL: $* exited 0: $got"; exit 1; fi
  [ "$(printf '%s' "$got" | code_of)" = "$want" ] || { echo "FAIL: $*: expected $want, got: $got"; exit 1; }
  [ -z "$msg" ] || [ "$(printf '%s' "$got" | message_of)" = "$msg" ] \
    || { echo "FAIL: $*: expected the message '$msg', got: $got"; exit 1; }
}

# 1. Arguments. Each fails before any device call.
refuses INVALID_ARGS "unexpected argument 'extra'" logs extra
for value in abc 1.1234567890 4294967296; do
  refuses INVALID_ARGS "--since must be Unix time in seconds (got '$value')" logs --since "$value"
done
refuses INVALID_ARGS "--since must be Unix time in seconds (got '-5')" logs --since=-5
# parseArgs reads -5 as an option and rejects the missing value itself.
refuses INVALID_ARGS '' logs --since -5
for value in 0 abc 1000000000; do
  refuses INVALID_ARGS "--lines must be a whole number from 1 to 999999999 (got '$value')" logs --lines "$value"
done
refuses INVALID_ARGS "'a;b' is not a package name" logs --package 'a;b'

# 2. The first ready emulator. Every live call names it, so a second device cannot cause DEVICE_AMBIGUOUS.
list=$(node dist/cli.js devices) || { echo "FAIL: devices exited non-zero: $list"; exit 1; }
id=$(printf '%s' "$list" | node -e '
  const found = JSON.parse(require("fs").readFileSync(0, "utf8")).devices.find((d) => d.kind === "emulator" && d.state === "device");
  if (!found) process.exit(1);
  console.log(found.id);
') || { echo "FAIL: no ready emulator in: $list (is one running? emulator -avd <name>)"; exit 1; }
n=$$
t0=$(adb -s "$id" shell date +%s.%N | tr -d '\r')

# Runs logs on $id; sets $out to the JSON line and $recs to its records, one per line.
read_logs() {
  out=$(node dist/cli.js logs --device "$id" "$@") || { echo "FAIL: logs $* exited non-zero: $out"; exit 1; }
  recs=$(printf '%s' "$out" | records_of) || { echo "FAIL: logs $*: not one JSON line with records: $out"; exit 1; }
}
# How many records in $recs contain the text $1.
seen() { printf '%s\n' "$recs" | grep -cF -- "$1" || true; }
# Fails unless $recs holds exactly one record with the message $1 (as JSON text), tagged KaragozSmoke at level I.
marker() {
  [ "$(seen "\"message\":\"$1\"}")" = 1 ] || { echo "FAIL: logs $2: $(seen "\"message\":\"$1\"}") records with the message $1, expected 1"; exit 1; }
  [ "$(seen "\"level\":\"I\",\"tag\":\"KaragozSmoke\",\"message\":\"$1\"}")" = 1 ] \
    || { echo "FAIL: logs $2: the record $1 is not tagged KaragozSmoke at level I: $(printf '%s\n' "$recs" | grep -F -- "$1")"; exit 1; }
}
# Fails when $recs holds a record with the message $1.
absent() {
  [ "$(seen "\"message\":\"$1\"}")" = 0 ] || { echo "FAIL: logs $2: the earlier record $1 came back"; exit 1; }
}
# The pid of the record with the message $1.
pid_of() { printf '%s\n' "$recs" | grep -F -- "\"message\":\"$1\"}" | sed 's/.*"pid":\([0-9-]*\),.*/\1/'; }
# Prints the largest time in $recs as the JSON has it. Fails when a record's time is not above $1.
latest() { printf '%s\n' "$recs" | node -e '
  const times = require("fs").readFileSync(0, "utf8").trim().split("\n").map((line) => JSON.parse(line).time);
  if (times.some((time) => !(time > Number(process.argv[1])))) process.exit(1);
  console.log(JSON.stringify(Math.max(...times)));
' "$1"; }

# 3. Markers. Each `log` call is a new process; the device shell runs printf, so the third message holds a real
# newline (adb joins shell arguments unquoted).
adb -s "$id" shell log -t KaragozSmoke "one-$n"
adb -s "$id" shell log -t KaragozSmoke "two-$n"
adb -s "$id" shell 'log -t KaragozSmoke "$(printf "ml-'"$n"'\nline2")"'
ml='ml-'"$n"'\nline2'

# 4. Everything since t0. --lines 1000 keeps device noise from pushing the markers out.
read_logs --since "$t0" --lines 1000
[ "$(printf '%s' "$out" | field device)" = "$id" ] || { echo "FAIL: logs --since: device is not $id: $out"; exit 1; }
for key in package uid; do
  if printf '%s' "$out" | field "$key" >/dev/null 2>&1; then echo "FAIL: logs --since: $key without --package"; exit 1; fi
done
[ "$(printf '%s' "$out" | field omitted)" = 0 ] || { echo "FAIL: logs --since: omitted is not 0"; exit 1; }
for m in "one-$n" "two-$n" "$ml"; do marker "$m" --since; done
[ "$(pid_of "one-$n")" != "$(pid_of "two-$n")" ] || { echo "FAIL: logs --since: one and two have the same pid"; exit 1; }
t1=$(latest "$t0") || { echo "FAIL: logs --since $t0: a record is not later than $t0"; exit 1; }

# 5. Chain: the largest time excludes every record read so far; a new marker comes back alone.
read_logs --since "$t1" --lines 1000
for m in "one-$n" "two-$n" "$ml"; do absent "$m" "--since $t1"; done
adb -s "$id" shell log -t KaragozSmoke "three-$n"
read_logs --since "$t1" --lines 1000
marker "three-$n" "--since $t1"
for m in "one-$n" "two-$n" "$ml"; do absent "$m" "--since $t1"; done

# 6. --lines keeps the newest and counts the rest.
read_logs --since "$t0" --lines 1
[ "$(printf '%s\n' "$recs" | wc -l | tr -d ' ')" = 1 ] && [ -n "$recs" ] \
  || { echo "FAIL: logs --lines 1: expected one record: $out"; exit 1; }
[ "$(printf '%s' "$out" | field omitted)" -ge 3 ] || { echo "FAIL: logs --lines 1: omitted is below 3: $out"; exit 1; }

# 7. A start a day ahead matches nothing, and that is a result, not an error.
out=$(node dist/cli.js logs --since "$((${t0%%.*} + 86400)).0" --device "$id") \
  || { echo "FAIL: logs with a future --since exited non-zero: $out"; exit 1; }
[ "$out" = "{\"device\":\"$id\",\"records\":[],\"omitted\":0}" ] || { echo "FAIL: logs with a future --since: $out"; exit 1; }

# 8. --package keeps the package's uid. `adb shell log` runs as com.android.shell (uid 2000); Settings runs as uid
# 1000, shared with system_server.
read_logs --package com.android.shell --since "$t0" --lines 1000
[ "$(printf '%s' "$out" | field package)" = com.android.shell ] && [ "$(printf '%s' "$out" | field uid)" = 2000 ] \
  || { echo "FAIL: logs --package com.android.shell: package or uid is wrong: $(printf '%s' "$out" | cut -c1-200)"; exit 1; }
for m in "one-$n" "two-$n" "$ml" "three-$n"; do marker "$m" '--package com.android.shell'; done
[ "$(pid_of "one-$n")" != "$(pid_of "two-$n")" ] || { echo "FAIL: logs --package: one and two have the same pid"; exit 1; }
read_logs --package com.android.settings --since "$t0" --lines 1000
[ "$(printf '%s' "$out" | field uid)" = 1000 ] || { echo "FAIL: logs --package com.android.settings: uid is not 1000"; exit 1; }
[ "$(seen '"tag":"KaragozSmoke"')" = 0 ] || { echo "FAIL: logs --package com.android.settings returned KaragozSmoke records"; exit 1; }
refuses APP_NOT_FOUND "package 'dev.karagoz.missing' is not installed on $id" logs --package dev.karagoz.missing --device "$id"

# 9. Against a fake adb, for output a live device does not give on demand. ANDROID_HOME makes
# $tmp/sdk/platform-tools/adb karagoz's first adb candidate; it answers logcat with $FAKE/out and records the
# arguments, and pm with $FAKE/pm.
fake=$tmp/fake
mkdir -p "$tmp/sdk/platform-tools" "$fake"
cat > "$tmp/sdk/platform-tools/adb" <<'FAKE'
#!/bin/sh
# Fake adb for smoke 1.6.
case "$*" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n\n' ;;
  *'exec-out pm list packages -U --user 0 '*) cat "$FAKE/pm" ;;
  # Without --user 0, what a phone with a user the shell may not access prints (fixture k), else the same as above.
  *'exec-out pm list packages -U '*) cat "$FAKE/pm-all" 2>/dev/null || cat "$FAKE/pm" ;;
  *'exec-out logcat -d -B'*) printf '%s\n' "$*" >> "$FAKE/args"; cat "$FAKE/out" ;;
  *) echo "fake adb: unexpected arguments: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb"
# Writes logger_entry records (28-byte header, K29) to stdout, one per input line: pid tid sec nsec uid prio tag
# message-in-hex. Hex, because printf and $(...) cannot carry every byte in sh.
cat > "$tmp/entries.js" <<'JS'
for (const line of require('fs').readFileSync(0, 'utf8').trim().split('\n')) {
  const [pid, tid, sec, nsec, uid, prio, tag, hex] = line.split(' ');
  const payload = Buffer.concat([Buffer.from([Number(prio)]), Buffer.from(`${tag}\0`), Buffer.from(hex, 'hex'), Buffer.from([0])]);
  const head = Buffer.alloc(28);
  head.writeUInt16LE(payload.length, 0);
  head.writeUInt16LE(28, 2);
  head.writeInt32LE(Number(pid), 4);
  head.writeUInt32LE(Number(tid), 8);
  head.writeUInt32LE(Number(sec), 12);
  head.writeUInt32LE(Number(nsec), 16);
  head.writeUInt32LE(Number(uid), 24);
  process.stdout.write(Buffer.concat([head, payload]));
}
JS
entries() { node "$tmp/entries.js"; }
# Sets $got. The variables are set inside the substitution: an assignment before a function call outlives the call in sh.
fake_run() { got=$(ANDROID_HOME="$tmp/sdk" FAKE="$fake" node dist/cli.js "$@" 2>/dev/null); }
# Fails unless $got is a one-line envelope with code $2 and, when $3 is not empty, the message $3. $1: the fixture.
error_is() {
  [ "$(printf '%s' "$got" | code_of)" = "$2" ] || { echo "FAIL: fixture $1: expected $2, got: $got"; exit 1; }
  [ -z "$3" ] || [ "$(printf '%s' "$got" | message_of)" = "$3" ] \
    || { echo "FAIL: fixture $1: expected the message '$3', got: $got"; exit 1; }
}
# Fails unless $got is exactly $2. $1: the fixture. printf, not echo: this machine's sh echo expands backslashes (K9).
result_is() { [ "$got" = "$2" ] || { printf 'FAIL: fixture %s: expected %s, got: %s\n' "$1" "$2" "$got"; exit 1; }; }

# a. exec-out puts logcat's own error on stdout and exits 0.
printf '%s\n' 'Failed to wait for logd.ready to become true. logd not running?' > "$fake/out"
if fake_run logs --device emulator-5554; then echo "FAIL: fixture a exited 0: $got"; exit 1; fi
error_is a ADB_FAILED 'Failed to wait for logd.ready to become true. logd not running?'

# b. A stream cut inside a record.
printf '1 1 1790513987 0 2000 4 T 6f6b\n' | entries | head -c 20 > "$fake/out"
if fake_run logs --device emulator-5554; then echo "FAIL: fixture b exited 0: $got"; exit 1; fi
error_is b ADB_FAILED ''

# c. Invalid UTF-8 in a message becomes U+FFFD.
printf '1 1 1790513987 0 2000 4 T 61ff62\n' | entries > "$fake/out"
fake_run logs --device emulator-5554 || { echo "FAIL: fixture c exited non-zero: $got"; exit 1; }
result_is c "$(printf '{"device":"emulator-5554","records":[{"time":1790513987,"pid":1,"tid":1,"level":"I","tag":"T","message":"a\357\277\275b"}],"omitted":0}')"

# d. time is rounded up to the microsecond; a whole second prints without a dot.
printf '%s\n' '1 1 1790513987 191234001 2000 4 T 64' '1 1 1790513987 0 2000 4 T 64' | entries > "$fake/out"
fake_run logs --device emulator-5554 || { echo "FAIL: fixture d exited non-zero: $got"; exit 1; }
result_is d '{"device":"emulator-5554","records":[{"time":1790513987.191235,"pid":1,"tid":1,"level":"I","tag":"T","message":"d"},{"time":1790513987,"pid":1,"tid":1,"level":"I","tag":"T","message":"d"}],"omitted":0}'

# e. The default keeps the newest 30.
node -e 'for (let i = 0; i < 150; i++) console.log(`1 1 1790513987 0 2000 4 T ${Buffer.from(`m${i}`).toString("hex")}`)' \
  | entries > "$fake/out"
fake_run logs --device emulator-5554 || { echo "FAIL: fixture e exited non-zero: $got"; exit 1; }
recs=$(printf '%s' "$got" | records_of) || { echo "FAIL: fixture e: not one JSON line with records: $got"; exit 1; }
[ "$(printf '%s\n' "$recs" | wc -l | tr -d ' ')" = 30 ] || { echo "FAIL: fixture e: expected 30 records"; exit 1; }
printf '%s\n' "$recs" | head -n 1 | grep -qF '"message":"m120"}' || { echo "FAIL: fixture e: the first record is not m120"; exit 1; }
printf '%s\n' "$recs" | tail -n 1 | grep -qF '"message":"m149"}' || { echo "FAIL: fixture e: the last record is not m149"; exit 1; }
[ "$(printf '%s' "$got" | field omitted)" = 120 ] || { echo "FAIL: fixture e: omitted is not 120: $got"; exit 1; }

# f. A --since without a dot reaches logcat with .0: logcat reads an all-digit -t as a line count (K29).
: > "$fake/args"
fake_run logs --since 1790513987 --device emulator-5554 || { echo "FAIL: fixture f exited non-zero: $got"; exit 1; }
[ "$(cat "$fake/args")" = '-s emulator-5554 exec-out logcat -d -B -t 1790513987.0' ] \
  || { echo "FAIL: fixture f: adb got: $(cat "$fake/args")"; exit 1; }

# g. pm list packages matches substrings: only the exact name counts, and only its uid's records are kept.
printf '%s\n' 'package:dev.karagoz.xy uid:10124' 'package:dev.karagoz.x uid:10123' > "$fake/pm"
printf '%s\n' "1 1 1790513987 0 10123 4 T $(printf mine | od -An -tx1 | tr -d ' \n')" \
  "2 2 1790513987 0 2000 4 T $(printf other | od -An -tx1 | tr -d ' \n')" | entries > "$fake/out"
fake_run logs --package dev.karagoz.x --device emulator-5554 || { echo "FAIL: fixture g exited non-zero: $got"; exit 1; }
result_is g '{"device":"emulator-5554","package":"dev.karagoz.x","uid":10123,"records":[{"time":1790513987,"pid":1,"tid":1,"level":"I","tag":"T","message":"mine"}],"omitted":0}'

# h. A longer name that contains the package is not the package.
printf '%s\n' 'package:dev.karagoz.xy uid:10124' > "$fake/pm"
if fake_run logs --package dev.karagoz.x --device emulator-5554; then echo "FAIL: fixture h exited 0: $got"; exit 1; fi
error_is h APP_NOT_FOUND "package 'dev.karagoz.x' is not installed on emulator-5554"

# i. The package without a uid.
printf '%s\n' 'package:dev.karagoz.x' > "$fake/pm"
if fake_run logs --package dev.karagoz.x --device emulator-5554; then echo "FAIL: fixture i exited 0: $got"; exit 1; fi
error_is i ADB_FAILED 'package:dev.karagoz.x'

# j. pm's own error, e.g. while the package service is not up, is not a missing package.
printf '%s\n' 'Error: something' > "$fake/pm"
if fake_run logs --package dev.karagoz.x --device emulator-5554; then echo "FAIL: fixture j exited 0: $got"; exit 1; fi
error_is j ADB_FAILED 'Error: something'

# k. From Android 13, pm list packages without --user walks every user and stops at one the shell may not access
# (Secure Folder, a managed work profile), printing only the exception (K29 2.6 note).
printf '%s\n' "Exception occurred while executing 'list':" \
  'java.lang.SecurityException: Shell does not have permission to access user 150' > "$fake/pm-all"
printf '%s\n' 'package:dev.karagoz.x uid:10123' > "$fake/pm"
printf '%s\n' "1 1 1790513987 0 10123 4 T $(printf mine | od -An -tx1 | tr -d ' \n')" | entries > "$fake/out"
fake_run logs --package dev.karagoz.x --device emulator-5554 || { echo "FAIL: fixture k exited non-zero: $got"; exit 1; }
result_is k '{"device":"emulator-5554","package":"dev.karagoz.x","uid":10123,"records":[{"time":1790513987,"pid":1,"tid":1,"level":"I","tag":"T","message":"mine"}],"omitted":0}'

# l. More than adbBytes' 64 MB maxBuffer: Node's own message would not tell the caller what to do.
head -c 70000000 /dev/zero > "$fake/out"
if fake_run logs --device emulator-5554; then echo "FAIL: fixture l exited 0"; exit 1; fi
error_is l ADB_FAILED 'the device log is larger than the 64 MB karagoz reads at once. Pass --since to read only records after a recent time on the device clock (`adb shell date +%s` prints it).'

echo "ok: $id, args, markers, chain, lines, future, package, fake adb, multi-user, overflow"
