#!/bin/sh
# Step 2.1: an emulator attached with `adb connect` lists as an emulator with its AVD name and can be targeted by
# that name; NO_DEVICE mentions a phone with USB debugging; an image from before 2021 is named from
# ro.kernel.qemu.avd_name (fake adb); a physical device, when one is listed, is named by its ro.product.model.
# Precondition: an emulator is running (emulator -avd <name>); a phone with USB debugging on is optional.
# The TCP and empty-list steps run on a second adb server on a free port with USB, emulator and mDNS scanning off,
# and the trap stops only that server. The server on the default port is never stopped, and the only calls that reach a
# phone are `adb devices` and getprop.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

tmp=$(mktemp -d)
port=
# set +e: errexit stays on inside the trap, and a failing kill-server would skip the rm.
trap 'set +e; [ -z "$port" ] || ANDROID_ADB_SERVER_PORT=$port adb kill-server 2>/dev/null; rm -rf "$tmp"' EXIT
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
# Runs a command against the second server. USB, emulator and mDNS scanning stay off even if a call has to restart
# it, so it never claims a phone the default server holds or auto-connects one paired over Wi-Fi. KARAGOZ_DEVICE and
# ANDROID_SERIAL from the calling shell are cleared: either would turn the NO_DEVICE step into DEVICE_NOT_FOUND.
on_test() { ANDROID_ADB_SERVER_PORT=$port ADB_USB=0 ADB_EMU=0 ADB_MDNS=0 KARAGOZ_DEVICE= ANDROID_SERIAL= DEVELOPER_DIR="$tmp/dev" "$@"; }
# A simctl that lists no simulator and a devicectl that lists no iPhone, so the exact devices lines below hold with one
# running or attached (smokes 3.1, 4.1).
mkdir -p "$tmp/dev/usr/bin"
cat > "$tmp/dev/usr/bin/simctl" <<'EOF'
#!/bin/sh
echo '{"devices":{}}'
EOF
cat > "$tmp/dev/usr/bin/devicectl" <<'EOF'
#!/bin/sh
echo '{"result":{"devices":[]}}'
EOF
chmod +x "$tmp/dev/usr/bin/simctl" "$tmp/dev/usr/bin/devicectl"

# 1. A ready, named emulator on the default server. Its adb port is the console port in emulator-<N> plus one.
list=$(node dist/cli.js devices) || { echo "FAIL: devices exited non-zero: $list"; exit 1; }
emu=$(printf '%s' "$list" | node -e '
  const found = JSON.parse(require("fs").readFileSync(0, "utf8")).devices.find((d) => /^emulator-\d+$/.test(d.id) && d.state === "device" && d.name);
  if (!found) process.exit(1);
  console.log(found.id, found.name);
') || { echo "FAIL: no ready, named emulator in: $list (is one running? emulator -avd <name>)"; exit 1; }
id=${emu% *}
name=${emu#* }
adb_port=$((${id#emulator-} + 1))

# 2. A second server with nothing on it: an empty listing, and NO_DEVICE for a targeted command.
port=$(node -e 'const s = require("net").createServer().listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); })')
on_test adb start-server 2>/dev/null || { echo "FAIL: adb start-server on port $port failed"; exit 1; }
out=$(on_test node dist/cli.js devices) || { echo "FAIL: devices on the second server exited non-zero: $out"; exit 1; }
[ "$out" = '{"devices":[]}' ] || { echo "FAIL: the second server is not empty: $out"; exit 1; }
if none=$(on_test node dist/cli.js screenshot --out "$tmp/none.png" 2>/dev/null); then echo "FAIL: screenshot with no device exited 0"; exit 1; fi
[ "$(printf '%s' "$none" | code_of)" = NO_DEVICE ] || { echo "FAIL: expected NO_DEVICE, got: $none"; exit 1; }
case $(printf '%s' "$none" | message_of) in
  *"emulator -avd"*"USB debugging"*) ;;
  *) echo "FAIL: NO_DEVICE message does not mention emulator -avd and USB debugging: $none"; exit 1 ;;
esac

# 3. The same emulator over TCP: kind emulator, its AVD name, and targetable by that name.
on_test adb connect "127.0.0.1:$adb_port" >/dev/null
out=$(on_test node dist/cli.js devices) || { echo "FAIL: devices with the TCP entry exited non-zero: $out"; exit 1; }
want="{\"devices\":[{\"id\":\"127.0.0.1:$adb_port\",\"platform\":\"android\",\"kind\":\"emulator\",\"state\":\"device\",\"name\":\"$name\"}]}"
[ "$out" = "$want" ] || { echo "FAIL: TCP entry listed as $out, expected $want"; exit 1; }
res=$(on_test node dist/cli.js screenshot --device "$name" --out "$tmp/tcp.png") \
  || { echo "FAIL: screenshot --device $name on the TCP entry exited non-zero: $res"; exit 1; }
[ -s "$tmp/tcp.png" ] || { echo "FAIL: screenshot by AVD name over TCP wrote no file: $res"; exit 1; }
if miss=$(on_test node dist/cli.js screenshot --device nosuch --out "$tmp/x.png" 2>/dev/null); then echo "FAIL: unknown device exited 0"; exit 1; fi
[ "$(printf '%s' "$miss" | code_of)" = DEVICE_NOT_FOUND ] || { echo "FAIL: expected DEVICE_NOT_FOUND, got: $miss"; exit 1; }
case $(printf '%s' "$miss" | message_of) in
  *"127.0.0.1:$adb_port ($name)"*) ;;
  *) echo "FAIL: DEVICE_NOT_FOUND message does not list 127.0.0.1:$adb_port ($name): $miss"; exit 1 ;;
esac

# 4. An image from before 2021 keeps the AVD name under ro.kernel.qemu. None is installed here, so a fake adb on an
# otherwise empty PATH answers as one would over TCP.
mkdir "$tmp/fake"
cat > "$tmp/fake/adb" <<'EOF'
#!/bin/sh
case "$*" in
  devices) printf 'List of devices attached\n127.0.0.1:5557\tdevice\n\n' ;;
  '-s 127.0.0.1:5557 shell '*) printf 'sdk_phone_x86\n\n1\nranchu\n\nOld_API_28\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/fake/adb"
out=$(env -i HOME="$tmp" PATH="$tmp/fake" DEVELOPER_DIR="$tmp/dev" "$(command -v node)" dist/cli.js devices) \
  || { echo "FAIL: devices with the fake adb exited non-zero: $out"; exit 1; }
want='{"devices":[{"id":"127.0.0.1:5557","platform":"android","kind":"emulator","state":"device","name":"Old_API_28"}]}'
[ "$out" = "$want" ] || { echo "FAIL: old image listed as $out, expected $want"; exit 1; }

# 5. A physical device on the default server, if one is listed: its name is ro.product.model, read here directly.
phone=$(printf '%s' "$list" | node -e '
  const found = JSON.parse(require("fs").readFileSync(0, "utf8")).devices.find((d) => d.kind === "physical" && d.state === "device");
  if (found) console.log(JSON.stringify(found));
')
physical=physical
if [ -z "$phone" ]; then
  echo "SKIP: no physical device"
  physical="physical skipped"
else
  serial=$(printf '%s' "$phone" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf8")).id')
  model=$(adb -s "$serial" shell getprop ro.product.model) || { echo "FAIL: getprop ro.product.model failed"; exit 1; }
  got=$(printf '%s' "$phone" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf8")).name')
  [ "$got" = "$model" ] || { echo "FAIL: physical device name is '$got', ro.product.model is '$model'"; exit 1; }
fi

echo "ok: tcp-emulator, no-device, old-image, $physical"
