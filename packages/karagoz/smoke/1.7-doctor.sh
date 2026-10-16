#!/bin/sh
# Step 1.7: `doctor` reports every adb candidate with its source, status and version, and the one the lookup uses.
# Every adb here is a fake; the machine's adb and the adb server are never touched. No device needed.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
listener=
# set +e: errexit stays on inside the trap, and a failing kill or wait would skip the rm.
trap 'set +e; kill $listener 2>/dev/null; wait $listener 2>/dev/null; rm -rf "$tmp"' EXIT
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
# Runs doctor with only the VAR=value pairs given; env -i keeps the machine's PATH and SDK variables out. Sets $full to
# the line and $got to its adb object alone: on macOS the line also carries this Mac's Xcode, which smoke 3.7 checks.
doc() {
  full=$(env -i HOME="$tmp/home" ARGS="$tmp/args" "$@" "$node_bin" dist/cli.js doctor 2>/dev/null) \
    || { printf 'FAIL: doctor exited non-zero: %s\n' "$full"; exit 1; }
  got=$(printf '%s' "$full" | node -e '
    const out = require("fs").readFileSync(0, "utf8").trimEnd();
    try { console.log(out.includes("\n") ? "not-one-line" : JSON.stringify({ adb: JSON.parse(out).adb })) } catch { console.log("not-json") }
  ')
}
# Fails unless $got is exactly $2. $1: the case. printf, not echo: this machine's sh echo expands backslashes (K9).
is() { [ "$got" = "$2" ] || { printf 'FAIL: %s: expected %s, got: %s\n' "$1" "$2" "$got"; exit 1; }; }

if [ "$(uname)" = Darwin ]; then
  default=$tmp/home/Library/Android/sdk/platform-tools/adb
  manager='brew install --cask android-platform-tools, or '
else
  default=$tmp/home/Android/Sdk/platform-tools/adb
  manager=
fi
hint="Install platform-tools (${manager}download https://developer.android.com/tools/releases/platform-tools and add it to PATH) or set ANDROID_HOME to your Android SDK."

# The fake adb. PATH holds no tools when it runs, so it uses builtins and absolute paths only. Any argv other than
# `version` waits on the server port, as the real client does.
cat > "$tmp/fake.sh" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$ARGS"
if [ "$*" != version ]; then
  exec "$NODE" -e 'require("net").connect(Number(process.env.ANDROID_ADB_SERVER_PORT), "127.0.0.1")'
fi
IFS= read -r line < "${0%/*}/version"
printf '%s\n' 'Android Debug Bridge version 1.0.41' "$line" "Installed as $0" 'Running on Fake 1.0 (x86_64)'
FAKE
# fake <dir> <Version line>: a fake adb in <dir> that prints that line.
fake() {
  mkdir -p "$1"
  cp "$tmp/fake.sh" "$1/adb"
  chmod 755 "$1/adb"
  printf '%s\n' "$2" > "$1/version"
}
# script <dir> <line>: an adb in <dir> that is a sh script running <line>.
script() {
  mkdir -p "$1"
  printf '#!/bin/sh\n%s\n' "$2" > "$1/adb"
  chmod 755 "$1/adb"
}
home_unset='{"source":"ANDROID_HOME","status":"unset"}'
root_unset='{"source":"ANDROID_SDK_ROOT","status":"unset"}'
path_missing='{"source":"PATH","status":"missing"}'
path_ok="{\"source\":\"PATH\",\"status\":\"ok\",\"path\":\"$tmp/p/adb\",\"version\":\"36.0.2-14143358\"}"
default_missing="{\"source\":\"default\",\"status\":\"missing\",\"path\":\"$default\"}"
# The report when ANDROID_HOME's adb at $1 is used and fails with the message $2, and nothing else is there.
home_failed() {
  m="\"path\":\"$1\",\"message\":\"$2\""
  printf '{"adb":{"status":"failed","source":"ANDROID_HOME",%s,"install":"%s","candidates":[%s,%s,%s,%s]}}' \
    "$m" "$hint" "{\"source\":\"ANDROID_HOME\",\"status\":\"failed\",$m}" "$root_unset" "$path_missing" "$default_missing"
}

# 1. Arguments.
refuses INVALID_ARGS "unexpected argument 'extra'" doctor extra
refuses INVALID_ARGS "'doctor' does not take the option '--device'" doctor --device x

# 2. No adb anywhere, and the install text ADB_NOT_FOUND shares with it.
mkdir -p "$tmp/empty"
doc PATH="$tmp/empty"
is missing "{\"adb\":{\"status\":\"missing\",\"install\":\"$hint\",\"candidates\":[$home_unset,$root_unset,$path_missing,$default_missing]}}"
if got=$(env -i HOME="$tmp/home" PATH="$tmp/empty" DEVELOPER_DIR="$tmp/empty" "$node_bin" dist/cli.js devices 2>/dev/null); then
  echo "FAIL: devices without adb exited 0: $got"
  exit 1
fi
[ "$(printf '%s' "$got" | code_of)" = ADB_NOT_FOUND ] || { printf 'FAIL: expected ADB_NOT_FOUND, got: %s\n' "$got"; exit 1; }
[ "$(printf '%s' "$got" | message_of)" = "adb not found (tried PATH, $default). $hint" ] \
  || { printf 'FAIL: ADB_NOT_FOUND message changed: %s\n' "$got"; exit 1; }
keys=$(printf '%s' "$full" | node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(0, "utf8"))).join())')
if [ "$(uname)" = Darwin ]; then want=adb,xcode; else want=adb; fi
[ "$keys" = "$want" ] || { echo "FAIL: doctor's keys: expected $want, got $keys"; exit 1; }

# 3. Found: ANDROID_HOME is used, PATH is listed.
fake "$tmp/a/platform-tools" 'Version 37.0.1-15733141'
fake "$tmp/p" 'Version 36.0.2-14143358'
: > "$tmp/args"
doc PATH="$tmp/p" ANDROID_HOME="$tmp/a"
a="\"path\":\"$tmp/a/platform-tools/adb\",\"version\":\"37.0.1-15733141\""
is found "{\"adb\":{\"status\":\"ok\",\"source\":\"ANDROID_HOME\",$a,\"candidates\":[{\"source\":\"ANDROID_HOME\",\"status\":\"ok\",$a},$root_unset,$path_ok,$default_missing]}}"
[ "$(cat "$tmp/args")" = "$(printf 'version\nversion')" ] || { echo "FAIL: found: fake adb got: $(cat "$tmp/args")"; exit 1; }

# 4. Versions and the floor.
doc PATH="$tmp/p" ANDROID_HOME=
is 'empty ANDROID_HOME' "{\"adb\":{\"status\":\"ok\",\"source\":\"PATH\",\"path\":\"$tmp/p/adb\",\"version\":\"36.0.2-14143358\",\"candidates\":[$home_unset,$root_unset,$path_ok,$default_missing]}}"

fake "$tmp/d/platform-tools" 'Version 34.0.5-debian'
doc PATH="$tmp/empty" ANDROID_SDK_ROOT="$tmp/d"
d="\"path\":\"$tmp/d/platform-tools/adb\",\"version\":\"34.0.5-debian\""
is debian "{\"adb\":{\"status\":\"ok\",\"source\":\"ANDROID_SDK_ROOT\",$d,\"candidates\":[$home_unset,{\"source\":\"ANDROID_SDK_ROOT\",\"status\":\"ok\",$d},$path_missing,$default_missing]}}"

fake "$tmp/o/platform-tools" 'Version 29.0.6-debian'
doc PATH="$tmp/empty" ANDROID_HOME="$tmp/o"
o="\"path\":\"$tmp/o/platform-tools/adb\",\"version\":\"29.0.6-debian\",\"message\":\"karagoz install needs platform-tools 30.0.0 or newer\""
is outdated "{\"adb\":{\"status\":\"outdated\",\"source\":\"ANDROID_HOME\",$o,\"install\":\"$hint\",\"candidates\":[{\"source\":\"ANDROID_HOME\",\"status\":\"outdated\",$o},$root_unset,$path_missing,$default_missing]}}"

# Debian's 8.1.0 package prints its package version, epoch first.
fake "$tmp/u/platform-tools" 'Version 1:8.1.0+r23-8'
doc PATH="$tmp/empty" ANDROID_HOME="$tmp/u"
u="\"path\":\"$tmp/u/platform-tools/adb\",\"version\":\"1:8.1.0+r23-8\",\"message\":\"karagoz install needs platform-tools 30.0.0 or newer\""
is epoch "{\"adb\":{\"status\":\"outdated\",\"source\":\"ANDROID_HOME\",$u,\"install\":\"$hint\",\"candidates\":[{\"source\":\"ANDROID_HOME\",\"status\":\"outdated\",$u},$root_unset,$path_missing,$default_missing]}}"

fake "$tmp/r/platform-tools" 'Revision 7f5b3b1c9a2e-android'
doc PATH="$tmp/empty" ANDROID_HOME="$tmp/r"
is 'no Version line' "$(home_failed "$tmp/r/platform-tools/adb" \
  "no Version line in 'adb version' output: Android Debug Bridge version 1.0.41")"

# The floor itself, from the OS default SDK location.
fake "$(dirname "$default")" 'Version 30.0.0-6374843'
doc PATH="$tmp/empty"
is default "{\"adb\":{\"status\":\"ok\",\"source\":\"default\",\"path\":\"$default\",\"version\":\"30.0.0-6374843\",\"candidates\":[$home_unset,$root_unset,$path_missing,{\"source\":\"default\",\"status\":\"ok\",\"path\":\"$default\",\"version\":\"30.0.0-6374843\"}]}}"
rm -rf "$tmp/home"

# 5. Broken and used: any spawn error but ENOENT stops the lookup (K19), so PATH is listed but not used.
fake "$tmp/b/platform-tools" 'Version 37.0.1-15733141'
chmod 644 "$tmp/b/platform-tools/adb"
doc PATH="$tmp/p" ANDROID_HOME="$tmp/b"
b="\"path\":\"$tmp/b/platform-tools/adb\",\"message\":\"spawn $tmp/b/platform-tools/adb EACCES\""
is EACCES "{\"adb\":{\"status\":\"failed\",\"source\":\"ANDROID_HOME\",$b,\"install\":\"$hint\",\"candidates\":[{\"source\":\"ANDROID_HOME\",\"status\":\"failed\",$b},$root_unset,$path_ok,$default_missing]}}"

mkdir -p "$tmp/e/platform-tools"
: > "$tmp/e/platform-tools/adb"
chmod 755 "$tmp/e/platform-tools/adb"
doc PATH="$tmp/empty" ANDROID_HOME="$tmp/e"
is ENOEXEC "$(home_failed "$tmp/e/platform-tools/adb" 'spawn ENOEXEC')"

: > "$tmp/afile"
doc PATH="$tmp/empty" ANDROID_HOME="$tmp/afile"
is ENOTDIR "$(home_failed "$tmp/afile/platform-tools/adb" 'spawn ENOTDIR')"

# 6. Only `version` reached a fake. if, not a bare grep: a grep that matches nothing exits 1 under set -e.
if grep -v '^version$' "$tmp/args"; then echo "FAIL: fake adb got arguments other than version"; exit 1; fi

# 7. Broken and skipped: a file that spawns with ENOENT is passed over by the lookup, so PATH is used.
mkdir -p "$tmp/s/platform-tools" "$tmp/l/platform-tools"
printf '#!/nonexistent/sh\n' > "$tmp/s/platform-tools/adb"
chmod 755 "$tmp/s/platform-tools/adb"
ln -s "$tmp/nowhere" "$tmp/l/platform-tools/adb"
doc PATH="$tmp/p" ANDROID_HOME="$tmp/s" ANDROID_SDK_ROOT="$tmp/l"
enoent='exists but could not be started (ENOENT): a missing interpreter or a broken link'
s="{\"source\":\"ANDROID_HOME\",\"status\":\"failed\",\"path\":\"$tmp/s/platform-tools/adb\",\"message\":\"$enoent\"}"
l="{\"source\":\"ANDROID_SDK_ROOT\",\"status\":\"failed\",\"path\":\"$tmp/l/platform-tools/adb\",\"message\":\"$enoent\"}"
is skipped "{\"adb\":{\"status\":\"ok\",\"source\":\"PATH\",\"path\":\"$tmp/p/adb\",\"version\":\"36.0.2-14143358\",\"candidates\":[$s,$l,$path_ok,$default_missing]}}"

# 8. Exit codes.
script "$tmp/x1/platform-tools" "echo 'dyld: Library not loaded' >&2; exit 1"
doc PATH="$tmp/empty" ANDROID_HOME="$tmp/x1"
is stderr "$(home_failed "$tmp/x1/platform-tools/adb" 'dyld: Library not loaded')"
script "$tmp/x2/platform-tools" 'exit 3'
doc PATH="$tmp/empty" ANDROID_HOME="$tmp/x2"
is 'exit 3' "$(home_failed "$tmp/x2/platform-tools/adb" 'exited with 3')"
script "$tmp/x3/platform-tools" 'kill -SEGV $$'
doc PATH="$tmp/empty" ANDROID_HOME="$tmp/x3"
is signal "$(home_failed "$tmp/x3/platform-tools/adb" 'killed by SIGSEGV')"

# 9. Two hung binaries time out together. exec: a timeout kills only the direct child, and a sleep under sh would
# outlive it.
script "$tmp/h1/platform-tools" 'exec /bin/sleep 31'
script "$tmp/h2/platform-tools" 'exec /bin/sleep 31'
start=$(date +%s)
doc PATH="$tmp/p" ANDROID_HOME="$tmp/h1" ANDROID_SDK_ROOT="$tmp/h2"
elapsed=$(($(date +%s) - start))
[ "$elapsed" -lt 15 ] || { echo "FAIL: two hung adbs took ${elapsed}s, not in parallel"; exit 1; }
h1="\"path\":\"$tmp/h1/platform-tools/adb\",\"message\":\"did not answer within 10s\""
h2="{\"source\":\"ANDROID_SDK_ROOT\",\"status\":\"failed\",\"path\":\"$tmp/h2/platform-tools/adb\",\"message\":\"did not answer within 10s\"}"
is hung "{\"adb\":{\"status\":\"failed\",\"source\":\"ANDROID_HOME\",$h1,\"install\":\"$hint\",\"candidates\":[{\"source\":\"ANDROID_HOME\",\"status\":\"failed\",$h1},$h2,$path_ok,$default_missing]}}"
if pgrep -fx '/bin/sleep 31'; then echo "FAIL: a sleep outlived the timeout"; exit 1; fi

# 10. A hung server: a port that accepts and never answers. The fakes connect to it for anything but `version`,
# so a server call would hang here and leave a line in conns.
node -e '
  const fs = require("fs");
  const s = require("net").createServer(() => fs.appendFileSync(process.argv[2], "connection\n"));
  s.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[1], String(s.address().port)));
' "$tmp/port" "$tmp/conns" &
listener=$!
while [ ! -s "$tmp/port" ]; do kill -0 "$listener" || { echo "FAIL: listener did not start"; exit 1; }; sleep 0.1; done
: > "$tmp/args"
start=$(date +%s)
doc PATH="$tmp/p" ANDROID_HOME="$tmp/a" ANDROID_ADB_SERVER_PORT="$(cat "$tmp/port")" NODE="$node_bin"
elapsed=$(($(date +%s) - start))
[ "$elapsed" -lt 3 ] || { echo "FAIL: doctor took ${elapsed}s against a hung server"; exit 1; }
is 'hung server' "{\"adb\":{\"status\":\"ok\",\"source\":\"ANDROID_HOME\",$a,\"candidates\":[{\"source\":\"ANDROID_HOME\",\"status\":\"ok\",$a},$root_unset,$path_ok,$default_missing]}}"
[ ! -s "$tmp/conns" ] || { echo "FAIL: doctor connected to the server port"; exit 1; }
if grep -v '^version$' "$tmp/args"; then echo "FAIL: fake adb got arguments other than version"; exit 1; fi

echo "ok: args, missing, found, versions, broken, skipped, exits, hung binary, hung server"
