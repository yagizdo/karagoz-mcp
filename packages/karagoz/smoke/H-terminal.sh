#!/bin/sh
# Terminal output: at a terminal, doctor and devices print text with ✓ ! ✗ marks and other commands indented
# JSON; piped, every command prints its one JSON line. A pseudo-terminal from script(1) stands in for the terminal.
# Every adb and Xcode tool here is a fake; no device needed.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; rm -rf "$tmp"' EXIT

# A fake adb with a ready phone and an unauthorized one, or none with EMPTY set. PATH holds no tools: builtins only.
mkdir -p "$tmp/sdk/platform-tools" "$tmp/empty" "$tmp/dev/usr/bin"
cat > "$tmp/sdk/platform-tools/adb" <<'FAKE'
#!/bin/sh
case "$*" in
  version) printf '%s\n' 'Android Debug Bridge version 1.0.41' 'Version 37.0.1-15733141' ;;
  devices)
    printf 'List of devices attached\n'
    [ -n "$EMPTY" ] || printf 'FAKE0001\tdevice\nFAKE0002\tunauthorized\n\n' ;;
  '-s FAKE0001 shell getprop ro.build.version.release; getprop ro.build.version.sdk') printf '14\n34\n' ;;
  '-s FAKE0001 shell getprop'*) printf 'Pixel Fake\n\n\n\n\n\n' ;;
  "-s FAKE0001 shell input 'keyevent' '3'") ;;
  *) exit 1 ;;
esac
FAKE
# No simulator, and a devicectl that fails, so the iOS listing shows up in errors (smoke 2.1's fakes).
printf '#!/bin/sh\necho %s\n' "'{\"devices\":{}}'" > "$tmp/dev/usr/bin/simctl"
printf '#!/bin/sh\necho boom >&2\nexit 1\n' > "$tmp/dev/usr/bin/devicectl"
chmod 755 "$tmp/sdk/platform-tools/adb" "$tmp/dev/usr/bin/simctl" "$tmp/dev/usr/bin/devicectl"

if [ "$(uname)" = Darwin ]; then
  manager='brew install --cask android-platform-tools, or '
  none='no device found. Start an emulator (emulator -avd <name>), connect a phone with USB debugging on, or boot a simulator (xcrun simctl boot <name>; on Xcode 26 and older, open -a Simulator also boots one).'
else
  manager=
  none='no device found. Start an emulator (emulator -avd <name>) or connect a phone with USB debugging on.'
fi
hint="Install platform-tools (${manager}download https://developer.android.com/tools/releases/platform-tools and add it to PATH) or set ANDROID_HOME to your Android SDK."

# Runs `node dist/cli.js` with the arguments in a fresh environment, with the fakes and the VAR=value pairs in $extra.
sdk=$tmp/sdk
run() { env -i HOME="$tmp/home" PATH="$tmp/empty" ANDROID_HOME="$sdk" DEVELOPER_DIR="$tmp/dev" TERM=xterm-256color $extra "$node_bin" dist/cli.js "$@"; }
# The same under a pseudo-terminal, with script's ^D echo and the terminal's \r taken out.
tty() {
  if [ "$(uname)" = Darwin ]; then
    env -i HOME="$tmp/home" PATH="$tmp/empty" ANDROID_HOME="$sdk" DEVELOPER_DIR="$tmp/dev" TERM=xterm-256color $extra \
      /usr/bin/script -q /dev/null "$node_bin" dist/cli.js "$@" < /dev/null
  else
    env -i HOME="$tmp/home" PATH="$tmp/empty" ANDROID_HOME="$sdk" DEVELOPER_DIR="$tmp/dev" TERM=xterm-256color $extra \
      /usr/bin/script -qec "$node_bin dist/cli.js $*" /dev/null < /dev/null
  fi | node -e 'process.stdout.write(require("fs").readFileSync(0, "utf8").replace(/^\^D\x08\x08/, "").replace(/\r/g, ""))'
}
# Runs the arguments under a pseudo-terminal with stderr dropped, which the terminal would mix into stdout. Sets $st to
# the exit code and $got to stdout without script's ^D echo and \r.
tty_err() {
  if [ "$(uname)" = Darwin ]; then
    raw=$(env -i HOME="$tmp/home" PATH="$tmp/empty" ANDROID_HOME="$sdk" DEVELOPER_DIR="$tmp/dev" TERM=xterm-256color \
      /usr/bin/script -q /dev/null /bin/sh -c 'exec "$@" 2>/dev/null' sh "$node_bin" dist/cli.js "$@" < /dev/null) && st=0 || st=$?
  else
    raw=$(env -i HOME="$tmp/home" PATH="$tmp/empty" ANDROID_HOME="$sdk" DEVELOPER_DIR="$tmp/dev" TERM=xterm-256color \
      /usr/bin/script -qec "$node_bin dist/cli.js $* 2>/dev/null" /dev/null < /dev/null) && st=0 || st=$?
  fi
  got=$(printf '%s' "$raw" | node -e 'process.stdout.write(require("fs").readFileSync(0, "utf8").replace(/^\^D\x08\x08/, "").replace(/\r/g, ""))')
}
# Fails unless $got is exactly $2. $1: the case. printf, not echo: this machine's sh echo expands backslashes (K9).
is() { [ "$got" = "$2" ] || { printf 'FAIL: %s: expected:\n%s\ngot:\n%s\n' "$1" "$2" "$got"; exit 1; }; }

# 1. Piped: one JSON line, as before.
extra=
got=$(run devices | node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { const { devices } = JSON.parse(out); console.log(out.includes("\n") ? "not-one-line" : devices.length) } catch { console.log("not-json") }
')
is 'piped devices' 2

# 2. doctor at a terminal, without colors: only what is wrong under a section, and the summary last. The fake
# DEVELOPER_DIR has no swiftc, so on macOS Xcode is broken.
extra=NO_COLOR=1
out=$(tty doctor)
got=$(printf '%s\n' "$out" | head -1)
is doctor '[✓] adb 37.0.1-15733141 from ANDROID_HOME'
got=$(printf '%s\n' "$out" | tail -1)
if [ "$(uname)" = Darwin ]; then
  is 'doctor summary' '! Doctor found issues in 2 categories.'
  got=$(printf '%s\n' "$out" | grep -c -e '^\[✗\] Xcode ' -e '^\[✗\] iPhone$' -e '^    ✗ swiftc: ')
  is 'doctor sections' 3
else
  is 'doctor summary' '• No issues found!'
fi

# 3. No adb: a red section with the install text under it.
sdk=$tmp/empty
got=$(tty doctor | head -2)
is 'no adb' "[✗] adb not found
    ✗ $hint"
sdk=$tmp/sdk

# 4. devices at a terminal: aligned columns, the OS, the unusable state with its hint, the failed listing, the footer.
out=$(tty devices)
got=$(printf '%s\n' "$out" | head -4)
is devices "Found 2 devices:
  Pixel Fake • FAKE0001 • physical • Android 14 (API 34) • device
  (no name)  • FAKE0002 • physical • Android             • unauthorized
      ! Accept the USB debugging prompt on the device."
got=$(printf '%s\n' "$out" | tail -2)
is 'devices footer' 'Pick one with --device <id or name>, or set KARAGOZ_DEVICE.
Missing a device? Run karagoz doctor.'
if [ "$(uname)" = Darwin ]; then
  # A prefix match, not cut -c: under a C locale cut counts bytes, and ✗ is three.
  got=$(printf '%s\n' "$out" | sed -n 5p)
  case $got in '✗ ios: DEVICECTL_FAILED: '*) got=ok ;; esac
  is 'devices errors' ok
fi
extra='NO_COLOR=1 EMPTY=1'
got=$(tty devices | head -1)
is 'no devices' "$none"

# 5. Any other command at a terminal: the piped line, indented.
extra=
line=$(run key HOME --device FAKE0001)
got=$(tty key HOME --device FAKE0001)
is 'indented json' "$(printf '%s' "$line" | node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(0, "utf8")), null, 2))')"

# 6. An error at a terminal is the one-line envelope with exit 1, not indented (AGENTS.md error contract).
tty_err tap
[ "$st" -ne 0 ] || { echo "FAIL: tap with no arguments exited 0 at a terminal: $got"; exit 1; }
got=$(printf '%s' "$got" | node -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
')
is 'error at a terminal' INVALID_ARGS

# 7. Colors at a terminal, none with NO_COLOR (step 2).
got=$(tty doctor | head -1)
is color "[$(printf '\033[32m✓\033[39m')] adb 37.0.1-15733141 from ANDROID_HOME"

echo "ok: piped line, doctor text, no adb, devices text, no devices, indented json, error envelope, colors"
