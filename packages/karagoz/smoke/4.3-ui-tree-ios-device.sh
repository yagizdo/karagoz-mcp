#!/bin/sh
# Step 4.3: on macOS `install-runner` builds karagoz's XCUITest runner with the team Xcode lists (or --team) and
# installs it with devicectl, `uninstall-runner` removes every runner and only the profiles made for them, and both
# refuse a simulator or an Android device before any readiness check. `ui-tree` on a paired iPhone asks the runner over
# usbmux, starts an installed runner with xcodebuild test-without-building once under a lock when nothing answers,
# refuses to start one that is not installed, maps its raw snapshot to K34's tree in pixels, and maps every start and
# read failure to its code (K41).
# Precondition: macOS. Fake adb, simctl, devicectl and xcodebuild come through ANDROID_HOME and DEVELOPER_DIR under
# env -i, Xcode's preferences through a fake HOME, usbmuxd through USBMUXD_SOCKET_ADDRESS (a fake daemon forwarding to
# a fake runner); no device and no real Xcode build are touched.
set -e
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "SKIP: iPhones need macOS"; echo "ok: skipped"; exit 0; }
npm run --silent build

node_bin=$(command -v node)
tmp=$(mktemp -d)
trap 'set +e; [ -n "$daemon" ] && { kill "$daemon"; wait "$daemon"; } 2>/dev/null; pkill -f "sleep 97\\.43"; pkill -f "$tmp/runner.js"; rm -rf "$tmp"' EXIT
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
    : > "\$dd/Build/Products/KaragozRunner_iphoneos27.1-arm64.xctestrun"
    ;;
  *test-without-building*)
    case "\$(/bin/cat "$fake/start")" in
      ok) "$node_bin" "$tmp/runner.js" "$fake" & exec /bin/sleep 97.43 ;;
      hang) exec /bin/sleep 97.43 ;;
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
k() { env -i HOME="$tmp/home" PATH=/usr/bin:/bin TMPDIR="$tmp" ANDROID_HOME="$tmp/sdk" DEVELOPER_DIR="$dev" USBMUXD_SOCKET_ADDRESS="UNIX:$tmp/usbmuxd" "$node_bin" dist/cli.js "$@" 2>/dev/null; }
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


# 5. ui-tree. A fake usbmuxd lists the phones in $fake/usb and forwards Connect to the fake runner's port, or answers
# 3 (refused) when nothing listens; the fake runner answers /health and /tree as $fake/runner-mode says.
cat > "$tmp/usbmuxd.js" <<'JS'
const net = require("net"), fs = require("fs");
const [, , path, fake] = process.argv;
const frame = (body) => {
  const xml = Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>${body}</dict></plist>\n`);
  const head = Buffer.alloc(16);
  head.writeUInt32LE(16 + xml.length, 0); head.writeUInt32LE(1, 4); head.writeUInt32LE(8, 8); head.writeUInt32LE(1, 12);
  return Buffer.concat([head, xml]);
};
const result = (n) => frame(`<key>MessageType</key><string>Result</string><key>Number</key><integer>${n}</integer>`);
net.createServer((socket) => {
  let buffer = Buffer.alloc(0);
  socket.on("error", () => {});
  const data = (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length < 16 || buffer.length < buffer.readUInt32LE(0)) return;
    socket.off("data", data);
    const xml = buffer.subarray(16, buffer.readUInt32LE(0)).toString();
    if (xml.includes("<string>ListDevices</string>")) {
      const serials = fs.readFileSync(fake + "/usb", "utf8").split(/\s+/).filter(Boolean);
      const list = serials.map((serial, i) => `<dict><key>DeviceID</key><integer>${i + 7}</integer><key>MessageType</key><string>Attached</string><key>Properties</key><dict><key>ConnectionType</key><string>USB</string><key>DeviceID</key><integer>${i + 7}</integer><key>SerialNumber</key><string>${serial}</string></dict></dict>`);
      return socket.end(frame(`<key>DeviceList</key><array>${list.join("")}</array>`));
    }
    const swapped = Number(/<key>PortNumber<\/key><integer>(\d+)<\/integer>/.exec(xml)[1]);
    fs.appendFileSync(fake + "/connects", `${((swapped & 0xff) << 8) | (swapped >> 8)}\n`);
    let port = 0;
    try { port = Number(fs.readFileSync(fake + "/runner-port", "utf8")); } catch {}
    if (!port) return socket.end(result(3));
    const runner = net.connect(port, "127.0.0.1");
    runner.on("error", () => socket.end(result(3)));
    runner.on("connect", () => { socket.write(result(0)); socket.pipe(runner); runner.pipe(socket); });
  };
  socket.on("data", data);
}).listen(path);
JS
cat > "$tmp/runner.js" <<'JS'
const http = require("http"), fs = require("fs");
const fake = process.argv[2];
const mode = () => { try { return fs.readFileSync(fake + "/runner-mode", "utf8").trim(); } catch { return "ok"; } };
const server = http.createServer((req, res) => {
  if (req.url === "/health") return res.end(JSON.stringify({ protocol: mode() === "protocol2" ? 2 : 1 }));
  fs.appendFileSync(fake + "/trees", "1\n");
  const m = mode();
  if (m === "hang") return;
  if (m === "close") return req.socket.destroy();
  if (m === "private" || m === "snapshot") {
    res.statusCode = 500;
    return res.end(JSON.stringify({ error: m === "private" ? "XCTest has no accessibilityInterface" : "Error kAXErrorIllegalArgument getting snapshot", kind: m }));
  }
  res.end(fs.readFileSync(fake + "/tree.json"));
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(fake + "/runner-port", String(server.address().port)));
JS
"$node_bin" "$tmp/usbmuxd.js" "$tmp/usbmuxd" "$fake" &
daemon=$!
echo P1 > "$fake/usb"
: > "$fake/connects"
echo ok > "$fake/start"
display() { echo "{\"result\":{\"displays\":[{\"primary\":true,\"pointScale\":3,\"currentOrientation\":\"$1\",\"nativeSize\":[$2]}]}}" > "$fake/displays.json"; }
display rot0 1290,2796
runner_installed() { printf 'echo %s\n' "'{\"result\":{\"apps\":[{\"bundleIdentifier\":\"com.karagozmcp.runner.$1.xctrunner\"}]}}'" > "$fake/apps"; }
runner_installed abcde12345
stop_runner() { pkill -f "$tmp/runner.js"; pkill -f "sleep 97\.43"; rm -f "$fake/runner-port"; while pgrep -f "$tmp/runner.js" > /dev/null; do sleep 0.1; done; }
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
for wanted in "-destination id=P1" "-only-testing:KaragozRunner/Runner/testServe" "-test-timeouts-enabled NO" "/ABCDE12345/Build/Products/KaragozRunner_iphoneos27.1-arm64.xctestrun"; do
  case "$args" in *"$wanted"*) ;; *) fail "start arguments lack '$wanted': $args" ;; esac
done
is "runner port" "$(/usr/bin/sort -u "$fake/connects")" 27753
out=$(k ui-tree --device P1) || fail "warm read exited non-zero: $out"
is "warm read: no second start" "$(starts)" $((before + 1))
display rot90 1080,2340
out=$(k ui-tree --device P1) || fail "mini exited non-zero: $out"
is "mini and rotation" "$(printf '%s' "$out" | "$node_bin" -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(r.rotation, JSON.stringify(r.root.bounds))')" "270 [0,0,1238.4,2684.16]"
display rot0 1290,2796

# Read failures from a running runner.
for m in snapshot:CAPTURE_FAILED:kAXErrorIllegalArgument private:HELPER_FAILED:"update karagoz" close:CAPTURE_FAILED:"closed the connection" protocol2:RUNNER_NOT_INSTALLED:"install-runner --device P1"; do
  echo "${m%%:*}" > "$fake/runner-mode"
  rest=${m#*:}
  refuses "runner ${m%%:*}" "${rest%%:*}" "${rest#*:}" ui-tree --device P1
done
echo hang > "$fake/runner-mode"
t0=$(date +%s)
refuses "runner hangs" CAPTURE_FAILED "did not answer within 30 s" ui-tree --device P1
[ $(($(date +%s) - t0)) -le 40 ] || fail "hang took $(($(date +%s) - t0)) s"
rm "$fake/runner-mode"

# Not attached by cable; then a stopped runner: not installed, or installed without a build here, never starts one.
: > "$fake/usb"
refuses "not on USB" DEVICE_NOT_READY "USB" ui-tree --device P1
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
echo "xcodebuild: error: Something unexpected happened." > "$fake/start-text"
refuses "unknown start failure" HELPER_FAILED "Something unexpected happened. (log: " ui-tree --device P1
echo hang > "$fake/start"
t0=$(date +%s)
refuses "start never answers" DEVICE_NOT_READY "did not start within 60 s" ui-tree --device P1
[ $(($(date +%s) - t0)) -le 75 ] || fail "start budget took $(($(date +%s) - t0)) s"
sleep 1
! pgrep -f "sleep 97\.43" > /dev/null || fail "the hung xcodebuild was left running"

# Two first calls at once start one runner.
echo ok > "$fake/start"
before=$(starts)
k ui-tree --device P1 > "$tmp/first" & first=$!
k ui-tree --device P1 > "$tmp/second" & second=$!
wait $first || fail "first concurrent call failed: $(/bin/cat "$tmp/first")"
wait $second || fail "second concurrent call failed: $(/bin/cat "$tmp/second")"
is "concurrent: one start" "$(starts)" $((before + 1))
is "concurrent: same tree" "$(/bin/cat "$tmp/second")" "$want"
refuses "other commands" NOT_SUPPORTED "runs only screenshot, ui-tree, install-runner and uninstall-runner" key HOME --device P1
stop_runner

echo "ok: teams, build arguments, failures, targets, uninstall, mapping, mini, read failures, not on USB, not installed, start failures, start budget (60s), lock"
