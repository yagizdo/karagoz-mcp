#!/bin/sh
# Step 4.3: on macOS `install-runner` builds karagoz's XCUITest runner with the team Xcode lists (or --team) and
# installs it with devicectl, `uninstall-runner` removes every runner and only the profiles made for them, and both
# refuse a simulator or an Android device before any readiness check (K41).
# Precondition: macOS. Fake adb, simctl, devicectl and xcodebuild come through ANDROID_HOME and DEVELOPER_DIR under
# env -i, Xcode's preferences through a fake HOME; no device and no real Xcode build are touched.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iPhones need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
is() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; }
code_of() { "$node_bin" -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them. Files under $fake steer them.
fake="$tmp/fake"
dev="$tmp/Xcode.app/Contents/Developer"
mkdir -p "$tmp/sdk/platform-tools" "$dev/usr/bin" "$tmp/home/Library/Preferences" "$fake"
cat > "$tmp/sdk/platform-tools/adb" <<FAKE
#!/bin/sh
case "\$*" in
  devices) /bin/cat "$fake/adb-devices" ;;
  *) exit 0 ;;
esac
FAKE
cat > "$dev/usr/bin/simctl" <<FAKE
#!/bin/sh
/bin/cat "$fake/sims.json"
FAKE
cat > "$dev/usr/bin/devicectl" <<FAKE
#!/bin/sh
case "\$*" in
  "list devices --json-output - -q") /bin/cat "$fake/list.json" ;;
  "device info apps --device "*" --json-output - -q") exec /bin/sh "$fake/apps" ;;
  "device install app --device "*" -q") echo "\$6" >> "$fake/installs"; exec /bin/sh "$fake/install" ;;
  "device uninstall app --device "*" -q") echo "\$6" >> "$fake/uninstalls" ;;
  "device profile list --device "*" --type provisioning --json-output - -q") /bin/cat "$fake/profiles.json" ;;
  "device profile remove --device "*" -q") echo "\$6" >> "$fake/removed" ;;
  *) exit 1 ;;
esac
FAKE
# build-for-testing logs its arguments and writes the products a real build leaves, unless $fake/build-error says
# what to print and fail with.
cat > "$dev/usr/bin/xcodebuild" <<FAKE
#!/bin/sh
echo "\$*" >> "$fake/xcodebuild"
case "\$*" in
  *build-for-testing*)
    if [ -f "$fake/build-error" ]; then /bin/cat "$fake/build-error"; exit 65; fi
    while [ \$# -gt 0 ]; do [ "\$1" = -derivedDataPath ] && dd=\$2; shift; done
    /bin/mkdir -p "\$dd/Build/Products/Debug-iphoneos/KaragozRunner-Runner.app"
    : > "\$dd/Build/Products/KaragozRunner_iphoneos27.1-arm64.xctestrun"
    ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$dev/usr/bin/simctl" "$dev/usr/bin/devicectl" "$dev/usr/bin/xcodebuild"
printf 'List of devices attached\n\n' > "$fake/adb-devices"
echo '{"devices":{}}' > "$fake/sims.json"
printf 'echo %s\n' "'{\"result\":{\"apps\":[]}}'" > "$fake/apps"
: > "$fake/install"
echo '{"result":{"profiles":[]}}' > "$fake/profiles.json"
phone() { printf '{"visibilityClass":"default","properties":{"hardware":{"udid":"%s","reality":"physical","platform":"iOS","marketingName":"iPhone 14 Pro Max"},"connection":{"pairingState":"%s","transportType":"wired","tunnelState":"disconnected"}}}' "$1" "$2"; }
echo "{\"result\":{\"devices\":[$(phone P1 paired),$(phone P2 unpaired)]}}" > "$fake/list.json"
# teams <account>=<id>:<name>:<free>...: Xcode's IDEProvisioningTeamByIdentifier as an XML plist.
teams() {
  {
    echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>IDEProvisioningTeamByIdentifier</key><dict><key>account-1</key><array>'
    for t in "$@"; do
      id=${t%%:*} rest=${t#*:} name=${rest%%:*} free=${rest#*:}
      echo "<dict><key>isFreeProvisioningTeam</key><$free/><key>teamID</key><string>$id</string><key>teamName</key><string>$name</string></dict>"
    done
    echo '</array></dict></dict></plist>'
  } > "$tmp/home/Library/Preferences/com.apple.dt.Xcode.plist"
}
k() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$dev" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
refuses() {
  step=$1 code=$2 text=$3
  shift 3
  if out=$(k "$@"); then fail "$step exited 0: $out"; fi
  is "$step" "$(printf '%s' "$out" | code_of)" "$code"
  [ "$text" = - ] || case "$(printf '%s' "$out" | message_of)" in *"$text"*) ;; *) fail "$step text: $out" ;; esac
}

# 1. Teams. None listed: the message says where to sign in. One: it builds and installs. Two free: refused with both.
# One paid and one free: the paid. A malformed --team is refused; a well-formed one is used even when Xcode lists none.
refuses "no team" HELPER_FAILED "Xcode > Settings > Accounts" install-runner --device P1
[ ! -e "$fake/xcodebuild" ] || fail "no team: xcodebuild ran"
teams 'ABCDE12345:Some Team:false'
out=$(k install-runner --device P1) || fail "one team exited non-zero: $out"
is "one team" "$out" '{"device":"P1","bundleId":"com.karagozmcp.runner.abcde12345.xctrunner","team":"ABCDE12345"}'
args=$(/usr/bin/tail -1 "$fake/xcodebuild")
for want in "build-for-testing" "-destination id=P1" "-allowProvisioningUpdates" "-allowProvisioningDeviceRegistration" \
  "DEVELOPMENT_TEAM=ABCDE12345" "PRODUCT_BUNDLE_IDENTIFIER=com.karagozmcp.runner.abcde12345" "CODE_SIGN_STYLE=Automatic"; do
  case "$args" in *"$want"*) ;; *) fail "build arguments lack '$want': $args" ;; esac
done
case "$(/usr/bin/tail -1 "$fake/installs")" in */ABCDE12345/Build/Products/Debug-iphoneos/KaragozRunner-Runner.app) ;; *) fail "installed: $(/bin/cat "$fake/installs")" ;; esac
teams 'AAAAA11111:Free One:true' 'BBBBB22222:Free Two:true'
refuses "two free teams" INVALID_ARGS "AAAAA11111 (Free One, free), BBBBB22222 (Free Two, free)" install-runner --device P1
teams 'AAAAA11111:Free:true' 'CCCCC33333:Paid:false'
out=$(k install-runner --device P1) || fail "paid tie-break exited non-zero: $out"
is "paid tie-break" "$(printf '%s' "$out" | "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).team)')" CCCCC33333
refuses "bad --team" INVALID_ARGS "10-character" install-runner --device P1 --team abc
rm "$tmp/home/Library/Preferences/com.apple.dt.Xcode.plist"
out=$(k install-runner --device P1 --team DDDDD44444) || fail "--team without a listed team exited non-zero: $out"

# 2. Failures. A build error carries xcodebuild's error line; devicectl's refusal is INSTALL_FAILED, and its Developer
# Mode text is DEVICE_NOT_READY.
teams 'ABCDE12345:Some Team:false'
echo "error: No Accounts: Add a new account in Accounts settings. (in target 'KaragozRunner' from project 'KaragozRunner')" > "$fake/build-error"
refuses "build error" HELPER_FAILED "No Accounts: Add a new account in Accounts settings." install-runner --device P1
rm "$fake/build-error"
printf 'echo "ERROR: The app could not be installed." >&2; exit 1\n' > "$fake/install"
refuses "install refused" INSTALL_FAILED "could not be installed" install-runner --device P1
printf 'echo "ERROR: Developer Mode is disabled on this device." >&2; exit 1\n' > "$fake/install"
refuses "Developer Mode" DEVICE_NOT_READY "Developer Mode" install-runner --device P1
: > "$fake/install"

# 3. Targets: the unpaired iPhone needs Trust; a simulator, even a booting one, and an Android device are refused first.
refuses "unpaired" DEVICE_NOT_READY "Trust" install-runner --device P2
echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"S1","name":"iPhone 17","state":"Booting","isAvailable":true}]}}' > "$fake/sims.json"
refuses "booting simulator" NOT_SUPPORTED "not an iPhone" install-runner --device S1
printf 'List of devices attached\nemulator-5554\toffline\n\n' > "$fake/adb-devices"
refuses "offline emulator" NOT_SUPPORTED "not an iPhone" uninstall-runner --device emulator-5554
printf 'List of devices attached\n\n' > "$fake/adb-devices"
echo '{"devices":{}}' > "$fake/sims.json"

# 4. Uninstall: every runner app goes, and only the profiles for karagoz's runner ids; a team wildcard stays.
printf 'echo %s\n' "'{\"result\":{\"apps\":[{\"bundleIdentifier\":\"com.karagozmcp.runner.abcde12345.xctrunner\"},{\"bundleIdentifier\":\"com.example.app\"},{\"bundleIdentifier\":\"com.karagozmcp.runner.ccccc33333.xctrunner\"}]}}'" > "$fake/apps"
cat > "$fake/profiles.json" <<'JSON'
{"result":{"profiles":[
{"uuid":"11111111-1111-1111-1111-111111111111","name":"iOS Team Provisioning Profile: com.karagozmcp.runner.abcde12345.xctrunner","entitlements":{"application-identifier":"ABCDE12345.com.karagozmcp.runner.abcde12345.xctrunner"}},
{"uuid":"22222222-2222-2222-2222-222222222222","name":"iOS Team Provisioning Profile: *","entitlements":{"application-identifier":"ABCDE12345.*"}},
{"uuid":"33333333-3333-3333-3333-333333333333","name":"Another app","entitlements":{"application-identifier":"ABCDE12345.com.example.app"}}]}}
JSON
out=$(k uninstall-runner --device P1) || fail "uninstall exited non-zero: $out"
is "uninstall" "$out" '{"device":"P1","apps":["com.karagozmcp.runner.abcde12345.xctrunner","com.karagozmcp.runner.ccccc33333.xctrunner"],"profiles":["11111111-1111-1111-1111-111111111111"]}'
is "uninstalled apps" "$(/usr/bin/tr '\n' ' ' < "$fake/uninstalls")" "com.karagozmcp.runner.abcde12345.xctrunner com.karagozmcp.runner.ccccc33333.xctrunner "
is "removed profiles" "$(/bin/cat "$fake/removed")" 11111111-1111-1111-1111-111111111111
printf 'echo %s\n' "'{\"result\":{\"apps\":[]}}'" > "$fake/apps"
echo '{"result":{"profiles":[]}}' > "$fake/profiles.json"
out=$(k uninstall-runner --device P1) || fail "uninstall of nothing exited non-zero: $out"
is "uninstall of nothing" "$out" '{"device":"P1","apps":[],"profiles":[]}'

echo "ok: teams, build arguments, failures, targets, uninstall"
