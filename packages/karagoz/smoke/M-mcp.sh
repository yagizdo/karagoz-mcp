#!/bin/sh
# Step M: `karagoz mcp` serves the 15 commands as MCP tools over stdio. The CLI lists mcp and checks its arguments;
# the bundle holds no HTTP transport or bearer-auth code and reaches the server chunk only through import(); both
# supported protocol versions are echoed; tools/list carries the 15 tools, their annotations and flat schemas within
# 7,200 characters; every result and error is the CLI's JSON line; key HOME, ui_tree and an inline screenshot work on
# the emulator; a cancelled call, stdin close, SIGTERM and SIGINT kill the call's adb child at once and the server
# keeps serving after a cancel; a cancelled logs call kills its streaming simctl; UiAutomation reads on one device take turns and a cancelled waiting read never runs;
# a cached adb that vanishes is looked up again, stays in use when an earlier candidate reappears, and is the one
# doctor names; stdout carries only JSON-RPC and every session exits 0 when stdin closes.
# Precondition: an emulator is running with its screen on. The only input is key HOME. Fake adbs run with
# PATH=/usr/bin:/bin and a scratch HOME, so no real adb runs under them; the adb server on the default port is never
# touched.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

tmp=$(mktemp -d)
# set +e: errexit stays on inside the trap. sleep 97.31, 97.41, 97.42 and 97.44 are the fake adb, simctl and devicectl
# hangs; the pkill is a safety net.
trap 'set +e; pkill -f "sleep 97\.(31|41|42|44)"; rm -rf "$tmp"' EXIT
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
# and, when $2 is not empty, whose message is exactly $2. Leaves the envelope in $got. stdin is /dev/null, so a server
# that starts by mistake exits instead of waiting.
refuses() {
  want=$1 msg=$2
  shift 2
  if got=$(node dist/cli.js "$@" 2>/dev/null < /dev/null); then echo "FAIL: $* exited 0: $got"; exit 1; fi
  [ "$(printf '%s' "$got" | code_of)" = "$want" ] || { echo "FAIL: $*: expected $want, got: $got"; exit 1; }
  [ -z "$msg" ] || [ "$(printf '%s' "$got" | message_of)" = "$msg" ] \
    || { echo "FAIL: $*: expected the message '$msg', got: $got"; exit 1; }
}

# 1. CLI.
refuses NO_COMMAND "no command given. Commands: devices, screenshot, ui-tree, key, tap, swipe, text, install, launch, terminate, uninstall, logs, doctor, install-runner, uninstall-runner, mcp"
refuses INVALID_ARGS "unexpected argument 'extra'" mcp extra
refuses INVALID_ARGS "'mcp' does not take the option '--device'" mcp --device x

# 2. Bundle. The pattern names what only the HTTP transports and bearer auth contain (K14); node:http is not in it,
# the Node HTTP transport imports a bare "http2".
if grep -lE 'StreamableHTTPServerTransport|requireBearerAuth|WWW-Authenticate|text/event-stream|from "(node:)?(http|https|http2)"' dist/*.js; then
  echo "FAIL: bundle: HTTP transport or bearer-auth code in the file(s) above"; exit 1
fi
# The server chunk is reached only through import(), and the CLI runs without it.
lazy=$(node -e '
const fs = require("fs"), os = require("os"), path = require("path"), { spawnSync } = require("child_process");
try {
  const dist = "dist", read = (f) => fs.readFileSync(path.join(dist, f), "utf8");
  const holders = fs.readdirSync(dist).filter((f) => f.endsWith(".js") && read(f).includes("StdioServerTransport = class"));
  if (holders.length !== 1) throw new Error("server code in: " + (holders.join(", ") || "no file"));
  const server = holders[0], seen = new Set();
  const walk = (f) => { if (seen.has(f)) return; seen.add(f);
    for (const m of read(f).matchAll(/^(?:import|export)\s(?:[^;"]*?\sfrom\s*)?"\.\/([^"]+)"/gm)) walk(m[1]); };
  walk("cli.js");
  if (seen.has(server)) throw new Error("static imports reach " + server + " via " + [...seen].join(" "));
  if (!read("cli.js").includes(`import("./${server}")`)) throw new Error("cli.js does not import() " + server);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "karagoz-lazy-"));
  try {
    fs.cpSync(dist, tmp, { recursive: true }); fs.rmSync(path.join(tmp, server));
    fs.writeFileSync(path.join(tmp, "package.json"), "{\"type\":\"module\"}");
    const run = (arg) => spawnSync(process.execPath, [path.join(tmp, "cli.js"), arg], { encoding: "utf8" });
    const v = run("--version"), e = run("nope");
    if (v.status !== 0 || !/^\d+\.\d+\.\d+\n$/.test(v.stdout)) throw new Error("--version without " + server + ": " + v.stdout + v.stderr);
    if (!e.stdout.includes("\"code\":\"UNKNOWN_COMMAND\"")) throw new Error("nope without " + server + ": " + e.stdout + e.stderr);
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
} catch (err) { console.log(err instanceof Error ? err.message : String(err)); process.exitCode = 1; }
') || { echo "FAIL: bundle: $lazy"; exit 1; }
[ "$(node dist/cli.js --version)" = "$(node -p 'require("./package.json").version')" ] \
  || { echo "FAIL: bundle: --version is not package.json's version"; exit 1; }

# 3. The first ready emulator. Every live call names it, so a second device cannot cause DEVICE_AMBIGUOUS.
list=$(node dist/cli.js devices) || { echo "FAIL: devices exited non-zero: $list"; exit 1; }
id=$(printf '%s' "$list" | node -e '
  const found = JSON.parse(require("fs").readFileSync(0, "utf8")).devices.find((d) => d.kind === "emulator" && d.state === "device");
  if (!found) process.exit(1);
  console.log(found.id);
') || { echo "FAIL: no ready emulator in: $list (is one running? emulator -avd <name>)"; exit 1; }

# 4. A fake adb for what a live device does not give on demand. ANDROID_HOME makes it karagoz's first candidate.
mkdir -p "$tmp/sdk/platform-tools" "$tmp/fake" "$tmp/home"
cat > "$tmp/sdk/platform-tools/adb" <<'FAKE'
#!/bin/sh
# Fake adb for smoke M: one device, and a hang on demand. exec, so killing adb kills the sleep. A dump holds a lock
# for 1 s and fails as uiautomator does when another dump holds it.
case "$*" in
  devices) [ -e "$FAKE/hang" ] && exec sleep 97.31; printf 'List of devices attached\nfake-1\tdevice\n\n' ;;
  *'exec-out uiautomator dump /dev/tty')
    if mkdir "$FAKE/lock" 2>/dev/null; then sleep 1; echo x >> "$FAKE/dumps"; cat "$FAKE/tree.xml"; rmdir "$FAKE/lock"
    else echo 'ERROR: another dump is running'; fi ;;
  *'shell dumpsys accessibility') echo '    Ui Automation[id=0, flags=0]' ;;
  *) echo "fake adb: unexpected arguments: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/sdk/platform-tools/adb"
# A fake simctl for the same servers: no simulator, or one booted on demand whose log show never ends, and a hang on
# demand.
mkdir -p "$tmp/dev/usr/bin"
cat > "$tmp/dev/usr/bin/simctl" <<'FAKE'
#!/bin/sh
[ -e "$FAKE/simctl-hang" ] && exec sleep 97.41
[ "$1" = spawn ] && exec sleep 97.42
if [ -e "$FAKE/simctl-sim" ]; then
  echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"A1","name":"iPhone 17","state":"Booted","isAvailable":true}]}}'
else
  echo '{"devices":{}}'
fi
FAKE
# A fake devicectl for the same servers: no iPhone, and a hang on demand.
cat > "$tmp/dev/usr/bin/devicectl" <<'FAKE'
#!/bin/sh
[ -e "$FAKE/devicectl-hang" ] && exec sleep 97.44
echo '{"result":{"devices":[]}}'
FAKE
chmod +x "$tmp/dev/usr/bin/simctl" "$tmp/dev/usr/bin/devicectl"
printf '%s' "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\"><node class=\"android.widget.FrameLayout\" package=\"dev.karagoz.fake\" bounds=\"[0,0][100,100]\" /></hierarchy>" \
  > "$tmp/fake/tree.xml"

# 5. The MCP groups. m.mjs prints FAIL lines only.
cat > "$tmp/m.mjs" <<'JS'
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync, writeSync } from 'node:fs';
import { createInterface } from 'node:readline';

const [id, tmp] = process.argv.slice(2);
const pkg = JSON.parse(readFileSync('package.json', 'utf8'));
const sessions = [];
// stdout lines that are not JSON-RPC messages, from any session; reported by the hygiene group.
const stray = [];

// writeSync: on macOS a pipe write is asynchronous, and process.exit would drop it.
function fail(message) {
  writeSync(1, `FAIL: ${message}\n`);
  process.exit(1);
}

async function start(env = process.env, version = '2025-11-25') {
  const child = spawn(process.execPath, ['dist/cli.js', 'mcp'], { env });
  // A write after the server exited fails with EPIPE; the missing response reports it.
  child.stdin.on('error', () => {});
  const got = new Map();
  const waiting = new Map();
  const stderr = [];
  let next = 1;
  createInterface({ input: child.stdout }).on('line', (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      stray.push(line);
      return;
    }
    if (message?.jsonrpc !== '2.0') return void stray.push(line);
    if (message.id === undefined) return;
    got.set(message.id, message);
    waiting.get(message.id)?.(message);
  });
  createInterface({ input: child.stderr }).on('line', (line) => stderr.push(line));
  const exited = new Promise((resolve) => child.on('exit', (code, signal) => resolve({ code, signal })));
  const write = (message) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`);
  const session = {
    child,
    stderr,
    exited,
    send(method, params) {
      const requestId = next++;
      write({ id: requestId, method, params });
      return requestId;
    },
    response(requestId, ms = 30_000) {
      if (got.has(requestId)) return Promise.resolve(got.get(requestId));
      return new Promise((resolve) => {
        const timer = setTimeout(() => fail(`no response to ${requestId} within ${ms} ms`), ms);
        waiting.set(requestId, (message) => {
          clearTimeout(timer);
          resolve(message);
        });
      });
    },
    request: (method, params) => session.response(session.send(method, params)),
    call: (tool, args) => session.request('tools/call', { name: tool, arguments: args }),
    notify: (method, params) => write({ method, params }),
    answered: (requestId) => got.has(requestId),
  };
  sessions.push(session);
  session.init = await session.request('initialize', {
    protocolVersion: version,
    capabilities: {},
    clientInfo: { name: 'smoke', version: '0' },
  });
  session.notify('notifications/initialized');
  return session;
}

const cli = (...args) => spawnSync(process.execPath, ['dist/cli.js', ...args], { encoding: 'utf8' }).stdout.replace(/\n$/, '');
const text = (message) => message.result.content[0].text;
const running = (pattern) => spawnSync('pgrep', ['-f', pattern]).status === 0;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const within = (promise, ms) => Promise.race([promise, sleep(ms).then(() => 'timeout')]);
async function until(predicate, ms) {
  for (const end = Date.now() + ms; Date.now() < end; await new Promise((resolve) => setTimeout(resolve, 50))) {
    if (predicate()) return true;
  }
  return predicate();
}
// The env of a server on the fake adb: built from nothing, so no real adb is on PATH or in the default SDK.
// DEVELOPER_DIR points at a fake simctl, so no simulator running on the Mac reaches the exact devices lines (smoke 3.1).
const fake = (extra = {}) => ({ PATH: '/usr/bin:/bin', HOME: `${tmp}/home`, ANDROID_HOME: `${tmp}/sdk`, DEVELOPER_DIR: `${tmp}/dev`, FAKE: `${tmp}/fake`, ...extra });

// Handshake.
const versions = ['2025-11-25', '2025-06-18'];
const [main] = await Promise.all(versions.map((version) => start(process.env, version)));
for (const [i, version] of versions.entries()) {
  const init = sessions[i].init.result;
  if (init?.protocolVersion !== version) fail(`handshake ${version}: ${JSON.stringify(sessions[i].init)}`);
  if (JSON.stringify(init.serverInfo) !== JSON.stringify({ name: 'karagoz', version: pkg.version })) {
    fail(`handshake ${version}: serverInfo ${JSON.stringify(init.serverInfo)}`);
  }
  if (typeof init.instructions !== 'string' || init.instructions.length > 400) {
    fail(`handshake ${version}: instructions ${JSON.stringify(init.instructions)}`);
  }
}

// List. The cap was 6,000 for 13 tools; the token table is measured again at the end of Kadran 4.
const list = (await main.request('tools/list', {})).result;
const names = ['devices', 'screenshot', 'ui_tree', 'tap', 'swipe', 'text', 'key', 'install', 'launch', 'terminate', 'uninstall', 'logs', 'doctor', 'install_runner', 'uninstall_runner'];
if (JSON.stringify(list?.tools?.map((tool) => tool.name).sort()) !== JSON.stringify([...names].sort())) {
  fail(`list: names ${JSON.stringify(list?.tools?.map((tool) => tool.name))}`);
}
const readOnly = ['devices', 'ui_tree', 'logs', 'doctor'];
const destructive = ['install', 'uninstall', 'uninstall_runner'];
// install_runner's build registers the iPhone and an App ID with Apple's developer service.
const openWorld = ['install_runner'];
const required = { swipe: ['x1', 'y1', 'x2', 'y2'], text: ['text'], key: ['key'], install: ['apk'], launch: ['package'], terminate: ['package'], uninstall: ['package'] };
const keys = (value) => (value && typeof value === 'object' ? Object.entries(value).flatMap(([key, inner]) => [key, ...keys(inner)]) : []);
for (const tool of list.tools) {
  const { name, annotations: hints = {}, inputSchema: schema } = tool;
  if ((hints.readOnlyHint === true) !== readOnly.includes(name)) fail(`list: ${name} readOnlyHint ${hints.readOnlyHint}`);
  const harmful = readOnly.includes(name) ? hints.destructiveHint === true : hints.destructiveHint !== destructive.includes(name);
  if (harmful) fail(`list: ${name} destructiveHint ${hints.destructiveHint}`);
  if (hints.openWorldHint !== openWorld.includes(name)) fail(`list: ${name} openWorldHint ${hints.openWorldHint}`);
  if (typeof tool.title !== 'string' || !tool.title) fail(`list: ${name} has no title`);
  if (schema?.type !== 'object') fail(`list: ${name} inputSchema.type ${schema?.type}`);
  if (JSON.stringify(schema.required) !== JSON.stringify(required[name])) fail(`list: ${name} required ${JSON.stringify(schema.required)}`);
  const banned = keys(schema).filter((key) => ['oneOf', 'anyOf', 'allOf', 'pattern', 'minimum', 'maximum', 'format', 'default'].includes(key));
  if (banned.length) fail(`list: ${name} schema has ${banned.join(', ')}`);
}
// 7,200 since logs says what an iPhone reads without since and how long a read takes (7,141 then, K44).
if (JSON.stringify(list).length > 7200) fail(`list: ${JSON.stringify(list).length} characters, over 7200`);

// Parity. Fails unless the call fails with exactly the envelope want, and the server logged its message.
async function refuses(tool, args, want) {
  const label = `parity: ${tool} ${JSON.stringify(args)}`;
  const res = await main.call(tool, args);
  if (res.result?.isError !== true || res.result.content?.length !== 1 || text(res) !== want) {
    fail(`${label}: expected ${want}, got ${JSON.stringify(res)}`);
  }
  const line = `karagoz: ${JSON.parse(want).error.message}`;
  if (!(await until(() => main.stderr.includes(line), 2000))) fail(`${label}: no '${line}' on stderr`);
}
for (const tool of ['devices', 'doctor']) {
  const res = await main.call(tool, {});
  if (res.result?.isError || res.result?.content?.length !== 1 || text(res) !== cli(tool)) {
    fail(`parity: ${tool}: expected ${cli(tool)}, got ${JSON.stringify(res)}`);
  }
}
await refuses('tap', { x: 1 }, cli('tap', '1'));
await refuses('tap', { x: 1, y: null }, cli('tap', '1'));
await refuses('tap', { x: 1, y: 2, duration: 1.5 }, cli('tap', '1', '2', '--duration', '1.5'));
await refuses('tap', { x: 1, y: 2, timeout: 5 }, cli('tap', '1', '2', '--timeout', '5'));
await refuses('key', { key: 'NOPE' }, cli('key', 'NOPE'));
await refuses('launch', { package: 'a;b' }, cli('launch', 'a;b'));
await refuses('text', { text: '' }, cli('text', ''));
await refuses('screenshot', { out: '/tmp/x.jpg' }, cli('screenshot', '--out', '/tmp/x.jpg'));
await refuses('screenshot', { out: '/tmp/x.jpg', inline: null }, cli('screenshot', '--out', '/tmp/x.jpg'));
await refuses('devices', { device: 'x' }, cli('devices', '--device', 'x'));
await refuses('ui_tree', { device: 'karagoz-none' }, cli('ui-tree', '--device', 'karagoz-none'));
await refuses('devices', { foo: 1 }, `{"error":{"code":"INVALID_ARGS","message":"'devices' does not take the option '--foo'"}}`);
await refuses('screenshot', { inline: 'yes' }, `{"error":{"code":"INVALID_ARGS","message":"inline must be true or false (got 'yes')"}}`);
for (const name of ['nope', 'ui-tree']) {
  const res = await main.call(name, {});
  if (res.error?.code !== -32602 || 'result' in res) fail(`parity: tool ${name}: expected a -32602 error, got ${JSON.stringify(res)}`);
}

// Live, on the emulator. key HOME is the only input of this smoke.
const home = await main.call('key', { key: 'HOME', device: id });
if (text(home) !== `{"device":"${id}","key":"KEYCODE_HOME","code":3}`) fail(`live: key HOME: ${JSON.stringify(home)}`);
const tree = JSON.parse(text(await main.call('ui_tree', { device: id })));
if (tree.device !== id || typeof tree.root?.class !== 'string') fail(`live: ui_tree: ${JSON.stringify(tree).slice(0, 300)}`);
const shot = await main.call('screenshot', { device: id, inline: true, out: `${tmp}/s.png` });
const [meta, image] = shot.result?.content ?? [];
if (shot.result?.isError || shot.result.content.length !== 2) fail(`live: screenshot: ${JSON.stringify(shot).slice(0, 300)}`);
const { path, pixels } = JSON.parse(meta.text);
if (path !== `${tmp}/s.png`) fail(`live: screenshot path ${path}`);
if (Object.keys(image).sort().join() !== 'data,mimeType,type' || image.type !== 'image' || image.mimeType !== 'image/png') {
  fail(`live: screenshot image block ${JSON.stringify({ ...image, data: image.data?.slice(0, 20) })}`);
}
const png = Buffer.from(image.data, 'base64');
if (!png.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')) || png.readUInt32BE(16) !== pixels.width || png.readUInt32BE(20) !== pixels.height) {
  fail(`live: screenshot image is not a ${pixels.width}x${pixels.height} PNG`);
}

// Cancel, fake adb: the cancelled call's adb dies, no response and no karagoz: line follow, and the server still serves.
const hang = `${tmp}/fake/hang`;
const sleeping = () => running('sleep 97\\.31');
writeFileSync(hang, '');
const faked = await start(fake());
const hung = faked.send('tools/call', { name: 'devices', arguments: {} });
if (!(await until(sleeping, 3000))) fail('cancel: the fake adb never started sleep 97.31');
faked.notify('notifications/cancelled', { requestId: hung, reason: 'smoke' });
if (!(await until(() => !sleeping(), 2000))) fail('cancel: sleep 97.31 still running 2 s after notifications/cancelled');
await sleep(500);
if (faked.answered(hung)) fail('cancel: the cancelled call was answered');
if (faked.stderr.some((line) => line.startsWith('karagoz:'))) fail(`cancel: stderr ${JSON.stringify(faked.stderr)}`);
rmSync(hang);
const listed = await faked.call('devices', {});
if (text(listed) !== '{"devices":[{"id":"fake-1","platform":"android","kind":"physical","state":"device","name":null}]}') {
  fail(`cancel: devices after the cancel: ${JSON.stringify(listed)}`);
}

// Cancel, fake simctl: the iOS listing's simctl dies with the call too, and nothing answers it.
const simctlHang = `${tmp}/fake/simctl-hang`;
const simctlSleeping = () => running('sleep 97\\.41');
writeFileSync(simctlHang, '');
const hungIos = faked.send('tools/call', { name: 'devices', arguments: {} });
if (!(await until(simctlSleeping, 3000))) fail('cancel simctl: the fake simctl never started sleep 97.41');
faked.notify('notifications/cancelled', { requestId: hungIos, reason: 'smoke' });
if (!(await until(() => !simctlSleeping(), 2000))) fail('cancel simctl: sleep 97.41 still running 2 s after notifications/cancelled');
await sleep(500);
if (faked.answered(hungIos)) fail('cancel simctl: the cancelled call was answered');
if (faked.stderr.some((line) => line.startsWith('karagoz:'))) fail(`cancel simctl: stderr ${JSON.stringify(faked.stderr)}`);
rmSync(simctlHang);

// Cancel, fake devicectl: the iPhone listing's devicectl dies with the call too, and nothing answers it.
const devicectlHang = `${tmp}/fake/devicectl-hang`;
const devicectlSleeping = () => running('sleep 97\\.44');
writeFileSync(devicectlHang, '');
const hungPhones = faked.send('tools/call', { name: 'devices', arguments: {} });
if (!(await until(devicectlSleeping, 3000))) fail('cancel devicectl: the fake devicectl never started sleep 97.44');
faked.notify('notifications/cancelled', { requestId: hungPhones, reason: 'smoke' });
if (!(await until(() => !devicectlSleeping(), 2000))) {
  fail('cancel devicectl: sleep 97.44 still running 2 s after notifications/cancelled');
}
await sleep(500);
if (faked.answered(hungPhones)) fail('cancel devicectl: the cancelled call was answered');
if (faked.stderr.some((line) => line.startsWith('karagoz:'))) fail(`cancel devicectl: stderr ${JSON.stringify(faked.stderr)}`);
rmSync(devicectlHang);

// Cancel, streaming simctl: a cancelled logs call kills its log show, and nothing answers it.
const simulator = `${tmp}/fake/simctl-sim`;
const reading = () => running('sleep 97\\.42');
writeFileSync(simulator, '');
const hungLogs = faked.send('tools/call', { name: 'logs', arguments: { device: 'A1' } });
if (!(await until(reading, 3000))) fail('cancel logs: the fake log show never started sleep 97.42');
faked.notify('notifications/cancelled', { requestId: hungLogs, reason: 'smoke' });
if (!(await until(() => !reading(), 2000))) fail('cancel logs: sleep 97.42 still running 2 s after notifications/cancelled');
await sleep(500);
if (faked.answered(hungLogs)) fail('cancel logs: the cancelled call was answered');
if (faked.stderr.some((line) => line.startsWith('karagoz:'))) fail(`cancel logs: stderr ${JSON.stringify(faked.stderr)}`);
rmSync(simulator);

// Exit, fake adb: stdin close, SIGTERM and SIGINT each end the server with its code and leave no adb child.
writeFileSync(hang, '');
for (const [how, code] of [['stdin', 0], ['SIGTERM', 143], ['SIGINT', 130]]) {
  const session = await start(fake());
  session.send('tools/call', { name: 'devices', arguments: {} });
  if (!(await until(sleeping, 3000))) fail(`exit ${how}: the fake adb never started sleep 97.31`);
  if (how === 'stdin') session.child.stdin.end();
  else session.child.kill(how);
  const end = await within(session.exited, 3000);
  if (end === 'timeout' || end.code !== code) fail(`exit ${how}: expected code ${code} within 3 s, got ${JSON.stringify(end)}`);
  if (!(await until(() => !sleeping(), 500))) fail(`exit ${how}: sleep 97.31 outlived the server`);
}
rmSync(hang);

// Cancel, device: a tap waiting for a node that never appears reads the screen and never taps; after the cancel no
// uiautomator dump is left and the device answers ui_tree again (it keeps its UiAutomation slot ~1-2 s, K19 note).
const waiting = main.send('tools/call', { name: 'tap', arguments: { device: id, text: 'NoSuchKaragozNode', timeout: 10000 } });
await sleep(2000);
main.notify('notifications/cancelled', { requestId: waiting, reason: 'smoke' });
await sleep(1000);
if (running('exec-out uiautomator')) fail('cancel: exec-out uiautomator still running 1 s after the cancel');
await sleep(2000);
const again = await main.call('ui_tree', { device: id });
if (again.result?.isError || typeof JSON.parse(text(again)).root?.class !== 'string') {
  fail(`cancel: ui_tree 3 s after the cancel: ${JSON.stringify(again).slice(0, 300)}`);
}
if (main.answered(waiting)) fail('cancel: the cancelled tap was answered');

// Queue, fake adb: two ui_tree calls on one serial take turns, and a call cancelled while it waits never reads.
const dumps = `${tmp}/fake/dumps`;
const dumped = () => (readFileSync(dumps, { encoding: 'utf8', flag: 'a+' }).match(/x/g) ?? []).length;
const tiny = '{"device":"fake-1","rotation":0,"root":{"class":"android.widget.FrameLayout","package":"dev.karagoz.fake","bounds":[0,0,100,100]}}';
const queued = await start(fake());
const pair = await Promise.all([1, 2].map(() => queued.call('ui_tree', { device: 'fake-1' })));
for (const [i, res] of pair.entries()) {
  if (text(res) !== tiny) fail(`queue: two ui_tree on fake-1: ${i ? 'second' : 'first'} result ${text(res)}`);
}
if (dumped() !== 2) fail(`queue: ${dumped()} dumps for two ui_tree calls`);
rmSync(dumps);
const ahead = queued.send('tools/call', { name: 'ui_tree', arguments: { device: 'fake-1' } });
// Each call resolves its device before it queues, so two calls sent together can queue in either order.
if (!(await until(() => existsSync(`${tmp}/fake/lock`), 3000))) fail('queue: the first ui_tree never started its dump');
const behind = queued.send('tools/call', { name: 'ui_tree', arguments: { device: 'fake-1' } });
await sleep(300);
queued.notify('notifications/cancelled', { requestId: behind, reason: 'smoke' });
const first = text(await queued.response(ahead));
if (first !== tiny) fail(`queue: the call ahead of a cancelled one: ${first}`);
await sleep(1500);
if (dumped() !== 1) fail(`queue: ${dumped()} dumps after a cancelled wait, expected 1`);
if (queued.answered(behind)) fail('queue: the cancelled ui_tree was answered');
// Live: the same on the emulator.
for (const res of await Promise.all([1, 2].map(() => main.call('ui_tree', { device: id })))) {
  if (res.result?.isError || JSON.parse(text(res)).device !== id) fail(`queue: two ui_tree on ${id}: ${text(res).slice(0, 300)}`);
}

// Re-lookup: ANDROID_HOME's adb answers, is deleted, and ANDROID_SDK_ROOT's answers the next call of the same server.
for (const [n, name] of [[1, 'one'], [2, 'two']]) {
  mkdirSync(`${tmp}/sdk${n}/platform-tools`, { recursive: true });
  const script = `#!/bin/sh\ncase "$*" in\n  devices) printf 'List of devices attached\\nfake-${name}\\tdevice\\n\\n' ;;\n  *) echo "fake adb: unexpected arguments: $*" >&2; exit 1 ;;\nesac\n`;
  writeFileSync(`${tmp}/sdk${n}/platform-tools/adb`, script, { mode: 0o755 });
}
const moving = await start({ PATH: '/usr/bin:/bin', HOME: `${tmp}/home`, ANDROID_HOME: `${tmp}/sdk1`, ANDROID_SDK_ROOT: `${tmp}/sdk2` });
const before = text(await moving.call('devices', {}));
if (!before.includes('"id":"fake-one"')) fail(`re-lookup: expected fake-one, got ${before}`);
renameSync(`${tmp}/sdk1/platform-tools/adb`, `${tmp}/adb-one`);
const after = text(await moving.call('devices', {}));
if (!after.includes('"id":"fake-two"')) fail(`re-lookup: expected fake-two, got ${after}`);
// The fakes fail `adb version`, so doctor marks the one it names failed; the source says which one that is.
renameSync(`${tmp}/adb-one`, `${tmp}/sdk1/platform-tools/adb`);
const kept = text(await moving.call('devices', {}));
if (!kept.includes('"id":"fake-two"')) fail(`re-lookup: expected fake-two to stay in use, got ${kept}`);
const report = JSON.parse(text(await moving.call('doctor', {})));
if (report.adb.source !== 'ANDROID_SDK_ROOT') fail(`re-lookup: doctor names ${report.adb.source}, not the adb in use`);

// Hygiene: stdout is JSON-RPC only; stderr is karagoz's own lines and adb's daemon lines.
if (stray.length) fail(`hygiene: stdout lines that are not JSON-RPC: ${JSON.stringify(stray.slice(0, 3))}`);
for (const session of sessions) {
  const odd = session.stderr.filter((line) => !line.startsWith('karagoz: ') && !line.startsWith('* '));
  if (odd.length) fail(`hygiene: stderr lines: ${JSON.stringify(odd.slice(0, 3))}`);
}

// End: every session still open exits 0 once its stdin closes.
for (const session of sessions) {
  if (session.child.exitCode !== null || session.child.signalCode !== null) continue;
  session.child.stdin.end();
  const end = await within(session.exited, 3000);
  if (end === 'timeout' || end.code !== 0) fail(`end: server exited ${JSON.stringify(end)} after stdin closed`);
}
process.exit(0);
JS
node "$tmp/m.mjs" "$id" "$tmp" || exit 1

echo "ok: $id, cli, bundle, handshake, list, parity, live, cancel, exit, queue, re-lookup"
