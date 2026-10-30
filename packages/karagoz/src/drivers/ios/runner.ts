import { spawn } from 'node:child_process';
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { closeSync, openSync } from 'node:fs';
import { readFile, rename, rm, writeFile } from 'node:fs/promises';
import { createConnection, createServer, type Socket } from 'node:net';
import { dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { cancellation } from '../../cancellation.js';
import { KaragozError, type ErrorCode } from '../../errors.js';
import { apps } from './devicectl.js';
import { isRecord } from './record.js';
import {
  locked,
  PHONE_LOCK_MS,
  POLL_MS,
  runnerBuild,
  simulatorBuild,
  START_BUDGET_MS,
  teamOf,
  xcodebuild,
  xctestrun,
} from './runner-build.js';
import { binary } from './simctl.js';
import { connect } from './usbmux.js';
import { CACHE_HINT, CACHE_ROOT, ownedDir, xcode } from './xcode.js';

// Mirrored in packages/ios-runner/KaragozRunner/Runner.swift: the port, the protocol, the two headers, and the text each
// HMAC-SHA256 covers, 'karagoz-req\n<nonce>\n<METHOD> <path>\n<body>' for a request and
// 'karagoz-res\n<nonce>\n<status>\n<body>' for its answer. Every request and answer is signed with the secret of the
// runner's start, which never travels (K42).
const PORT = 27753;
const PROTOCOL = 3;
const NONCE_HEADER = 'X-Karagoz-Nonce';
const MAC_HEADER = 'X-Karagoz-Mac';
const SECRET = /^[0-9a-f]{64}$/;
// The simulator helper's read timeout (K34); the runner gives up on a snapshot itself after 20 s.
const READ_TIMEOUT_MS = 30_000;
// One usbmux connect and /health, which the runner answers off its main thread.
const HEALTH_TIMEOUT_MS = 3_000;

// Where this Mac keeps the secret of the runner it last started on a device, and a simulator runner's port; every karagoz
// process of this user reads them.
const secretPath = (udid: string) => join(CACHE_ROOT, 'runner', `${udid}.token`);
const portPath = (udid: string) => join(CACHE_ROOT, 'runner', `${udid}.port`);

// An iPhone's runner over usbmux, or a simulator's: a process on this Mac.
export type On = 'iphone' | 'simulator';

function notInstalled(udid: string, reason: string): KaragozError {
  return new KaragozError(
    'RUNNER_NOT_INSTALLED',
    `karagoz's runner ${reason} on iPhone ${udid}. Install it with 'karagoz install-runner --device ${udid}' (MCP: install_runner).`,
  );
}

function stranger(udid: string, on: On): KaragozError {
  if (on === 'simulator') {
    return new KaragozError(
      'DEVICE_NOT_READY',
      `device ${udid} is not ready: another process on this Mac answers on the port of karagoz's runner. Try again`,
    );
  }
  return new KaragozError(
    'DEVICE_NOT_READY',
    `device ${udid} is not ready: something else on the iPhone answers on karagoz's port ${PORT} without this Mac's key for karagoz's runner: another app, or a runner another Mac user started (it stops within 10 minutes). Restart the iPhone if it stays.`,
  );
}

const mac = (key: Buffer, prefix: string, body: Buffer) =>
  createHmac('sha256', key).update(prefix).update(body).digest('hex');

// The secret's bytes, undefined when this Mac has none for the phone: nothing can be signed then (K42).
async function secretOf(udid: string): Promise<Buffer | undefined> {
  const text = await readFile(secretPath(udid), 'utf8').catch(() => '');
  return SECRET.test(text) ? Buffer.from(text, 'hex') : undefined;
}

type Answer = { status: number; body: string; signed: boolean };

// A port nobody on this Mac holds now. Another process can take it before the runner binds it; the start then fails with
// Runner.swift's 'cannot listen on'.
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      const port = typeof address === 'object' && address !== null ? address.port : 0;
      server.close(() => resolve(port));
    });
  });
}

// The runner's stream, paused: an iPhone's through usbmux at the fixed port; a simulator's on this Mac's loopback, which
// the simulator shares, at the port its start picked (K49). 'refused' when nothing listens there.
async function reach(udid: string, on: On): Promise<Socket | 'refused'> {
  if (on === 'iphone') return connect(udid, PORT, HEALTH_TIMEOUT_MS);
  const port = Number(await readFile(portPath(udid), 'utf8').catch(() => ''));
  if (!Number.isInteger(port) || port < 1 || port > 65535) return 'refused';
  return new Promise((resolve) => {
    const socket = createConnection({ host: '127.0.0.1', port });
    // A loopback connect fails at once when nothing listens; any failure means start a runner.
    const refused = () => {
      clearTimeout(timer);
      socket.destroy();
      resolve('refused');
    };
    const timer = setTimeout(refused, HEALTH_TIMEOUT_MS);
    socket.once('error', refused);
    socket.once('connect', () => {
      clearTimeout(timer);
      socket.off('error', refused);
      socket.pause();
      resolve(socket);
    });
  });
}

// One HTTP/1.0 request on a usbmux stream; the runner closes the connection after its answer. signed: the answer
// carries a valid MAC for this request's nonce, which needs the secret (K42).
function exchange(
  socket: Socket,
  key: Buffer | undefined,
  method: 'GET' | 'POST',
  path: string,
  body: string,
  timeoutMs: number,
  failure: ErrorCode,
): Promise<Answer> {
  const signal = cancellation.getStore();
  const nonce = randomBytes(16).toString('hex');
  const payload = Buffer.from(body);
  const head = [
    `${method} ${path} HTTP/1.0`,
    'Host: karagoz',
    `Content-Length: ${payload.length}`,
    `${NONCE_HEADER}: ${nonce}`,
  ];
  if (key) head.push(`${MAC_HEADER}: ${mac(key, `karagoz-req\n${nonce}\n${method} ${path}\n`, payload)}`);
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const finish = (settle: () => void) => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', aborted);
      socket.destroy();
      settle();
    };
    const timer = setTimeout(
      () =>
        finish(() => reject(new KaragozError(failure, `karagoz's runner did not answer within ${timeoutMs / 1000} s`))),
      timeoutMs,
    );
    // The SDK sends no response for a cancelled call, so the abort passes through (K31).
    const aborted = () => finish(() => reject(signal?.reason));
    signal?.addEventListener('abort', aborted, { once: true });
    socket.on('data', (chunk: Buffer) => chunks.push(chunk));
    socket.once('error', () => undefined);
    socket.once('close', () => {
      const all = Buffer.concat(chunks);
      const split = all.indexOf('\r\n\r\n');
      // Head fields are ASCII; the MAC covers the body's bytes, so it is checked before any UTF-8 decoding.
      const fields = split < 0 ? '' : all.subarray(0, split).toString('latin1');
      const status = /^HTTP\/1\.[01] (\d{3}) /.exec(fields)?.[1];
      const rest = all.subarray(split + 4);
      const length = /^content-length:[ \t]*(\d+)[ \t]*\r?$/im.exec(fields)?.[1];
      if (split < 0 || status === undefined || (length !== undefined && Number(length) !== rest.length)) {
        return finish(() =>
          reject(new KaragozError(failure, "karagoz's runner closed the connection before it answered")),
        );
      }
      const given = /^x-karagoz-mac:[ \t]*([0-9a-f]{64})[ \t]*\r?$/im.exec(fields)?.[1];
      const signed =
        key !== undefined &&
        given !== undefined &&
        timingSafeEqual(
          Buffer.from(given, 'hex'),
          Buffer.from(mac(key, `karagoz-res\n${nonce}\n${status}\n`, rest), 'hex'),
        );
      finish(() => resolve({ status: Number(status), body: rest.toString('utf8'), signed }));
    });
    socket.write(Buffer.concat([Buffer.from(`${head.join('\r\n')}\r\n\r\n`), payload]));
    socket.resume();
  });
}

// A signed request to the device's runner, which ensure() has found answering.
async function request(
  udid: string,
  on: On,
  method: 'GET' | 'POST',
  path: string,
  body: string,
  timeoutMs: number,
  failure: ErrorCode,
): Promise<Answer> {
  const key = await secretOf(udid);
  const socket = await reach(udid, on);
  if (socket === 'refused') throw new KaragozError(failure, "karagoz's runner stopped before it answered");
  return exchange(socket, key, method, path, body, timeoutMs, failure);
}

type Health = 'up' | 'down' | 'old' | 'stranger';

// up: this Mac's runner answers, signed; down: nothing listens; old: a 4.3 runner, which signs nothing, or a signed one
// of an older protocol, which lacks a route this karagoz sends (protocol 2 has no /double-tap); stranger:
// anything else listening there, or no secret here to tell. A listener that accepts and does not answer is a stranger
// too: the runner answers /health off its main thread, and starting another would replace the secret of a live one.
async function health(udid: string, on: On): Promise<Health> {
  const socket = await reach(udid, on);
  if (socket === 'refused') return 'down';
  let answer: Answer;
  try {
    answer = await exchange(socket, await secretOf(udid), 'GET', '/health', '', HEALTH_TIMEOUT_MS, 'CAPTURE_FAILED');
  } catch (err) {
    if (cancellation.getStore()?.aborted) throw err;
    return 'stranger';
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(answer.body);
  } catch {
    // Not JSON: not a runner of karagoz's.
    return 'stranger';
  }
  // Checked before the secret: a Mac coming from 4.3 has none, and its runner is still the older one.
  if (!answer.signed) return isRecord(parsed) && parsed.protocol === 1 ? 'old' : 'stranger';
  if (!isRecord(parsed) || typeof parsed.protocol !== 'number') return 'stranger';
  return parsed.protocol === PROTOCOL ? 'up' : parsed.protocol < PROTOCOL ? 'old' : 'stranger';
}

function refusal(udid: string, state: 'old' | 'stranger'): KaragozError {
  return state === 'old' ? notInstalled(udid, 'is an older version') : stranger(udid, 'iphone');
}

// The .xctestrun of the installed runner's team, built by this karagoz and Xcode. The check keeps test-without-building,
// which installs as part of a run, from putting a runner on a phone that has none (K13, K41).
async function installedBuild(udid: string, dev: string): Promise<string> {
  const runners = (await apps(udid)).flatMap(({ id }) => {
    const team = teamOf(id);
    return team === undefined ? [] : [team];
  });
  if (!runners.length) throw notInstalled(udid, 'is not installed');
  const root = await runnerBuild(dev);
  for (const team of runners) {
    const path = await xctestrun(root, team);
    if (path) return path;
  }
  throw notInstalled(udid, 'was built by another karagoz or Xcode, or its build was deleted,');
}

// What the iPhone's user or the caller does, by xcodebuild's log, first match wins. 0xe8008012 is from a captured log;
// the other texts come from sources and 4.3's phone run (K41). A simulator has only the port to lose.
function startFailure(udid: string, log: string, output: string, on: On): KaragozError {
  const lower = output.toLowerCase();
  const phone: [string[], ErrorCode, string][] = [
    // Runner.swift's own text when the port is taken (K42).
    [
      ['cannot listen on'],
      'DEVICE_NOT_READY',
      `another app on the iPhone holds karagoz's port ${PORT}. Restart the iPhone, then try again`,
    ],
    [['0xe8008012'], 'RUNNER_NOT_INSTALLED', 'was signed for other phones'],
    [['has expired', 'profile expired'], 'RUNNER_NOT_INSTALLED', 'has an expired provisioning profile'],
    [
      ['not been explicitly trusted', 'untrusted developer', 'invalid code signature'],
      'DEVICE_NOT_READY',
      'its developer is not trusted. On the iPhone, open Settings > General > VPN & Device Management and trust the developer app, then try again',
    ],
    [
      ['developer mode'],
      'DEVICE_NOT_READY',
      'Developer Mode is off. Turn it on in Settings > Privacy & Security > Developer Mode, then restart the iPhone',
    ],
    [
      ['device is locked', 'is passcode protected', 'still locked'],
      'DEVICE_NOT_READY',
      'it is locked. Unlock the iPhone and try again',
    ],
    [
      ['automation mode', 'ui automation'],
      'DEVICE_NOT_READY',
      'UI automation is off. Turn on Settings > Developer > Enable UI Automation, enter the passcode if the iPhone asks, then try again',
    ],
  ];
  const simulator: [string[], ErrorCode, string][] = [
    [['cannot listen on'], 'DEVICE_NOT_READY', 'another process on this Mac took the port karagoz picked. Try again'],
  ];
  const states = on === 'simulator' ? simulator : phone;
  const state = states.find(([texts]) => texts.some((text) => lower.includes(text)));
  if (state?.[1] === 'RUNNER_NOT_INSTALLED') return notInstalled(udid, state[2]);
  if (state) return new KaragozError(state[1], `device ${udid} is not ready: ${state[2]}.`);
  const lines = output.split('\n').map((line) => line.trim());
  const last = lines.filter((line) => /error/i.test(line)).at(-1) ?? lines.filter(Boolean).at(-1) ?? '';
  return new KaragozError(
    'HELPER_FAILED',
    `xcodebuild could not start karagoz's runner: ${last.slice(0, 300)} (log: ${log})`,
  );
}

// A fresh 0600 file in place of path: writeFile's mode applies only to a file it creates, so a new name and a rename.
async function writePrivate(path: string, data: string): Promise<void> {
  const tmp = `${path}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
  try {
    await writeFile(tmp, data, { mode: 0o600, flag: 'wx' });
    await rename(tmp, path);
  } catch (err) {
    await rm(tmp, { force: true });
    throw new KaragozError(
      'HELPER_FAILED',
      `cannot write ${path} (${err instanceof Error ? err.message : String(err)}); ${CACHE_HINT}`,
    );
  }
}

// A new secret for this start: in its file for later karagoz processes, and in a copy of the build's .xctestrun next to
// it (its paths are relative to that folder), whose EnvironmentVariables reach the runner on the phone without the
// secret on any command line or in Xcode's logs (measured, K42). A simulator's port travels the same way (K49).
async function keyed(udid: string, build: string, port: number | undefined): Promise<string> {
  const plist = await readFile(build, 'utf8').catch(() => '');
  const sections = [...plist.matchAll(/<key>EnvironmentVariables<\/key>\s*<dict>/g)];
  const [only] = sections;
  if (!only || sections.length > 1) {
    throw new KaragozError(
      'HELPER_FAILED',
      `cannot add karagoz's key to ${build}: this Xcode writes .xctestrun files karagoz does not know; update karagoz`,
    );
  }
  const secret = randomBytes(32).toString('hex');
  const at = only.index + only[0].length;
  const session = join(dirname(build), `session-${udid}.xctestrun`);
  await writePrivate(
    session,
    `${plist.slice(0, at)}<key>KARAGOZ_TOKEN</key><string>${secret}</string>${port === undefined ? '' : `<key>KARAGOZ_PORT</key><string>${port}</string>`}${plist.slice(at)}`,
  );
  await writePrivate(secretPath(udid), secret);
  if (port !== undefined) await writePrivate(portPath(udid), String(port));
  return session;
}

// A simulator's xcodebuild runs under sh, which turns app accessibility back on when xcodebuild exits: testmanagerd
// turns it off as the runner's session ends, and apps opened later read as an empty tree (measured on iOS 26.2 and 27,
// K47, K49). A killed group skips it; readTree() then puts it back.
const WRITE_BACK =
  'simctl=$1 udid=$2; shift 2; "$@"; "$simctl" spawn "$udid" defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true';

// Starts the runner with xcodebuild test-without-building, detached: it outlives this call and ends with the runner's
// idle stop. Only the start budget bounds this call; a start nobody waits for is killed with its process group (K41).
// simulator is the simulator build's .xctestrun; an iPhone's comes from the installed runner.
async function start(udid: string, dev: string, simulator: string | undefined): Promise<void> {
  const on: On = simulator === undefined ? 'iphone' : 'simulator';
  const build = simulator ?? (await installedBuild(udid, dev));
  await ownedDir(join(CACHE_ROOT, 'runner'));
  const xctestrun = await keyed(udid, build, on === 'simulator' ? await freePort() : undefined);
  const args = [
    'test-without-building',
    '-xctestrun',
    xctestrun,
    '-destination',
    `id=${udid}`,
    '-only-testing:KaragozRunner/Runner/testServe',
    '-test-timeouts-enabled',
    'NO',
    '-collect-test-diagnostics',
    'never',
    '-parallel-testing-enabled',
    'NO',
  ];
  const [command, argv] =
    on === 'iphone'
      ? [xcodebuild(dev).bin, args]
      : ['/bin/sh', ['-c', WRITE_BACK, 'sh', (await binary()).bin, udid, xcodebuild(dev).bin, ...args]];
  const signal = cancellation.getStore();
  // The kill below listens for an abort from here on; a call aborted before starts nothing.
  signal?.throwIfAborted();
  const log = join(CACHE_ROOT, 'runner', `${udid}.log`);
  const fd = openSync(log, 'w', 0o600);
  // Set from the child's events; an object, so the loop below re-reads it.
  const ended: { exited: boolean; error?: NodeJS.ErrnoException } = { exited: false };
  const child = (() => {
    try {
      // Never inherit: in MCP mode stdout is the JSON-RPC stream.
      return spawn(command, argv, { detached: true, stdio: ['ignore', fd, fd] });
    } finally {
      closeSync(fd);
    }
  })();
  child.once('error', (err: NodeJS.ErrnoException) => {
    ended.exited = true;
    ended.error = err;
  });
  child.once('exit', () => (ended.exited = true));
  child.unref();
  const kill = () => {
    if (ended.exited || child.pid === undefined) return;
    try {
      process.kill(-child.pid, 'SIGTERM');
    } catch {
      // Already gone: nothing to stop.
    }
  };
  // A signal handler aborts and exits at once (src/cli.ts, src/mcp.ts), before any catch below runs, so the abort itself
  // kills the start (K41).
  signal?.addEventListener('abort', kill, { once: true });
  const deadline = Date.now() + START_BUDGET_MS;
  try {
    for (;;) {
      const output = await readFile(log, 'utf8').catch(() => '');
      // A binary that cannot start comes as an 'error' event and leaves the log empty.
      if (ended.error) {
        throw new KaragozError(
          'HELPER_FAILED',
          ended.error.code === 'ENOENT'
            ? xcodebuild(dev).missing
            : `xcodebuild could not start karagoz's runner: ${ended.error.message} (log: ${log})`,
        );
      }
      if (ended.exited) throw startFailure(udid, log, output, on);
      // xcodebuild waits, without exiting, for a phone that is not ready and says why (a locked iPhone, measured, K42):
      // a reason startFailure knows ends the start now instead of at the budget.
      if (output.includes('Waiting for the destination to become ready')) {
        const failure = startFailure(udid, log, output, on);
        if (failure.code !== 'HELPER_FAILED') throw failure;
      }
      const state = await health(udid, on);
      if (state === 'up') return;
      // A simulator's port is this start's own; anything else there before the runner binds it fails the bind.
      if (on === 'iphone' && state !== 'down') throw refusal(udid, state);
      if (Date.now() > deadline) {
        const look =
          on === 'iphone'
            ? '. Look at the iPhone: unlock it, enter the passcode if it asks to enable UI automation, and check that Settings > Developer > Enable UI Automation is on'
            : '';
        throw new KaragozError(
          'DEVICE_NOT_READY',
          `device ${udid} is not ready: karagoz's runner did not start within ${START_BUDGET_MS / 1000} s${look} (log: ${log}).`,
        );
      }
      await sleep(POLL_MS, undefined, signal && { signal });
    }
  } catch (err) {
    kill();
    throw err;
  } finally {
    // A runner that answered stays up: a later abort of this call must not reach it.
    signal?.removeEventListener('abort', kill);
  }
}

// The runner answering on its port, started first when nothing answers. On a simulator anything but this Mac's runner
// at the stored port (none yet, a stale port, another process there) means start one, built first if need be (K49).
async function ensure(udid: string, on: On): Promise<void> {
  const state = await health(udid, on);
  if (state === 'up') return;
  if (on === 'iphone' && state !== 'down') throw refusal(udid, state);
  const dev = await xcode();
  // Outside the device's lock: a second first call waits for the build on the build's own lock.
  const simulator = on === 'simulator' ? await simulatorBuild(udid, dev) : undefined;
  await locked(udid, PHONE_LOCK_MS, async () => {
    const again = await health(udid, on);
    if (again === 'up') return;
    if (on === 'iphone' && again !== 'down') throw refusal(udid, again);
    await start(udid, dev, simulator);
  });
}

// The raw snapshot of what is on the iPhone's screen, from the runner (K41).
export async function tree(udid: string): Promise<unknown> {
  await ensure(udid, 'iphone');
  const { status, body, signed } = await request(udid, 'iphone', 'GET', '/tree', '', READ_TIMEOUT_MS, 'CAPTURE_FAILED');
  if (!signed) throw stranger(udid, 'iphone');
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new KaragozError('CAPTURE_FAILED', `cannot parse the runner's answer: ${body.slice(0, 100)}`);
  }
  if (status === 200 && isRecord(parsed) && parsed.root !== undefined) return parsed.root;
  throw runnerError(parsed, status, 'CAPTURE_FAILED', '');
}

// The runner's refusal, by its error text or else the status; a changed private interface is HELPER_FAILED (K41).
function runnerError(parsed: unknown, status: number, code: ErrorCode, prefix: string): KaragozError {
  const error = isRecord(parsed) && typeof parsed.error === 'string' ? parsed.error : `status ${status}`;
  if (isRecord(parsed) && parsed.kind === 'private') {
    return new KaragozError(
      'HELPER_FAILED',
      `${error}: this iOS changed an interface karagoz's runner uses; update karagoz`,
    );
  }
  return new KaragozError(code, prefix + error);
}

// One input on the device, through the runner started first if need be. playMs is how long the gesture or the typing
// takes, added to the call's budget as the runner adds it to its own (K42).
export async function input(
  udid: string,
  on: On,
  route: '/tap' | '/double-tap' | '/swipe' | '/text' | '/button',
  body: Record<string, unknown>,
  playMs: number,
): Promise<void> {
  await ensure(udid, on);
  const answer = await request(
    udid,
    on,
    'POST',
    route,
    JSON.stringify(body),
    READ_TIMEOUT_MS + playMs,
    'HELPER_FAILED',
  );
  if (!answer.signed) throw stranger(udid, on);
  if (answer.status === 200) return;
  let parsed: unknown;
  try {
    parsed = JSON.parse(answer.body);
  } catch {
    // Not the runner's JSON: the status is all there is to say.
    parsed = undefined;
  }
  throw runnerError(parsed, answer.status, 'HELPER_FAILED', "karagoz's runner could not play it: ");
}

export type RunnerState = 'running' | 'installed' | 'not installed' | null;

// running when the runner answers; else installed or not from devicectl's app list; null for an unpaired phone or when
// devicectl cannot tell. Never a KaragozError: devices prints the other phones and platforms whatever happens here.
async function runnerState(udid: string, paired: boolean): Promise<RunnerState> {
  if (!paired) return null;
  const signal = cancellation.getStore();
  try {
    if ((await health(udid, 'iphone')) === 'up') return 'running';
  } catch (err) {
    if (signal?.aborted) throw err;
    // Not on USB or usbmuxd unreachable: the runner can still be installed, which devicectl tells.
  }
  try {
    return (await apps(udid)).some(({ id }) => teamOf(id) !== undefined) ? 'installed' : 'not installed';
  } catch (err) {
    if (signal?.aborted) throw err;
    return null;
  }
}

// The runner's state on each attached iPhone, for devices only: resolving a target never pays for it (K41).
export async function runnerStates(phones: { id: string; state: string }[]): Promise<Map<string, RunnerState>> {
  const states = await Promise.all(phones.map(({ id, state }) => runnerState(id, state === 'paired')));
  return new Map(phones.map(({ id }, i) => [id, states[i] ?? null]));
}
