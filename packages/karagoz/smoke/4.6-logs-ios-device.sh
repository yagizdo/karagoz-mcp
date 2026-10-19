#!/bin/sh
# Step 4.6: on macOS `logs` reads a paired iPhone's past records over USB with no sudo: the pair record from usbmuxd, a
# lockdown session over TLS, the phone's log relay archive unpacked by tar into a temporary .logarchive, read by log
# show (K44). Fakes prove the archive request and log show's argv for each window, the record mapping, --since, --lines,
# --package's proof rule (the current install folder or a pid launchd ran under the bundle id, else every folder) and
# its one-hour window, APP_NOT_FOUND, not on USB, no pair record, a refused session, a missing service, a refused
# archive, a cut and a stalled stream, log's own failure and hang, missing tools, malformed output, an unpaired phone,
# a temporary directory gone after every case (also after SIGTERM mid-archive) and no pair-record value in any output.
# Precondition: macOS. Fake usbmuxd (smoke/fixtures/logs-ios-device/usbmuxd.cjs, TLS with a throwaway openssl
# certificate), devicectl, adb and simctl come under env -i; a fake log is first on PATH, tar is macOS's own.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iPhones need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; [ -f "$tmp/daemon" ] && kill "$(cat "$tmp/daemon")"; pkill -f "sleep 97\\.46"; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
code_of() { "$node_bin" -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }
# "<message>,<message>,...|<omitted>" of a success result; fails unless stdout is one JSON line with records.
summary_of() { "$node_bin" -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  if (out.includes("\n")) process.exit(1);
  const r = JSON.parse(out);
  console.log(r.records.map((x) => x.message).join(",") + "|" + r.omitted);
'; }

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them. Files under $fake steer them.
fake=$tmp/fake
dev=$tmp/dev
mkdir -p "$tmp/sdk/platform-tools" "$dev/usr/bin" "$tmp/home" "$tmp/bin" "$tmp/onlytar" "$tmp/t" "$fake/src"
printf '#!/bin/sh\ncase "$*" in devices) printf "List of devices attached\\n\\n" ;; *) exit 1 ;; esac\n' > "$tmp/sdk/platform-tools/adb"
printf '#!/bin/sh\necho %s\n' "'{\"devices\":{}}'" > "$dev/usr/bin/simctl"
cat > "$dev/usr/bin/devicectl" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/calls"
case "\$*" in
  "list devices --json-output - -q") /bin/cat "$fake/list.json" ;;
  "device info apps --device P1 --bundle-id "*" --include-all-apps --json-output - -q")
    if [ -e "$fake/app-\$7" ]; then /bin/cat "$fake/app-\$7"; else echo '{"result":{"apps":[]}}'; fi ;;
  *) echo "unexpected devicectl \$*" >&2; exit 1 ;;
esac
FAKE
# log show: argv one per line, the archive directory checked as macOS's log checks it, then $fake/ndjson.
cat > "$tmp/bin/log" <<FAKE
#!/bin/sh
for a in "\$@"; do echo "\$a"; done > "$fake/log-argv"
[ "\$2" = --archive ] && [ "\${3%.logarchive}" != "\$3" ] && [ -f "\$3/Info.plist" ] && [ -f "\$3/data.bin" ] || {
  echo "log: An archive must have extension .logarchive" >&2; exit 64; }
[ -e "$fake/log-hang" ] && exec /bin/sleep 97.46
[ -e "$fake/log-stderr" ] && /bin/cat "$fake/log-stderr" >&2
/bin/cat "$fake/ndjson"
exit \$(/bin/cat "$fake/log-exit" 2>/dev/null || echo 0)
FAKE
ln -s /usr/bin/tar "$tmp/onlytar/tar"
chmod +x "$tmp/sdk/platform-tools/adb" "$dev/usr/bin/simctl" "$dev/usr/bin/devicectl" "$tmp/bin/log"
phone() { echo "{\"visibilityClass\":\"default\",\"properties\":{\"hardware\":{\"udid\":\"$1\",\"reality\":\"physical\",\"platform\":\"iOS\",\"marketingName\":\"iPhone 14 Pro Max\"},\"connection\":{\"pairingState\":\"$2\",\"state\":\"connected\",\"transportType\":\"wired\"}}}"; }
echo "{\"result\":{\"devices\":[$(phone P1 paired),$(phone P3 unpaired)]}}" > "$fake/list.json"
echo '{"result":{"apps":[{"bundleIdentifier":"dev.karagoz.probe","url":"file:///private/var/containers/Bundle/Application/AAAA/Probe.app/","removable":true}]}}' > "$fake/app-dev.karagoz.probe"
echo P1 > "$fake/usb"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fake/key.pem" -out "$fake/cert.pem" -days 1 -subj /CN=fake 2> /dev/null
/bin/dd if=/dev/zero of="$fake/src/data.bin" bs=1000 count=40 2> /dev/null
echo '<plist version="1.0"><dict/></plist>' > "$fake/src/Info.plist"
# The phone sends Info.plist last (K44 M5).
/usr/bin/tar -cf "$fake/archive.tar" -C "$fake/src" data.bin Info.plist
# Started from a subshell, so the shell does not report its end when the trap stops it.
("$node_bin" smoke/fixtures/logs-ios-device/usbmuxd.cjs "$tmp/usbmuxd" "$fake" & echo $! > "$tmp/daemon")
i=0
while [ ! -S "$tmp/usbmuxd" ]; do i=$((i + 1)); [ $i -lt 50 ] || fail "the fake usbmuxd did not start"; sleep 0.1; done

# Records: base 2026-10-19 10:00:00 UTC; the phone's clock reads base + 100.
base=1792404000
echo $((base + 100)) > "$fake/clock"
# rec <offset seconds> <level> <image> <pid> <subsystem> <message>: one log show ndjson line.
rec() { "$node_bin" -e '
  const [off, level, image, pid, subsystem, message] = process.argv.slice(1);
  const at = new Date((1792404000 + Number(off)) * 1000).toISOString().replace("T", " ").replace(/\.(\d+)Z$/, (m, f) => "." + f.padEnd(6, "0") + "+0000");
  console.log(JSON.stringify({ timestamp: at, messageType: level, eventType: "logEvent", processImagePath: image,
    processImageUUID: "00000000-0000-0000-0000-000000000000", processID: Number(pid), threadID: 9, subsystem,
    category: "c", eventMessage: message }));
' -- "$@"; }
done_line() { echo '{"count":0,"finished":1}'; }
c=/private/var/containers/Bundle/Application
spawned() { rec "$1" Default /sbin/launchd 1 "user/501/UIKitApplication:dev.karagoz.probe[ab12][rb-legacy] [$2]" "service spawned with pid $2"; }

# karagoz with only the fakes. Sets $out and $st; every case leaves no temporary directory.
call() {
  rm -f "$fake/calls" "$fake/connects" "$fake/requests" "$fake/log-argv"
  out=$(env -i HOME="$tmp/home" PATH="${PATHS:-$tmp/bin:/usr/bin:/bin}" TMPDIR="$tmp/t" ANDROID_HOME="$tmp/sdk" \
    DEVELOPER_DIR="$dev" USBMUXD_SOCKET_ADDRESS="UNIX:$tmp/usbmuxd" "$node_bin" dist/cli.js "$@" 2>> "$tmp/stderr") && st=0 || st=$?
  echo "$out" >> "$tmp/stdout"
  [ -z "$(ls "$tmp/t")" ] || fail "$*: left $(ls "$tmp/t") in TMPDIR"
}
succeeds() { # <label> <expected summary>
  [ "$st" = 0 ] || fail "$1 exited $st: $out"
  got=$(printf '%s' "$out" | summary_of) || fail "$1: not one result line: $out"
  [ "$got" = "$2" ] || fail "$1: got $got, expected $2"
}
refuses() { # <code> <label> [<message>]
  [ "$st" -ne 0 ] || fail "$2 exited 0: $out"
  [ "$(printf '%s' "$out" | code_of)" = "$1" ] || fail "$2: expected $1, got: $out"
  [ $# -lt 3 ] || [ "$(printf '%s' "$out" | message_of)" = "$3" ] || fail "$2: expected the message '$3', got: $out"
}
argv_is() { # <label> <expected log argv, space-separated, the archive path as ARCHIVE>
  got=$(sed -E 's#^.*/karagoz-logs-[^/]+/phone\.logarchive$#ARCHIVE#' "$fake/log-argv" | tr '\n' ' ' | sed 's/ $//')
  [ "$got" = "$2" ] || fail "$1: log argv was '$got', expected '$2'"
}
start_is() { # <label> <StartTime>
  grep -q "<key>Request</key><string>CreateArchive</string><key>StartTime</key><integer>$2</integer>" "$fake/requests" ||
    fail "$1: archive request was $(cat "$fake/requests" 2> /dev/null)"
}
trust='Unlock the iPhone, tap Trust on "Trust This Computer?" and enter the passcode; if no prompt shows, unplug it and plug it in again.'

# a. The default read: the last minute on the phone's clock, every record, the record's full shape.
{ rec 10.5 Default "$c/X/A.app/A" 7 s m1; rec 20.5 Info "$c/X/A.app/A" 7 s m2; rec 30.5 Error /usr/libexec/d 8 '' m3; done_line; } > "$fake/ndjson"
call logs --device P1
succeeds "default" "m1,m2,m3|0"
start_is "default" $((base + 40))
argv_is "default" "show --archive ARCHIVE --style ndjson --info --debug --last 1m --predicate type == logEvent"
first=$(printf '%s' "$out" | "$node_bin" -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(0, "utf8")).records[2]))')
[ "$first" = "{\"time\":$((base + 30)).5,\"pid\":8,\"tid\":9,\"level\":\"E\",\"tag\":\"d\",\"subsystem\":\"\",\"category\":\"c\",\"message\":\"m3\"}" ] || fail "mapping: $first"
[ "$(printf '%s' "$out" | "$node_bin" -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(Object.keys(r).join())')" = device,records,omitted ] || fail "default keys: $out"

# b. --since: whole seconds to the phone and to log show, karagoz keeps only later records; the chain stops.
call logs --device P1 --since "$((base + 20)).25"
succeeds "--since" "m2,m3|0"
start_is "--since" $((base + 20))
argv_is "--since" "show --archive ARCHIVE --style ndjson --info --debug --start @$((base + 20)) --predicate type == logEvent"
call logs --device P1 --since "$((base + 30)).5"
succeeds "chain" "|0"

# c. --lines: the newest, omitted counted.
call logs --device P1 --lines 2
succeeds "--lines" "m2,m3|1"

# d. --package: the hour before the phone's clock, no window for log show; AAAA is proven only as the current install,
# BBBB only by launchd's line for its pid, CCCC is another app with the same folder name; launchd's exit line (of a run
# with no records here) comes out, its other lines do not.
{
  rec -4000 Default "$c/AAAA/Probe.app/Probe" 100 s old
  spawned 5 200
  rec 10 Default "$c/AAAA/Probe.app/Probe" 100 s a10
  rec 20 Default "$c/BBBB/Probe.app/Probe" 200 s b20
  rec 25 Default "$c/CCCC/Probe.app/Probe" 300 s c25
  rec 30 Default "$c/AAAA/Probe.app/PlugIns/W.appex/W" 101 s a30
  rec 35 Default /sbin/launchd 1 "user/501/UIKitApplication:dev.karagoz.probe[cd34][rb-legacy] [400]" "exited due to SIGKILL"
  rec 40 Info "$c/BBBB/Probe.app/Probe" 200 s b40
  done_line
} > "$fake/ndjson"
call logs --package dev.karagoz.probe --device P1
succeeds "--package" "a10,b20,a30,exited due to SIGKILL,b40|0"
start_is "--package" $((base - 3500))
argv_is "--package" "show --archive ARCHIVE --style ndjson --info --debug --predicate type == logEvent AND (processImagePath CONTAINS \"/Probe.app/\" OR (process == \"launchd\" AND subsystem CONTAINS \"UIKitApplication:dev.karagoz.probe[\"))"
[ "$(printf '%s' "$out" | "$node_bin" -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(r.package, r.records[3].tag, r.records[2].tag)')" = "dev.karagoz.probe launchd W" ] || fail "package fields: $out"

# c2. --package --lines: the newest across folders and exit lines, by time.
call logs --package dev.karagoz.probe --device P1 --lines 2
succeeds "--package --lines" "exited due to SIGKILL,b40|3"

# d2. --package --since: BBBB's proof (the launchd line at +5) is older than --since and still counts.
call logs --package dev.karagoz.probe --device P1 --since $((base + 15))
succeeds "--package --since" "b20,a30,exited due to SIGKILL,b40|0"
start_is "--package --since" $((base + 15))
argv_is "--package --since" "show --archive ARCHIVE --style ndjson --info --debug --predicate type == logEvent AND (processImagePath CONTAINS \"/Probe.app/\" OR (process == \"launchd\" AND subsystem CONTAINS \"UIKitApplication:dev.karagoz.probe[\"))"

# e. No folder proven: every folder with the app's folder name.
{ rec 20 Default "$c/BBBB/Probe.app/Probe" 200 s b20; rec 25 Default "$c/CCCC/Probe.app/Probe" 300 s c25; done_line; } > "$fake/ndjson"
call logs --package dev.karagoz.probe --device P1
succeeds "no proof" "b20,c25|0"

# f. Not installed: devicectl says so before any usbmuxd connection.
call logs --package dev.karagoz.absent --device P1
refuses APP_NOT_FOUND "not installed" "app 'dev.karagoz.absent' is not installed on P1"
[ ! -e "$fake/connects" ] || fail "not installed: usbmuxd was reached"

# j. An unpaired phone: refused before usbmuxd.
call logs --device P3
refuses DEVICE_NOT_READY "unpaired" "device P3 is not ready (state: unpaired). $trust"
[ ! -e "$fake/connects" ] || fail "unpaired: usbmuxd was reached"

# g. Failures, each with the code the caller acts on.
: > "$fake/usb"
call logs --device P1
refuses DEVICE_NOT_READY "not on USB" "device P1 is not ready: it is not connected by USB. karagoz reaches an iPhone's log over a USB cable; connect the iPhone with one."
echo P1 > "$fake/usb"
: > "$fake/no-record"
call logs --device P1
refuses DEVICE_NOT_READY "no pair record" "device P1 is not ready: this Mac holds no pairing record for it. $trust"
rm "$fake/no-record"
echo InvalidHostID > "$fake/session-error"
call logs --device P1
refuses DEVICE_NOT_READY "session refused" "device P1 is not ready: the iPhone refused a session (InvalidHostID). $trust"
rm "$fake/session-error"
: > "$fake/no-service"
call logs --device P1
refuses HELPER_FAILED "no service" "the iPhone did not start its log service (InvalidService)"
rm "$fake/no-service"
: > "$fake/bad-status"
call logs --device P1
refuses HELPER_FAILED "bad status"
case $(printf '%s' "$out" | message_of) in "the iPhone's log service did not build an archive: "*Failed*) ;; *) fail "bad status: $out" ;; esac
rm "$fake/bad-status"
: > "$fake/cut"
call logs --device P1
refuses HELPER_FAILED "cut stream"
rm "$fake/cut"
for f in hang hang-mid; do
  : > "$fake/$f"
  call logs --device P1
  refuses HELPER_FAILED "$f" "the iPhone sent no log data for 30 s"
  rm "$fake/$f"
done
{ rec 10 Default "$c/X/A.app/A" 7 s m1; done_line; } > "$fake/ndjson"
echo 'log: Could not open the archive' > "$fake/log-stderr"
echo 1 > "$fake/log-exit"
call logs --device P1
refuses HELPER_FAILED "log failed" "log: Could not open the archive"
rm "$fake/log-stderr" "$fake/log-exit"
: > "$fake/log-hang"
call logs --device P1
refuses HELPER_FAILED "log hung" "log show did not finish within 30 s. Pass a later --since, or --package, to read less of the iPhone log."
rm "$fake/log-hang"
# sh keeps an assignment made before a function call, so PATHS is set and cleared on its own.
PATHS=$tmp/onlytar
call logs --device P1
refuses HELPER_FAILED "no log" "log not found on PATH"
PATHS=/nowhere
call logs --device P1
refuses HELPER_FAILED "no tar" "tar not found on PATH"
PATHS=
{ echo garbage; done_line; } > "$fake/ndjson"
call logs --device P1
refuses HELPER_FAILED "malformed" "unexpected log output: garbage"

# h. SIGTERM while tar unpacks: the temporary directory goes with the process.
: > "$fake/hang-mid"
env -i HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin" TMPDIR="$tmp/t" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$dev" \
  USBMUXD_SOCKET_ADDRESS="UNIX:$tmp/usbmuxd" "$node_bin" dist/cli.js logs --device P1 > /dev/null 2>&1 &
cli=$!
i=0
until [ -f "$(ls -d "$tmp"/t/karagoz-logs-*/phone.logarchive 2> /dev/null)/data.bin" ]; do
  i=$((i + 1)); [ $i -lt 100 ] || fail "SIGTERM: tar never started"; sleep 0.1
done
kill -TERM $cli
wait $cli || true
[ -z "$(ls "$tmp/t")" ] || fail "SIGTERM: left $(ls "$tmp/t") in TMPDIR"
rm "$fake/hang-mid"

# i. No pair-record value in anything karagoz printed.
for secret in FAKE-HOST-ID-4242 FAKE-SYSTEM-BUID-4242 "$(sed -n 5p "$fake/key.pem")" "$(sed -n 5p "$fake/cert.pem")"; do
  ! grep -qF -- "$secret" "$tmp/stdout" "$tmp/stderr" || fail "a pair-record value was printed"
done
fakes="fakes: default, since, chain, lines, package, package lines, package since, no proof, not installed, unpaired, not on USB, no record, session, service, status, cut, stalls (60s), log errors, tools, malformed, SIGTERM, secrets"

echo "ok: $fakes"
