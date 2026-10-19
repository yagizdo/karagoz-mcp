#!/bin/sh
# Step 4.3: on macOS `install-runner` builds karagoz's XCUITest runner with the team Xcode lists (or --team) and
# installs it with devicectl, `uninstall-runner` removes every runner and only the profiles made for them, and both
# refuse a simulator or an Android device before any readiness check. `ui-tree` on a paired iPhone asks the runner over
# usbmux, starts an installed runner with xcodebuild test-without-building once under a lock when nothing answers,
# refuses to start one that is not installed, maps its raw snapshot to K34's tree in pixels, and maps every start and
# read failure to its code (K41). Each start puts a fresh secret in a 0600 file and a 0600 copy of the build's
# .xctestrun, never on xcodebuild's command line; every request and answer is signed with it, and an older runner, a
# stranger, a squatter, a listener that never answers and a taken port each get their own refusal (K42).
# Precondition: macOS. Fake adb, simctl, devicectl and xcodebuild come through ANDROID_HOME and DEVELOPER_DIR under
# env -i, Xcode's preferences through a fake HOME, usbmuxd through USBMUXD_SOCKET_ADDRESS (a fake daemon forwarding to
# a fake runner). The real step reads a paired iPhone's tree when `karagoz devices` lists one whose runner is installed,
# else it prints SKIP; its tree is never printed.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iPhones need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; [ -n "$daemon" ] && { kill "$daemon"; wait "$daemon"; } 2>/dev/null; pkill -f "sleep 97\\.43"; pkill -f "runner.cjs $tmp/fake"; rm -rf "$tmp"' EXIT
daemon=
fail() { echo "FAIL: $*"; exit 1; }
is() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; }
code_of() { "$node_bin" -e '
  const out = require("fs").readFileSync(0, "utf8").trimEnd();
  try { console.log(out.includes("\n") ? "not-one-line" : JSON.parse(out).error.code) } catch { console.log("not-json") }
'; }
message_of() { "$node_bin" -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).error.message)'; }

# Fakes. Scripts call /bin tools by absolute path: env -i leaves no PATH for them. Files under $fake steer them.
fake="$tmp/fake"
fixtures=$(pwd)/smoke/fixtures/runner
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
  "device info displays --device "*" --json-output - -q") /bin/cat "$fake/displays.json" ;;
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
    /bin/cp "$fixtures/KaragozRunner.xctestrun" "\$dd/Build/Products/KaragozRunner_iphoneos27.1-arm64.xctestrun"
    ;;
  *test-without-building*)
    while [ \$# -gt 0 ]; do [ "\$1" = -xctestrun ] && xr=\$2; shift; done
    case "\$(/bin/cat "$fake/start")" in
      ok) "$node_bin" "$fixtures/runner.cjs" "$fake" "\$xr" & exec /bin/sleep 97.43 ;;
      hang) /bin/sleep 97.43 & exec /bin/sleep 97.43 ;;
      wait) /bin/cat "$fake/start-text"; exec /bin/sleep 97.43 ;;
      *) /bin/cat "$fake/start-text"; exit 65 ;;
    esac
    ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb" "$dev/usr/bin/simctl" "$dev/usr/bin/devicectl" "$dev/usr/bin/xcodebuild"
printf 'List of devices attached\n\n' > "$fake/adb-devices"
echo '{"devices":{}}' > "$fake/sims.json"
printf 'echo %s\n' "'{\"result\":{\"apps\":[]}}'" > "$fake/apps"
: > "$fake/install"
echo '{"result":{"configurationProfiles":[],"provisioningProfiles":[]}}' > "$fake/profiles.json"
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
# An Apple account signed in to Xcode that has not saved its teams yet: what Xcode writes at sign-in (measured).
account_only() {
  echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>DVTDeveloperAccountManagerAppleIDLists</key><dict><key>IDE.Identifiers.Prod</key><array><dict><key>identifier</key><string>someone</string></dict></array></dict></dict></plist>' > "$tmp/home/Library/Preferences/com.apple.dt.Xcode.plist"
}
k() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$dev" USBMUXD_SOCKET_ADDRESS="UNIX:$tmp/usbmuxd" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
refuses() {
  step=$1 code=$2 text=$3
  shift 3
  if out=$(k "$@"); then fail "$step exited 0: $out"; fi
  is "$step" "$(printf '%s' "$out" | code_of)" "$code"
  [ "$text" = - ] || case "$(printf '%s' "$out" | message_of)" in *"$text"*) ;; *) fail "$step text: $out" ;; esac
}

# 1. Teams. No account: the message says where to sign in; an account whose teams Xcode has not saved: how to make it. One: it builds and installs. Two free: refused with both.
# One paid and one free: the paid. A malformed --team is refused; a well-formed one is used even when Xcode lists none.
refuses "no account" HELPER_FAILED "sign in to Xcode > Settings > Accounts" install-runner --device P1
account_only
refuses "account, no team yet" HELPER_FAILED "Signing & Capabilities tab in Xcode once, or pass --team" install-runner --device P1
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
{"result":{"configurationProfiles":[],"provisioningProfiles":[
{"uuid":"11111111-1111-1111-1111-111111111111","name":"iOS Team Provisioning Profile: com.karagozmcp.runner.abcde12345.xctrunner","appIdentifier":"ABCDE12345.com.karagozmcp.runner.abcde12345.xctrunner","hasExpired":false},
{"uuid":"22222222-2222-2222-2222-222222222222","name":"iOS Team Provisioning Profile: *","appIdentifier":"ABCDE12345.*","hasExpired":false},
{"uuid":"33333333-3333-3333-3333-333333333333","name":"Another app","appIdentifier":"ABCDE12345.com.example.app","hasExpired":false}]}}
JSON
out=$(k uninstall-runner --device P1) || fail "uninstall exited non-zero: $out"
is "uninstall" "$out" '{"device":"P1","apps":["com.karagozmcp.runner.abcde12345.xctrunner","com.karagozmcp.runner.ccccc33333.xctrunner"],"profiles":["11111111-1111-1111-1111-111111111111"]}'
is "uninstalled apps" "$(/usr/bin/tr '\n' ' ' < "$fake/uninstalls")" "com.karagozmcp.runner.abcde12345.xctrunner com.karagozmcp.runner.ccccc33333.xctrunner "
is "removed profiles" "$(/bin/cat "$fake/removed")" 11111111-1111-1111-1111-111111111111
printf 'echo %s\n' "'{\"result\":{\"apps\":[]}}'" > "$fake/apps"
echo '{"result":{"configurationProfiles":[],"provisioningProfiles":[]}}' > "$fake/profiles.json"
out=$(k uninstall-runner --device P1) || fail "uninstall of nothing exited non-zero: $out"
is "uninstall of nothing" "$out" '{"device":"P1","apps":[],"profiles":[]}'


# 5. ui-tree, through the fake usbmuxd and the fake runner in smoke/fixtures/runner/ (their headers say what steers
# them).
"$node_bin" "$fixtures/usbmuxd.cjs" "$tmp/usbmuxd" "$fake" &
daemon=$!
echo P1 > "$fake/usb"
: > "$fake/connects"
echo ok > "$fake/start"
display() { echo "{\"result\":{\"displays\":[{\"primary\":true,\"pointScale\":3,\"currentOrientation\":\"$1\",\"nativeSize\":[$2]}]}}" > "$fake/displays.json"; }
display rot0 1290,2796
runner_installed() { printf 'echo %s\n' "'{\"result\":{\"apps\":[{\"bundleIdentifier\":\"com.karagozmcp.runner.$1.xctrunner\"}]}}'" > "$fake/apps"; }
runner_installed abcde12345
stop_runner() { pkill -f "runner.cjs $fake"; pkill -f "sleep 97\.43"; rm -f "$fake/runner-port"; while pgrep -f "runner.cjs $fake" > /dev/null; do sleep 0.1; done; }
starts() { /usr/bin/grep -c test-without-building "$fake/xcodebuild" || true; }
cat > "$fake/tree.json" <<'JSON'
{"root":{"type":2,"label":"Probe","frame":[0,0,430,932],"children":[{"type":1,"frame":[0,0,430,932],"children":[
{"type":48,"label":"Title","heading":true,"frame":[16,60,200,40]},
{"type":48,"label":"Body","frame":[16,110,200,20.5]},
{"type":41,"label":"Wi-Fi","value":"1","frame":[16,140,398,44]},
{"type":49,"placeholder":"Search","focused":true,"frame":[16,190,398,36]},
{"type":9,"label":"Delete","identifier":"delete","enabled":false,"selected":true,"frame":[16,230,100,44]},
{"type":99,"frame":[0,0,1,1]}]}]}}
JSON
want='{"device":"P1","rotation":0,"root":{"role":"Application","label":"Probe","bounds":[0,0,1290,2796],"children":[{"role":"Group","bounds":[0,0,1290,2796],"children":[{"role":"Heading","label":"Title","bounds":[48,180,648,300]},{"role":"StaticText","label":"Body","bounds":[48,330,648,391.5]},{"role":"Switch","label":"Wi-Fi","value":"1","bounds":[48,420,1242,552]},{"role":"TextField","value":"Search","focused":true,"bounds":[48,570,1242,678]},{"role":"Button","label":"Delete","identifier":"delete","selected":true,"enabled":false,"bounds":[48,690,348,822]},{"role":"Element99","bounds":[0,0,3,3]}]}]}}'
before=$(starts)
out=$(k ui-tree --device P1) || fail "cold start exited non-zero: $out"
is "cold start, mapping" "$out" "$want"
is "cold start: one xcodebuild" "$(starts)" $((before + 1))
args=$(/usr/bin/grep test-without-building "$fake/xcodebuild" | /usr/bin/tail -1)
for wanted in "-destination id=P1" "-only-testing:KaragozRunner/Runner/testServe" "-test-timeouts-enabled NO" "/ABCDE12345/Build/Products/session-P1.xctestrun"; do
  case "$args" in *"$wanted"*) ;; *) fail "start arguments lack '$wanted': $args" ;; esac
done
# The secret: 64 hex characters in a 0600 file, added to a 0600 copy of the build's .xctestrun inside
# EnvironmentVariables only, on no command line; the build's own file is untouched.
secret=$tmp/home/Library/Caches/karagoz/runner/P1.token
products=$(dirname "$(/usr/bin/find "$tmp/home/Library/Caches/karagoz/runner" -path '*/ABCDE12345/Build/Products/session-P1.xctestrun')")
is "secret mode" "$(/usr/bin/stat -f %Lp "$secret")" 600
/usr/bin/grep -Eqx '[0-9a-f]{64}' "$secret" || fail "the secret is not 64 hex characters"
is "session copy mode" "$(/usr/bin/stat -f %Lp "$products/session-P1.xctestrun")" 600
is "secret in EnvironmentVariables" "$("$node_bin" -e '
  const fs = require("fs"), [copy, secret] = process.argv.slice(1);
  const env = /<key>EnvironmentVariables<\/key>\s*<dict>([\s\S]*?)<\/dict>/.exec(fs.readFileSync(copy, "utf8"))[1];
  const text = fs.readFileSync(copy, "utf8");
  console.log(env.includes(`<key>KARAGOZ_TOKEN</key><string>${fs.readFileSync(secret, "utf8")}</string>`) && text.split("KARAGOZ_TOKEN").length === 2);
' "$products/session-P1.xctestrun" "$secret")" true
/usr/bin/cmp -s "$products/KaragozRunner_iphoneos27.1-arm64.xctestrun" "$fixtures/KaragozRunner.xctestrun" || fail "the build's .xctestrun changed"
! /usr/bin/grep -q -F -f "$secret" "$fake/xcodebuild" || fail "the secret is on xcodebuild's command line"
[ ! -s "$fake/refused" ] || fail "the runner refused karagoz's own requests: $(/bin/cat "$fake/refused")"
is "runner port" "$(/usr/bin/sort -u "$fake/connects")" 27753
out=$(k ui-tree --device P1) || fail "warm read exited non-zero: $out"
is "warm read: no second start" "$(starts)" $((before + 1))
display rot90 1080,2340
out=$(k ui-tree --device P1) || fail "mini exited non-zero: $out"
is "mini and rotation" "$(printf '%s' "$out" | "$node_bin" -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(r.rotation, JSON.stringify(r.root.bounds))')" "270 [0,0,1238.4,2684.16]"
# In landscape the keyboard comes in the portrait panel's points (measured); it is turned into the screen.
cp "$fake/tree.json" "$tmp/tree.portrait.json"
cat > "$fake/tree.json" <<'JSON'
{"root":{"type":2,"label":"Probe","frame":[0,0,932,430],"children":[{"type":4,"frame":[0,0,932,430],"children":[
{"type":19,"frame":[266,117,162,698],"children":[{"type":20,"label":"q","frame":[266,117,40,60]}]}]}]}}
JSON
display rot90 1290,2796
out=$(k ui-tree --device P1) || fail "landscape keyboard exited non-zero: $out"
is "landscape keyboard" "$out" '{"device":"P1","rotation":270,"root":{"role":"Application","label":"Probe","bounds":[0,0,2796,1290],"children":[{"role":"Window","bounds":[0,0,2796,1290],"children":[{"role":"Keyboard","bounds":[351,798,2445,1284],"children":[{"role":"Key","label":"q","bounds":[2265,798,2445,918]}]}]}]}}'
cp "$tmp/tree.portrait.json" "$fake/tree.json"
display rot0 1290,2796

# Read failures from a running runner.
for m in snapshot:CAPTURE_FAILED:kAXErrorIllegalArgument private:HELPER_FAILED:"update karagoz" close:CAPTURE_FAILED:"closed the connection" \
  old:RUNNER_NOT_INSTALLED:"is an older version on iPhone P1. Install it with 'karagoz install-runner --device P1'" \
  stranger:DEVICE_NOT_READY:"answers on karagoz's port 27753" squatter:DEVICE_NOT_READY:"answers on karagoz's port 27753"; do
  echo "${m%%:*}" > "$fake/runner-mode"
  rest=${m#*:}
  refuses "runner ${m%%:*}" "${rest%%:*}" "${rest#*:}" ui-tree --device P1
done
# A 4.3 runner on a Mac that never had a secret is still the older runner; a listener that accepts and never answers
# is not ours, and no start replaces the secret of a runner that may only be slow.
echo old > "$fake/runner-mode"
mv "$secret" "$tmp/secret.saved"
refuses "older runner, no secret here" RUNNER_NOT_INSTALLED "is an older version" ui-tree --device P1
mv "$tmp/secret.saved" "$secret"
echo mute > "$fake/runner-mode"
before=$(starts)
refuses "listener never answers" DEVICE_NOT_READY "answers on karagoz's port 27753" ui-tree --device P1
is "listener never answers: no start" "$(starts)" "$before"
rm -f "$fake/refused"
echo hang > "$fake/runner-mode"
t0=$(date +%s)
refuses "runner hangs" CAPTURE_FAILED "did not answer within 30 s" ui-tree --device P1
[ $(($(date +%s) - t0)) -le 40 ] || fail "hang took $(($(date +%s) - t0)) s"
rm "$fake/runner-mode"

# Not attached by cable (no entry, a Wi-Fi entry only, or gone before Connect); usbmuxd's serial matches in any case.
# Then a stopped runner: not installed, or installed without a build here, never starts one.
: > "$fake/usb"
refuses "not on USB" DEVICE_NOT_READY "USB" ui-tree --device P1
echo P1:Network > "$fake/usb"
refuses "Wi-Fi only" DEVICE_NOT_READY "USB" ui-tree --device P1
echo p1 > "$fake/usb"
out=$(k ui-tree --device P1) || fail "lowercase serial exited non-zero: $out"
is "lowercase serial" "$out" "$want"
: > "$fake/gone"
refuses "gone before Connect" DEVICE_NOT_READY "USB" ui-tree --device P1
rm "$fake/gone"
echo P1 > "$fake/usb"
stop_runner
before=$(starts)
printf 'echo %s\n' "'{\"result\":{\"apps\":[]}}'" > "$fake/apps"
refuses "not installed" RUNNER_NOT_INSTALLED "'karagoz install-runner --device P1' (MCP: install_runner)" ui-tree --device P1
runner_installed fffff66666
refuses "no build here" RUNNER_NOT_INSTALLED "built by another karagoz or Xcode" ui-tree --device P1
is "never started" "$(starts)" "$before"
runner_installed abcde12345

# Start failures by xcodebuild's text; a start that never answers is killed with its process group.
echo text > "$fake/start"
echo "Error Domain=com.apple.dt.CoreDeviceError Code=3002 (0xe8008012 (This provisioning profile cannot be installed on this device.))" > "$fake/start-text"
refuses "profile lacks the phone" RUNNER_NOT_INSTALLED "signed for other phones" ui-tree --device P1
echo "The application could not be launched because its profile has not been explicitly trusted by the user." > "$fake/start-text"
refuses "untrusted developer" DEVICE_NOT_READY "VPN & Device Management" ui-tree --device P1
echo "cannot listen on 127.0.0.1:27753: Address already in use" > "$fake/start-text"
refuses "port taken" DEVICE_NOT_READY "holds karagoz's port 27753" ui-tree --device P1
echo "xcodebuild: error: Something unexpected happened." > "$fake/start-text"
refuses "unknown start failure" HELPER_FAILED "Something unexpected happened. (log: " ui-tree --device P1
for m in "The provisioning profile has expired.|RUNNER_NOT_INSTALLED|expired provisioning profile" \
  "Developer Mode disabled.|DEVICE_NOT_READY|Developer Mode is off" \
  "The device is locked.|DEVICE_NOT_READY|it is locked" \
  "Enable automation mode failed.|DEVICE_NOT_READY|UI automation is off"; do
  echo "${m%%|*}" > "$fake/start-text"
  rest=${m#*|}
  refuses "start: ${m%%|*}" "${rest%%|*}" "${rest#*|}" ui-tree --device P1
done
# A locked iPhone: xcodebuild says so and waits for it without exiting (measured); the start ends at once.
echo wait > "$fake/start"
printf '%s\n' 'Run Destination Preflight: The destination is not ready.' \
  'Error Domain=com.apple.dt.deviceprep Code=-3 "Unlock iPhone to Continue" UserInfo={NSLocalizedRecoverySuggestion=Xcode cannot launch KaragozRunner on iPhone because the device is locked.}' \
  'Run Destination Preflight: Waiting for the destination to become ready.' > "$fake/start-text"
t0=$(date +%s)
refuses "start on a locked iPhone" DEVICE_NOT_READY "it is locked" ui-tree --device P1
[ $(($(date +%s) - t0)) -le 10 ] || fail "the locked start took $(($(date +%s) - t0)) s"
sleep 1
! pgrep -f "sleep 97\.43" > /dev/null || fail "the waiting xcodebuild was left running"
echo hang > "$fake/start"
t0=$(date +%s)
refuses "start never answers" DEVICE_NOT_READY "did not start within 60 s" ui-tree --device P1
[ $(($(date +%s) - t0)) -le 75 ] || fail "start budget took $(($(date +%s) - t0)) s"
sleep 1
! pgrep -f "sleep 97\.43" > /dev/null || fail "the hung xcodebuild was left running"
# The MCP server exits right after aborting on SIGTERM, before any catch runs: the abort itself kills the start.
mcp_term=$(env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$dev" \
  USBMUXD_SOCKET_ADDRESS="UNIX:$tmp/usbmuxd" "$node_bin" -e '
  const { spawn, spawnSync } = require("child_process");
  const server = spawn(process.execPath, ["dist/cli.js", "mcp"], { stdio: ["pipe", "pipe", "ignore"] });
  const send = (m) => server.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
  send({ id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "smoke", version: "0" } } });
  server.stdout.once("data", () => {
    send({ method: "notifications/initialized" });
    send({ id: 2, method: "tools/call", params: { name: "ui_tree", arguments: { device: "P1" } } });
  });
  const sleeping = () => spawnSync("/usr/bin/pgrep", ["-f", "sleep 97\\.43"]).status === 0;
  const giveUp = setTimeout(() => { clearInterval(poll); console.log("no start"); server.kill("SIGKILL"); }, 15000);
  const poll = setInterval(() => { if (sleeping()) { clearInterval(poll); clearTimeout(giveUp); server.kill("SIGTERM"); } }, 100);
  server.on("exit", (code) => setTimeout(() => console.log(code, sleeping() ? "left" : "gone"), 1000));
')
is "MCP SIGTERM during a start" "$mcp_term" "143 gone"
# The CLI too: the start has left its process group, so only the abort reaches it.
env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$dev" \
  USBMUXD_SOCKET_ADDRESS="UNIX:$tmp/usbmuxd" "$node_bin" dist/cli.js ui-tree --device P1 > /dev/null 2>&1 &
cli=$!
i=0
until pgrep -f "sleep 97\.43" > /dev/null; do i=$((i + 1)); [ $i -le 150 ] || fail "CLI start: no xcodebuild"; sleep 0.1; done
code=0
kill -TERM "$cli"
wait "$cli" || code=$?
sleep 1
is "CLI SIGTERM during a start" "$code $(pgrep -f "sleep 97\.43" > /dev/null && echo left || echo gone)" "143 gone"

# Two first calls at once start one runner.
echo ok > "$fake/start"
before=$(starts)
k ui-tree --device P1 > "$tmp/first" & first=$!
k ui-tree --device P1 > "$tmp/second" & second=$!
wait $first || fail "first concurrent call failed: $(/bin/cat "$tmp/first")"
wait $second || fail "second concurrent call failed: $(/bin/cat "$tmp/second")"
is "concurrent: one start" "$(starts)" $((before + 1))
is "concurrent: same tree" "$(/bin/cat "$tmp/second")" "$want"
refuses "other commands" NOT_SUPPORTED "runs only screenshot, ui-tree, tap, swipe, text, key, install-runner and uninstall-runner" launch com.example --device P1
stop_runner

# 6. devices: iPhone rows end in runner. doctor: signing from Xcode's teams, iosRunner from the builds section 1 made.
runner_of() { k devices | "$node_bin" -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(r.devices.filter((d) => d.kind === "physical").map((d) => d.id + "=" + d.runner).join(" "))'; }
k ui-tree --device P1 > /dev/null || fail "ui-tree before devices failed"
is "devices, running" "$(runner_of)" "P1=running P2=null"
stop_runner
is "devices, installed" "$(runner_of)" "P1=installed P2=null"
printf 'echo %s\n' "'{\"result\":{\"apps\":[]}}'" > "$fake/apps"
is "devices, not installed" "$(runner_of)" "P1=not installed P2=null"
printf 'exit 1\n' > "$fake/apps"
is "devices, devicectl failing" "$(runner_of)" "P1=null P2=null"
runner_installed abcde12345
doctor_of() { k doctor | "$node_bin" -e 'const x = JSON.parse(require("fs").readFileSync(0, "utf8")).xcode; console.log(JSON.stringify([x.signing, x.iosRunner]).replace(/runner\/[0-9a-f]{16}/g, "runner/KEY"))'; }
teams 'ABCDE12345:Some Team:false' 'AAAAA11111:Me:true'
is "doctor" "$(doctor_of)" "[{\"status\":\"ok\",\"teams\":[{\"id\":\"ABCDE12345\",\"name\":\"Some Team\",\"free\":false},{\"id\":\"AAAAA11111\",\"name\":\"Me\",\"free\":true}]},{\"status\":\"ok\",\"path\":\"$tmp/home/Library/Caches/karagoz/runner/KEY\",\"teams\":[\"ABCDE12345\",\"CCCCC33333\",\"DDDDD44444\"]}]"
rm "$tmp/home/Library/Preferences/com.apple.dt.Xcode.plist"
rm -rf "$tmp/home/Library/Caches/karagoz/runner"
is "doctor, nothing yet" "$(doctor_of)" "[{\"status\":\"missing\",\"message\":\"Xcode lists no Apple account: sign in to Xcode > Settings > Accounts with your Apple ID, to build karagoz's iPhone runner with install-runner\"},{\"status\":\"not built\",\"path\":\"$tmp/home/Library/Caches/karagoz/runner/KEY\"}]"

# 7. A real paired iPhone with karagoz's runner: the tree's shape only, nothing from the screen is printed. Real tools,
# the real HOME (where install-runner built the runner), a fake adb that lists nothing.
real() { env -i HOME="$HOME" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
phone=$(real devices | "$node_bin" -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  console.log(r.devices.find((d) => d.kind === "physical" && d.state === "paired" && (d.runner === "running" || d.runner === "installed"))?.id ?? "");
')
if [ -z "$phone" ]; then
  echo "SKIP: no paired iPhone with karagoz's runner"
  real_ok="real skipped"
else
  out=$(real ui-tree --device "$phone") || fail "real ui-tree exited non-zero: $(printf '%s' "$out" | code_of)"
  real_ok=$(printf '%s' "$out" | "$node_bin" -e '
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    let nodes = 0, bad = 0;
    const walk = (n) => { nodes++; if (!Array.isArray(n.bounds) || n.bounds.length !== 4 || !n.bounds.every(Number.isFinite) || typeof n.role !== "string") bad++; (n.children ?? []).forEach(walk); };
    walk(r.root);
    const rotation = r.rotation === null || [0, 90, 180, 270].includes(r.rotation);
    console.log(r.root.role === "Application" && rotation && !bad ? `real ${nodes} nodes, rotation ${r.rotation}` : `bad: root ${r.root.role}, rotation ${r.rotation}, ${bad} bad nodes`);
  ')
  case "$real_ok" in real*) ;; *) fail "real tree: $real_ok" ;; esac
fi

echo "ok: $real_ok, teams, build arguments, failures, targets, uninstall, mapping, mini, read failures, not on USB, Wi-Fi only, serial case, gone before Connect, not installed, start failures, start budget (60s), MCP and CLI SIGTERM during a start, lock, devices, doctor, landscape keyboard, secret, signatures, older runner, stranger, squatter, mute listener, port taken, locked start"
