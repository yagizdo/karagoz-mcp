import { execFile, spawn } from 'node:child_process';
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { closeSync, constants, openSync } from 'node:fs';
import { copyFile, mkdir, open, readdir, readFile, rename, rm, writeFile, type FileHandle } from 'node:fs/promises';
import type { Socket } from 'node:net';
import { dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError, type ErrorCode } from '../../errors.js';
import { apps, installApp, PHONE_TIMEOUT_MS, profiles, removeProfile, uninstallApp } from './devicectl.js';
import { isRecord } from './devices.js';
import { connect } from './usbmux.js';
import { buildVersion, CACHE_HINT, CACHE_ROOT, noTeam, ownedDir, teams, xcode } from './xcode.js';

const run = promisify(execFile);

// The runner's Xcode project, copied next to the bundle by the build (packages/ios-runner, K41). Only these three
// files make a runner; the cache key hashes them and the build copies them, so nothing Xcode writes lands in the package.
const PROJECT = fileURLToPath(new URL('ios-runner/', import.meta.url));
const SOURCES = [
  'KaragozRunner.xcodeproj/project.pbxproj',
  'KaragozRunner.xcodeproj/xcshareddata/xcschemes/KaragozRunner.xcscheme',
  'KaragozRunner/Runner.swift',
];
const ID_PREFIX = 'com.karagozmcp.runner.';
// Xcode installs a UI-testing bundle X as the app X.xctrunner.
const APP_SUFFIX = '.xctrunner';
// A cold build creates a certificate, an App ID and a profile online and registers the phone (K41).
const BUILD_TIMEOUT_MS = 600_000;
// A second install for the team waits for the first one's build, which shares its derived data.
const BUILD_LOCK_MS = BUILD_TIMEOUT_MS + 10_000;
// xcodebuild -quiet still prints every warning and error; a signing failure can repeat a line per target.
const MAX_BUFFER = 64 * 1024 * 1024;
const TEAM = /^[A-Z0-9]{10}$/;

// The test bundle's id for a team; the team keeps it unique on a free account (K41).
function runnerId(team: string): string {
  return ID_PREFIX + team.toLowerCase();
}

// The team in an installed runner's app id, com.karagozmcp.runner.<team>.xctrunner; undefined for any other app.
function teamOf(appId: string): string | undefined {
  if (!appId.startsWith(ID_PREFIX) || !appId.endsWith(APP_SUFFIX)) return undefined;
  const team = appId.slice(ID_PREFIX.length, -APP_SUFFIX.length).toUpperCase();
  return TEAM.test(team) ? team : undefined;
}

// Where this karagoz's runner, built by this Xcode, lives: one directory per team below it.
export async function runnerBuild(dev: string): Promise<string> {
  const texts = await Promise.all(
    SOURCES.map((file) =>
      readFile(join(PROJECT, file)).catch(() => {
        throw new KaragozError('HELPER_FAILED', `cannot read ${join(PROJECT, file)}; reinstall karagoz`);
      }),
    ),
  );
  const hash = createHash('sha256');
  for (const text of texts) hash.update(text).update('\0');
  const key = hash
    .update(dev)
    .update('\0')
    .update(await buildVersion(dev))
    .digest('hex')
    .slice(0, 16);
  return join(CACHE_ROOT, 'runner', key);
}

// The .xctestrun the team's build left under root, undefined when there is none. Xcode names it KaragozRunner_<sdk>;
// the session copies start() writes beside it are not builds (K42).
export async function xctestrun(root: string, team: string): Promise<string | undefined> {
  const products = join(root, team, 'Build', 'Products');
  const file = (await readdir(products).catch(() => [])).find(
    (name) => name.startsWith('KaragozRunner_') && name.endsWith('.xctestrun'),
  );
  return file && join(products, file);
}

// --team when given, else the only team in Xcode's accounts, else the only paid one.
async function chooseTeam(wanted: string | undefined): Promise<string> {
  if (wanted !== undefined) {
    if (!TEAM.test(wanted)) {
      throw new KaragozError(
        'INVALID_ARGS',
        `--team must be a 10-character Apple team ID such as ABCDE12345 (got '${wanted}')`,
      );
    }
    return wanted;
  }
  const { signedIn, teams: all } = await teams();
  const [only, ...others] = all;
  if (!only) throw new KaragozError('HELPER_FAILED', `${noTeam(signedIn)}, then run install-runner again.`);
  if (!others.length) return only.id;
  const paid = all.filter((team) => !team.free);
  const [onlyPaid] = paid;
  if (onlyPaid && paid.length === 1) return onlyPaid.id;
  const listed = all.map((team) => `${team.id} (${team.name}${team.free ? ', free' : ''})`).join(', ');
  throw new KaragozError('INVALID_ARGS', `Xcode lists more than one team: ${listed}. Pick one with --team <ID>.`);
}

// Builds the runner for the team with xcodebuild and installs it with devicectl: the one command that writes the runner
// to a phone (K13 4.0 note, K41).
export async function installRunner(udid: string, wanted: string | undefined) {
  const dev = await xcode();
  const team = await chooseTeam(wanted);
  const root = await runnerBuild(dev);
  await ownedDir(join(CACHE_ROOT, 'runner'));
  await ownedDir(root);
  const derived = join(root, team);
  await ownedDir(derived);
  const id = runnerId(team);
  // Two installs for one team share its derived data, which one xcodebuild builds at a time.
  await locked(`team-${team}`, BUILD_LOCK_MS, async () => {
    const project = join(derived, 'project');
    for (const file of SOURCES) {
      await mkdir(dirname(join(project, file)), { recursive: true, mode: 0o700 });
      await copyFile(join(PROJECT, file), join(project, file));
    }
    const log = join(derived, 'build.log');
    const signal = cancellation.getStore();
    signal?.throwIfAborted();
    try {
      const { stdout, stderr } = await run(
        join(dev, 'usr', 'bin', 'xcodebuild'),
        [
          '-quiet',
          'build-for-testing',
          '-project',
          join(project, 'KaragozRunner.xcodeproj'),
          '-scheme',
          'KaragozRunner',
          '-destination',
          `id=${udid}`,
          '-derivedDataPath',
          derived,
          '-allowProvisioningUpdates',
          '-allowProvisioningDeviceRegistration',
          `DEVELOPMENT_TEAM=${team}`,
          `PRODUCT_BUNDLE_IDENTIFIER=${id}`,
          'CODE_SIGN_STYLE=Automatic',
        ],
        { timeout: BUILD_TIMEOUT_MS, maxBuffer: MAX_BUFFER, ...(signal && { signal }) },
      );
      await writeFile(log, stdout + stderr);
    } catch (err) {
      // The SDK sends no response for a cancelled call, so the abort passes through (K31).
      if (signal?.aborted) throw err;
      if (!(err instanceof Error)) throw err;
      const stdout = 'stdout' in err && typeof err.stdout === 'string' ? err.stdout : '';
      const stderr = 'stderr' in err && typeof err.stderr === 'string' ? err.stderr : '';
      const output = stdout + stderr;
      await writeFile(log, output).catch(() => undefined);
      if ('killed' in err && err.killed) {
        throw new KaragozError(
          'HELPER_FAILED',
          `xcodebuild did not finish within ${BUILD_TIMEOUT_MS / 60_000} minutes (log: ${log})`,
        );
      }
      if ('code' in err && err.code === 'ENOENT') {
        throw new KaragozError(
          'HELPER_FAILED',
          `xcodebuild not found in ${dev}; install Xcode and select it (xcode-select -s <Xcode.app>)`,
        );
      }
      const errors = output.split('\n').filter((line) => line.includes('error:'));
      const reason = (
        errors.length ? [...new Set(errors.map((line) => line.trim()))].slice(0, 3).join(' ') : err.message
      ).slice(0, 300);
      throw new KaragozError('HELPER_FAILED', `the runner build failed: ${reason} (log: ${log})`);
    }
  });
  await installApp(udid, join(derived, 'Build', 'Products', 'Debug-iphoneos', 'KaragozRunner-Runner.app'));
  return { device: udid, bundleId: id + APP_SUFFIX, team };
}

// Removes every karagoz runner and the provisioning profiles made for its ids. Automatic signing on a paid team used the
// team wildcard profile (measured), which other apps share: it is never touched (K41).
export async function uninstallRunner(udid: string) {
  // Under the phone's lock: a start in progress would put back what this removes (K41).
  return locked(udid, PHONE_LOCK_MS, async () => {
    const installed = (await apps(udid)).map(({ id }) => id).filter((id) => teamOf(id) !== undefined);
    for (const id of installed) await uninstallApp(udid, id);
    const ours = new RegExp(`^[A-Z0-9]{10}\\.${ID_PREFIX.replace(/\./g, '\\.')}`);
    const removed: string[] = [];
    for (const profile of await profiles(udid)) {
      if (!ours.test(profile.appId)) continue;
      await removeProfile(udid, profile.uuid);
      removed.push(profile.uuid);
    }
    return { device: udid, apps: installed, profiles: removed };
  });
}

// Mirrored in packages/ios-runner/KaragozRunner/Runner.swift: the port, the protocol, the two headers, and the text each
// HMAC-SHA256 covers, 'karagoz-req\n<nonce>\n<METHOD> <path>\n<body>' for a request and
// 'karagoz-res\n<nonce>\n<status>\n<body>' for its answer. Every request and answer is signed with the secret of the
// runner's start, which never travels (K42).
const PORT = 27753;
const PROTOCOL = 2;
const NONCE_HEADER = 'X-Karagoz-Nonce';
const MAC_HEADER = 'X-Karagoz-Mac';
const SECRET = /^[0-9a-f]{64}$/;
// From xcodebuild's start to the runner's first answer; prior art budgets 45-60 s, 4.3's phone run measured it (K41).
const START_BUDGET_MS = 60_000;
// How long a call waits for a phone's lock: the holder's devicectl app list, its start budget, and slack for the health
// checks around them.
const PHONE_LOCK_MS = PHONE_TIMEOUT_MS + START_BUDGET_MS + 15_000;
// The simulator helper's read timeout (K34); the runner gives up on a snapshot itself after 20 s.
const READ_TIMEOUT_MS = 30_000;
// One usbmux connect and /health, which the runner answers off its main thread.
const HEALTH_TIMEOUT_MS = 3_000;
const POLL_MS = 500;
// Darwin's O_EXLOCK, which Node does not name: open() takes an exclusive lock the kernel drops when its holder exits,
// crashed or not, so a lock file needs no staleness rule (K41).
const O_EXLOCK = 0x20;

// Where this Mac keeps the secret of the runner it last started on a phone; every karagoz process of this user reads it.
const secretPath = (udid: string) => join(CACHE_ROOT, 'runner', `${udid}.token`);

function notInstalled(udid: string, reason: string): KaragozError {
  return new KaragozError(
    'RUNNER_NOT_INSTALLED',
    `karagoz's runner ${reason} on iPhone ${udid}. Install it with 'karagoz install-runner --device ${udid}' (MCP: install_runner).`,
  );
}

function stranger(udid: string): KaragozError {
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

// A signed request to the phone's runner, which ensure() has found answering.
async function request(
  udid: string,
  method: 'GET' | 'POST',
  path: string,
  body: string,
  timeoutMs: number,
  failure: ErrorCode,
): Promise<Answer> {
  const key = await secretOf(udid);
  const socket = await connect(udid, PORT, HEALTH_TIMEOUT_MS);
  if (socket === 'refused') throw new KaragozError(failure, "karagoz's runner stopped before it answered");
  return exchange(socket, key, method, path, body, timeoutMs, failure);
}

type Health = 'up' | 'down' | 'old' | 'stranger';

// up: this Mac's runner answers, signed; down: nothing listens; old: a 4.3 runner, which signs nothing; stranger:
// anything else listening there, or no secret here to tell. A listener that accepts and does not answer is a stranger
// too: the runner answers /health off its main thread, and starting another would replace the secret of a live one.
async function health(udid: string): Promise<Health> {
  const socket = await connect(udid, PORT, HEALTH_TIMEOUT_MS);
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
  return isRecord(parsed) && parsed.protocol === PROTOCOL ? 'up' : 'stranger';
}

function refusal(udid: string, state: 'old' | 'stranger'): KaragozError {
  return state === 'old' ? notInstalled(udid, 'is an older version') : stranger(udid);
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
// the other texts come from sources and 4.3's phone run (K41).
function startFailure(udid: string, log: string, output: string): KaragozError {
  const lower = output.toLowerCase();
  const states: [string[], ErrorCode, string][] = [
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
// secret on any command line or in Xcode's logs (measured, K42).
async function keyed(udid: string, build: string): Promise<string> {
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
    `${plist.slice(0, at)}<key>KARAGOZ_TOKEN</key><string>${secret}</string>${plist.slice(at)}`,
  );
  await writePrivate(secretPath(udid), secret);
  return session;
}

// Starts the runner with xcodebuild test-without-building, detached: it outlives this call and ends with the runner's
// idle stop. Only the start budget bounds this call; a start nobody waits for is killed with its process group (K41).
async function start(udid: string, dev: string): Promise<void> {
  const build = await installedBuild(udid, dev);
  await ownedDir(join(CACHE_ROOT, 'runner'));
  const xctestrun = await keyed(udid, build);
  const signal = cancellation.getStore();
  // The kill below listens for an abort from here on; a call aborted before starts nothing.
  signal?.throwIfAborted();
  const log = join(CACHE_ROOT, 'runner', `${udid}.log`);
  const fd = openSync(log, 'w', 0o600);
  // Set from the child's events; an object, so the loop below re-reads it.
  const ended = { exited: false };
  const child = (() => {
    try {
      return spawn(
        join(dev, 'usr', 'bin', 'xcodebuild'),
        [
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
        ],
        // Never inherit: in MCP mode stdout is the JSON-RPC stream.
        { detached: true, stdio: ['ignore', fd, fd] },
      );
    } finally {
      closeSync(fd);
    }
  })();
  child.once('error', () => (ended.exited = true));
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
      if (ended.exited) throw startFailure(udid, log, output);
      // xcodebuild waits, without exiting, for a phone that is not ready and says why (a locked iPhone, measured, K42):
      // a reason startFailure knows ends the start now instead of at the budget.
      if (output.includes('Waiting for the destination to become ready')) {
        const failure = startFailure(udid, log, output);
        if (failure.code !== 'HELPER_FAILED') throw failure;
      }
      const state = await health(udid);
      if (state === 'up') return;
      if (state !== 'down') throw refusal(udid, state);
      if (Date.now() > deadline) {
        throw new KaragozError(
          'DEVICE_NOT_READY',
          `device ${udid} is not ready: karagoz's runner did not start within ${START_BUDGET_MS / 1000} s. Look at the iPhone: unlock it, enter the passcode if it asks to enable UI automation, and check that Settings > Developer > Enable UI Automation is on (log: ${log}).`,
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

// Runs work while holding the lock file name.lock, waiting up to waitMs for it: a phone's UDID, so concurrent first calls
// start one runner and an uninstall waits for a start (K3 4.0 note), or team-<ID> for one build at a time.
async function locked<T>(name: string, waitMs: number, work: () => Promise<T>): Promise<T> {
  const dir = join(CACHE_ROOT, 'locks');
  await ownedDir(dir);
  const path = join(dir, `${name}.lock`);
  const signal = cancellation.getStore();
  const deadline = Date.now() + waitMs;
  let handle: FileHandle | undefined;
  while (!handle) {
    try {
      handle = await open(path, constants.O_RDWR | constants.O_CREAT | constants.O_NONBLOCK | O_EXLOCK, 0o600);
    } catch (err) {
      if (!(err instanceof Error) || !('code' in err) || err.code !== 'EAGAIN') {
        throw new KaragozError(
          'HELPER_FAILED',
          `cannot lock ${path} (${err instanceof Error ? err.message : String(err)}); ${CACHE_HINT}`,
        );
      }
      if (Date.now() > deadline) {
        throw new KaragozError('HELPER_FAILED', `another karagoz call kept ${path} for over ${waitMs / 1000} s`);
      }
      await sleep(POLL_MS, undefined, signal && { signal });
    }
  }
  try {
    return await work();
  } finally {
    await handle.close();
  }
}

// The runner answering on its port, started first when nothing answers.
async function ensure(udid: string): Promise<void> {
  const state = await health(udid);
  if (state === 'up') return;
  if (state !== 'down') throw refusal(udid, state);
  const dev = await xcode();
  await locked(udid, PHONE_LOCK_MS, async () => {
    const again = await health(udid);
    if (again === 'up') return;
    if (again !== 'down') throw refusal(udid, again);
    await start(udid, dev);
  });
}

// The raw snapshot of what is on the iPhone's screen, from the runner (K41).
export async function tree(udid: string): Promise<unknown> {
  await ensure(udid);
  const { status, body, signed } = await request(udid, 'GET', '/tree', '', READ_TIMEOUT_MS, 'CAPTURE_FAILED');
  if (!signed) throw stranger(udid);
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

// One input on the iPhone, through the runner started first if need be. playMs is how long the gesture or the typing
// takes, added to the call's budget as the runner adds it to its own (K42).
export async function input(
  udid: string,
  route: '/tap' | '/swipe' | '/text' | '/button',
  body: Record<string, unknown>,
  playMs: number,
): Promise<void> {
  await ensure(udid);
  const answer = await request(udid, 'POST', route, JSON.stringify(body), READ_TIMEOUT_MS + playMs, 'HELPER_FAILED');
  if (!answer.signed) throw stranger(udid);
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
    if ((await health(udid)) === 'up') return 'running';
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
