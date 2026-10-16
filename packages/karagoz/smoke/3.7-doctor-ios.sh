#!/bin/sh
# Step 3.7: on macOS `doctor` adds an `xcode` report: the developer dir the iOS commands use, its version, and one entry
# each for simctl, swiftc, devicectl and the ui-tree helper cache, with the commands' own paths and messages (K30).
# Fake Xcode trees prove every status, the first-launch check and the helper states; recording fakes and a scratch HOME
# prove doctor starts no Xcode tool and creates no cache, and that the adb object never changes.
# Precondition: macOS with Xcode. No simulator needed; the real Xcode is only read.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: the xcode report is macOS only"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# doctor under env -i with a scratch HOME and only the VAR=value pairs given. Sets $x to the xcode object with the
# helper's cache key as KEY, $hp to the helper's real path (or empty), and checks the adb object against case a's.
doc() {
  out=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin ANDROID_HOME="$tmp/sdk" CALLS="$tmp/calls" "$@" \
    "$node_bin" dist/cli.js doctor 2>/dev/null) || fail "doctor $* exited non-zero: $out"
  parsed=$(printf '%s' "$out" | node -e '
    const out = require("fs").readFileSync(0, "utf8").trimEnd();
    if (out.includes("\n")) { console.log("not-one-line"); process.exit(); }
    const o = JSON.parse(out);
    console.log(o.xcode ? JSON.stringify(o.xcode).replace(/karagoz\/[0-9a-f]{16}\//g, "karagoz/KEY/").replace(/runner\/[0-9a-f]{16}/g, "runner/KEY") : "no xcode key");
    console.log(o.xcode?.helper?.path ?? "");
    console.log(JSON.stringify(o.adb));
  ') || fail "doctor $* printed no JSON: $out"
  x=$(printf '%s\n' "$parsed" | sed -n 1p)
  hp=$(printf '%s\n' "$parsed" | sed -n 2p)
  a=$(printf '%s\n' "$parsed" | sed -n 3p)
  [ -n "$adb" ] || adb=$a
  [ "$a" = "$adb" ] || fail "adb object changed with $*: $a"
}
# printf, not echo: this machine's sh echo expands backslashes (K9).
is() { [ "$x" = "$2" ] || { printf 'FAIL: %s: expected %s, got: %s\n' "$1" "$2" "$x"; exit 1; }; }

framework=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources
coredevice=/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl
fw=$(/usr/bin/plutil -extract CFBundleVersion raw "$framework/Info.plist")
newer=$(printf '%s' "$fw" | awk -F. -v OFS=. '{ $NF = $NF + 1; print }')
helper_path=$tmp/home/Library/Caches/karagoz/KEY/ax
# No Apple account under the fake HOME; the runner is never built here.
signing_text="Xcode lists no Apple account: sign in to Xcode > Settings > Accounts with your Apple ID, to build karagoz's iPhone runner"
runner_path=$tmp/home/Library/Caches/karagoz/runner/KEY
swiftc_text='the Command Line Tools are not enough'

# Every fake tool only records its argv: doctor must start none of them.
cat > "$tmp/logger" <<'FAKE'
printf '%s\n' "$0 $*" >> "$CALLS"
exit 1
FAKE
# fake <app> <version> <build> <EXPECTED_VERSION>: an Xcode.app with version.plist, a simctl shim, devicectl and swiftc.
fake() {
  dev=$1/Contents/Developer
  bin=$dev/Toolchains/XcodeDefault.xctoolchain/usr/bin
  mkdir -p "$dev/usr/bin" "$bin"
  printf '<plist version="1.0">\n<dict>\n\t<key>CFBundleShortVersionString</key>\n\t<string>%s</string>\n\t<key>ProductBuildVersion</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' \
    "$2" "$3" > "$1/Contents/version.plist"
  { echo '#!/bin/sh'; printf 'EXPECTED_VERSION="%s"\n' "$4"; cat "$tmp/logger"; } > "$dev/usr/bin/simctl"
  { echo '#!/bin/sh'; cat "$tmp/logger"; } > "$dev/usr/bin/devicectl"
  cp "$dev/usr/bin/devicectl" "$bin/swiftc"
  chmod 755 "$dev/usr/bin/simctl" "$dev/usr/bin/devicectl" "$bin/swiftc"
}
# entries <developer dir>: every entry ok and the helper not built, in $sim, $swc, $dctl and $hlp.
entries() {
  sim="{\"status\":\"ok\",\"path\":\"$1/usr/bin/simctl\",\"version\":\"$fw\"}"
  swc="{\"status\":\"ok\",\"path\":\"$1/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc\"}"
  dctl="{\"status\":\"ok\",\"path\":\"$1/usr/bin/devicectl\"}"
  hlp="{\"status\":\"not built\",\"path\":\"$helper_path\"}"
  sgn="{\"status\":\"missing\",\"message\":\"$signing_text\"}"
  rnr="{\"status\":\"not built\",\"path\":\"$runner_path\"}"
}
# top <status> <developer dir> <version> <build> [<message>]: the xcode object under DEVELOPER_DIR with those entries.
top() {
  v=
  [ -z "$3" ] || v=",\"version\":\"$3\",\"build\":\"$4\""
  m=
  [ -z "$5" ] || m=",\"message\":\"$5\""
  printf '{"status":"%s","source":"DEVELOPER_DIR","path":"%s"%s%s,"simctl":%s,"swiftc":%s,"devicectl":%s,"helper":%s,"signing":%s,"iosRunner":%s}' \
    "$1" "$2" "$v" "$m" "$sim" "$swc" "$dctl" "$hlp" "$sgn" "$rnr"
}
devicectl_text() { echo "devicectl not found (tried $1): iPhones are not listed or reachable, and a simulator's rotation reads as null"; }

# a. This Mac, DEVELOPER_DIR unset, against reads that do not go through karagoz.
doc
if [ -e /var/db/xcode_select_link ]; then
  source=xcode-select dev=$(readlink /var/db/xcode_select_link)
else
  source=default dev=/Applications/Xcode.app/Contents/Developer
fi
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$dev/../version.plist")
build=$(/usr/bin/plutil -extract ProductBuildVersion raw "$dev/../version.plist")
status=ok message=
if [ "${version%%.*}" -lt 27 ]; then status=outdated message='tap, swipe and key on a simulator need Xcode 27 or later'; fi
fields=$(printf '%s' "$x" | node -e '
  const o = JSON.parse(require("fs").readFileSync(0, "utf8"));
  console.log([o.status, o.source, o.path, o.version, o.build, o.message, o.simctl.status, o.simctl.path, o.simctl.version,
    o.swiftc.status, o.devicectl.status, o.devicectl.path, o.helper.status, o.helper.path].join("|"));
' 2>/dev/null) || fail "real: no xcode key: $x"
want="$status|$source|$dev|$version|$build|$message|ok|$framework/bin/simctl|$fw|ok|ok|$coredevice|not built|$helper_path"
[ "$fields" = "$want" ] || fail "real: expected $want, got: $x"
[ ! -e "$tmp/home/Library" ] || fail "real: doctor created $tmp/home/Library"
ok="real ($status)"

# b, c. Xcode 27, by its .app, the .app with a slash, and the developer dir.
fake "$tmp/X27.app" 27.0 27A1 "$fw"
d=$tmp/X27.app/Contents/Developer
entries "$d"
for dir in "$tmp/X27.app" "$tmp/X27.app/" "$d"; do
  doc DEVELOPER_DIR="$dir"
  is "ok ($dir)" "$(top ok "$d" 27.0 27A1)"
done
ok="$ok, app, ok"

# d. Xcode 26.
fake "$tmp/X26.app" 26.2 17C52 "$fw"
d=$tmp/X26.app/Contents/Developer
entries "$d"
doc DEVELOPER_DIR="$tmp/X26.app"
is outdated "$(top outdated "$d" 26.2 17C52 'tap, swipe and key on a simulator need Xcode 27 or later')"
ok="$ok, outdated"

# e. First launch pending: the shim expects a newer CoreSimulator than this Mac has.
fake "$tmp/X271.app" 27.1 27B1 "$newer"
d=$tmp/X271.app/Contents/Developer
entries "$d"
first="the selected Xcode expects CoreSimulator $newer, this Mac has $fw: open Xcode once to finish installing its components"
sim="{\"status\":\"failed\",\"path\":\"$d/usr/bin/simctl\",\"version\":\"$fw\",\"message\":\"$first\"}"
doc DEVELOPER_DIR="$tmp/X271.app"
is 'first launch' "$(top failed "$d" 27.1 27B1 "$first")"
ok="$ok, first launch"

# f. Only an older framework counts: a shim expecting an older one is fine.
fake "$tmp/Xf.app" 27.0 27A1 1.0
d=$tmp/Xf.app/Contents/Developer
entries "$d"
doc DEVELOPER_DIR="$tmp/Xf.app"
is newer "$(top ok "$d" 27.0 27A1)"
ok="$ok, newer"

# g. A Command Line Tools-like dir: no simctl, no swiftc, no version.plist.
d=$tmp/clt
mkdir -p "$d/usr/bin"
entries "$d"
missing="simctl not found (tried $d/usr/bin/simctl, from DEVELOPER_DIR). Point DEVELOPER_DIR at an Xcode, not the Command Line Tools, or unset it."
sim="{\"status\":\"missing\",\"path\":\"$d/usr/bin/simctl\",\"message\":\"$missing\"}"
s=$d/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
swc="{\"status\":\"missing\",\"path\":\"$s\",\"message\":\"swiftc not found at $s; install or select an Xcode (xcode-select -s <Xcode.app> or DEVELOPER_DIR), $swiftc_text\"}"
dctl="{\"status\":\"missing\",\"path\":\"$d/usr/bin/devicectl\",\"message\":\"$(devicectl_text "$d/usr/bin/devicectl")\"}"
doc DEVELOPER_DIR="$d"
is clt "$(top missing "$d" '' '' "$missing")"
ok="$ok, clt"

# h. swiftc missing from an Xcode whose simctl is there.
fake "$tmp/Xh.app" 27.0 27A1 "$fw"
d=$tmp/Xh.app/Contents/Developer
s=$d/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
rm "$s"
entries "$d"
text="swiftc not found at $s; install or select an Xcode (xcode-select -s <Xcode.app> or DEVELOPER_DIR), $swiftc_text"
swc="{\"status\":\"missing\",\"path\":\"$s\",\"message\":\"$text\"}"
doc DEVELOPER_DIR="$tmp/Xh.app"
is 'no swiftc' "$(top failed "$d" 27.0 27A1 "$text")"
ok="$ok, no swiftc"

# i. simctl there but not executable.
fake "$tmp/Xi.app" 27.0 27A1 "$fw"
d=$tmp/Xi.app/Contents/Developer
chmod 644 "$d/usr/bin/simctl"
entries "$d"
text="cannot run $d/usr/bin/simctl (EACCES)"
sim="{\"status\":\"failed\",\"path\":\"$d/usr/bin/simctl\",\"version\":\"$fw\",\"message\":\"$text\"}"
doc DEVELOPER_DIR="$tmp/Xi.app"
is 'not executable' "$(top failed "$d" 27.0 27A1 "$text")"
ok="$ok, not executable"

# j. devicectl missing: no iPhones, and rotation would read as null.
fake "$tmp/Xj.app" 27.0 27A1 "$fw"
d=$tmp/Xj.app/Contents/Developer
rm "$d/usr/bin/devicectl"
entries "$d"
text=$(devicectl_text "$d/usr/bin/devicectl")
dctl="{\"status\":\"missing\",\"path\":\"$d/usr/bin/devicectl\",\"message\":\"$text\"}"
doc DEVELOPER_DIR="$tmp/Xj.app"
is 'no devicectl' "$(top failed "$d" 27.0 27A1 "$text")"
ok="$ok, no devicectl"

# k. DEVELOPER_DIR is a file: spawn would fail with ENOTDIR.
d=$tmp/file
: > "$d"
entries "$d"
s=$d/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
sim="{\"status\":\"failed\",\"path\":\"$d/usr/bin/simctl\",\"version\":\"$fw\",\"message\":\"cannot run $d/usr/bin/simctl (ENOTDIR)\"}"
swc="{\"status\":\"failed\",\"path\":\"$s\",\"message\":\"cannot run $s (ENOTDIR)\"}"
dctl="{\"status\":\"failed\",\"path\":\"$d/usr/bin/devicectl\",\"message\":\"cannot run $d/usr/bin/devicectl (ENOTDIR)\"}"
doc DEVELOPER_DIR="$d"
is file "$(top failed "$d" '' '' "cannot run $d/usr/bin/simctl (ENOTDIR)")"
ok="$ok, file"
[ ! -e "$tmp/home/Library" ] || fail "doctor created $tmp/home/Library"

# l. The helper: built once a file sits at its path, failed when the cache root is a file.
d=$tmp/X27.app/Contents/Developer
entries "$d"
doc DEVELOPER_DIR="$tmp/X27.app"
mkdir -p "$(dirname "$hp")"
: > "$hp"
hlp="{\"status\":\"ok\",\"path\":\"$helper_path\"}"
doc DEVELOPER_DIR="$tmp/X27.app"
is 'helper built' "$(top ok "$d" 27.0 27A1)"
rm -rf "$tmp/home/Library/Caches/karagoz"
: > "$tmp/home/Library/Caches/karagoz"
text="$tmp/home/Library/Caches/karagoz is not a directory owned by the current user; delete ~/Library/Caches/karagoz"
hlp="{\"status\":\"failed\",\"path\":\"$helper_path\",\"message\":\"$text\"}"
rnr="{\"status\":\"failed\",\"path\":\"$runner_path\",\"message\":\"cannot check $runner_path (ENOTDIR); delete ~/Library/Caches/karagoz\"}"
doc DEVELOPER_DIR="$tmp/X27.app"
is 'helper failed' "$(top failed "$d" 27.0 27A1 "$text")"
ok="$ok, helper"

# m, n. No fake recorded a call, and doc() compared every adb object with case a's.
[ ! -e "$tmp/calls" ] || fail "doctor ran a tool: $(cat "$tmp/calls")"
echo "ok: $ok, no process, adb"
