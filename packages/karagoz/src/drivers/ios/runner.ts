import { execFile, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { closeSync, constants, openSync } from 'node:fs';
import { copyFile, mkdir, open, readdir, readFile, writeFile, type FileHandle } from 'node:fs/promises';
import type { Socket } from 'node:net';
import { dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError, type ErrorCode } from '../../errors.js';
import { apps, installApp, profiles, removeProfile, uninstallApp } from './devicectl.js';
import { isRecord } from './devices.js';
import { connect } from './usbmux.js';
import { buildVersion, CACHE_HINT, CACHE_ROOT, owns, teams, xcode } from './xcode.js';

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
// xcodebuild -quiet still prints every warning and error; a signing failure can repeat a line per target.
const MAX_BUFFER = 64 * 1024 * 1024;
const TEAM = /^[A-Z0-9]{10}$/;

// The test bundle's id for a team; the team keeps it unique on a free account (K41).
export function runnerId(team: string): string {
  return ID_PREFIX + team.toLowerCase();
}

// The team in an installed runner's app id, com.karagozmcp.runner.<team>.xctrunner; undefined for any other app.
export function teamOf(appId: string): string | undefined {
  if (!appId.startsWith(ID_PREFIX) || !appId.endsWith(APP_SUFFIX)) return undefined;
  const team = appId.slice(ID_PREFIX.length, -APP_SUFFIX.length).toUpperCase();
  return TEAM.test(team) ? team : undefined;
}

// Where this karagoz's runner, built by this Xcode, lives: one directory per team below it.
export async function runnerBuild(dev: string): Promise<{ root: string; key: string }> {
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
  return { root: join(CACHE_ROOT, 'runner', key), key };
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
  const all = await teams();
  const [only, ...others] = all;
  if (!only) {
    throw new KaragozError(
      'HELPER_FAILED',
      'Xcode lists no Apple development team: sign in to Xcode > Settings > Accounts with your Apple ID, then run install-runner again (or pass --team <ID>)',
    );
  }
  if (!others.length) return only.id;
  const paid = all.filter((team) => !team.free);
  const [onlyPaid] = paid;
  if (onlyPaid && paid.length === 1) return onlyPaid.id;
  const listed = all.map((team) => `${team.id} (${team.name}${team.free ? ', free' : ''})`).join(', ');
  throw new KaragozError('INVALID_ARGS', `Xcode lists more than one team: ${listed}. Pick one with --team <ID>.`);
}

async function ownedDir(path: string): Promise<void> {
  try {
    await mkdir(path, { recursive: true, mode: 0o700 });
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    throw new KaragozError('HELPER_FAILED', err.message);
  }
  await owns(path, 'directory');
}

// Builds the runner for the team with xcodebuild and installs it with devicectl: the one command that writes the runner
// to a phone (K13 4.0 note, K41).
export async function installRunner(udid: string, wanted: string | undefined) {
  const dev = await xcode();
  const team = await chooseTeam(wanted);
  const { root } = await runnerBuild(dev);
  await ownedDir(join(CACHE_ROOT, 'runner'));
  await ownedDir(root);
  const derived = join(root, team);
  await ownedDir(derived);
  const project = join(derived, 'project');
  for (const file of SOURCES) {
    await mkdir(dirname(join(project, file)), { recursive: true, mode: 0o700 });
    await copyFile(join(PROJECT, file), join(project, file));
  }
  const id = runnerId(team);
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
  await installApp(udid, join(derived, 'Build', 'Products', 'Debug-iphoneos', 'KaragozRunner-Runner.app'));
  return { device: udid, bundleId: id + APP_SUFFIX, team };
}

// Removes every karagoz runner and the provisioning profiles made for them; a team wildcard profile is never touched.
export async function uninstallRunner(udid: string) {
  const installed = (await apps(udid)).map(({ id }) => id).filter((id) => teamOf(id) !== undefined);
  for (const id of installed) await uninstallApp(udid, id);
  const ours = new RegExp(`^[A-Z0-9]{10}\\.${ID_PREFIX.replace(/\./g, '\\.')}`);
  const removed: string[] = [];
  for (const profile of await profiles(udid)) {
    if (!profile.appIds.some((appId) => ours.test(appId))) continue;
    await removeProfile(udid, profile.uuid);
    removed.push(profile.uuid);
  }
  return { device: udid, apps: installed, profiles: removed };
}

// Mirrored in packages/ios-runner/KaragozRunner/Runner.swift; a runner answering another protocol is reinstalled (K41).
const PORT = 27753;
const PROTOCOL = 1;
// From xcodebuild's start to the runner's first answer; prior art budgets 45-60 s, 4.3's phone run measured it (K41).
const START_BUDGET_MS = 60_000;
// The simulator helper's read timeout (K34); the runner gives up on a snapshot itself after 20 s.
const READ_TIMEOUT_MS = 30_000;
// One usbmux connect and /health, which the runner answers off its main thread.
const HEALTH_TIMEOUT_MS = 3_000;
const POLL_MS = 500;
// Darwin's O_EXLOCK, which Node does not name: open() takes an exclusive lock the kernel drops when its holder exits,
// crashed or not, so a lock file needs no staleness rule (K41).
const O_EXLOCK = 0x20;

function notInstalled(udid: string, reason: string): KaragozError {
  return new KaragozError(
    'RUNNER_NOT_INSTALLED',
    `karagoz's runner ${reason} on iPhone ${udid}. Install it with 'karagoz install-runner --device ${udid}' (MCP: install_runner).`,
  );
}

// One HTTP/1.0 request on a usbmux stream; the runner closes the connection after its answer.
function get(socket: Socket, path: string, timeoutMs: number): Promise<{ status: number; body: string }> {
  const signal = cancellation.getStore();
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
        finish(() =>
          reject(new KaragozError('CAPTURE_FAILED', `karagoz's runner did not answer within ${timeoutMs / 1000} s`)),
        ),
      timeoutMs,
    );
    // The SDK sends no response for a cancelled call, so the abort passes through (K31).
    const aborted = () => finish(() => reject(signal?.reason));
    signal?.addEventListener('abort', aborted, { once: true });
    socket.on('data', (chunk: Buffer) => chunks.push(chunk));
    socket.once('error', () => undefined);
    socket.once('close', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      const split = text.indexOf('\r\n\r\n');
      const status = /^HTTP\/1\.[01] (\d{3}) /.exec(text)?.[1];
      finish(() =>
        split < 0 || status === undefined
          ? reject(new KaragozError('CAPTURE_FAILED', "karagoz's runner closed the connection before it answered"))
          : resolve({ status: Number(status), body: text.slice(split + 4) }),
      );
    });
    socket.write(`GET ${path} HTTP/1.0\r\nHost: karagoz\r\n\r\n`);
    socket.resume();
  });
}

// up: this karagoz's runner answers; down: nothing listens or it does not answer; other: a runner of another protocol.
export async function health(udid: string): Promise<'up' | 'down' | 'other'> {
  const socket = await connect(udid, PORT, HEALTH_TIMEOUT_MS);
  if (socket === 'refused') return 'down';
  let body: string;
  try {
    ({ body } = await get(socket, '/health', HEALTH_TIMEOUT_MS));
  } catch (err) {
    if (cancellation.getStore()?.aborted) throw err;
    // A runner that accepts and does not answer is treated as gone; starting another reports why it cannot.
    return 'down';
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    // Not the runner's JSON: something else listens on the port.
    return 'other';
  }
  return isRecord(parsed) && parsed.protocol === PROTOCOL ? 'up' : 'other';
}

// The .xctestrun of the installed runner's team, built by this karagoz and Xcode. The check keeps test-without-building,
// which installs as part of a run, from putting a runner on a phone that has none (K13, K41).
async function installedBuild(udid: string, dev: string): Promise<string> {
  const runners = (await apps(udid)).flatMap(({ id }) => {
    const team = teamOf(id);
    return team === undefined ? [] : [team];
  });
  if (!runners.length) throw notInstalled(udid, 'is not installed');
  const { root } = await runnerBuild(dev);
  for (const team of runners) {
    const products = join(root, team, 'Build', 'Products');
    const files = await readdir(products).catch(() => []);
    const xctestrun = files.find((file) => file.endsWith('.xctestrun'));
    if (xctestrun) return join(products, xctestrun);
  }
  throw notInstalled(udid, 'was built by another karagoz or Xcode, or its build was deleted,');
}

// What the iPhone's user or the caller does, by xcodebuild's log, first match wins. 0xe8008012 is from a captured log;
// the other texts come from sources and 4.3's phone run (K41).
function startFailure(udid: string, log: string, output: string): KaragozError {
  const lower = output.toLowerCase();
  const states: [string[], ErrorCode, string][] = [
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

// Starts the runner with xcodebuild test-without-building, detached: it outlives this call and ends with the runner's
// idle stop. Only the start budget bounds this call; a start nobody waits for is killed with its process group (K41).
async function start(udid: string, dev: string): Promise<void> {
  const xctestrun = await installedBuild(udid, dev);
  await ownedDir(join(CACHE_ROOT, 'runner'));
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
  const signal = cancellation.getStore();
  const deadline = Date.now() + START_BUDGET_MS;
  try {
    for (;;) {
      if (ended.exited) throw startFailure(udid, log, await readFile(log, 'utf8').catch(() => ''));
      const state = await health(udid);
      if (state === 'up') return;
      if (state === 'other') throw notInstalled(udid, "answering on its port is not this karagoz's");
      if (Date.now() > deadline) {
        throw new KaragozError(
          'DEVICE_NOT_READY',
          `device ${udid} is not ready: karagoz's runner did not start within ${START_BUDGET_MS / 1000} s. Look at the iPhone: unlock it, enter the passcode if it asks to enable UI automation, and check that Settings > Developer > Enable UI Automation is on (log: ${log}).`,
        );
      }
      await sleep(POLL_MS, undefined, signal && { signal });
    }
  } catch (err) {
    if (!ended.exited && child.pid !== undefined) {
      try {
        process.kill(-child.pid, 'SIGTERM');
      } catch {
        // Already gone: nothing to stop.
      }
    }
    throw err;
  }
}

// Runs work while holding the phone's lock file, so concurrent first calls start one runner (K3 4.0 note).
async function locked<T>(udid: string, work: () => Promise<T>): Promise<T> {
  const dir = join(CACHE_ROOT, 'locks');
  await ownedDir(dir);
  const path = join(dir, `${udid}.lock`);
  const signal = cancellation.getStore();
  // The holder's own start budget, plus slack for its health checks.
  const deadline = Date.now() + START_BUDGET_MS + 10_000;
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
        throw new KaragozError(
          'HELPER_FAILED',
          `another karagoz call kept ${path} for over ${(START_BUDGET_MS + 10_000) / 1000} s`,
        );
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
  if (state === 'other') throw notInstalled(udid, "answering on its port is not this karagoz's");
  const dev = await xcode();
  await locked(udid, async () => {
    const again = await health(udid);
    if (again === 'up') return;
    if (again === 'other') throw notInstalled(udid, "answering on its port is not this karagoz's");
    await start(udid, dev);
  });
}

// The raw snapshot of what is on the iPhone's screen, from the runner (K41).
export async function tree(udid: string): Promise<unknown> {
  await ensure(udid);
  const socket = await connect(udid, PORT, HEALTH_TIMEOUT_MS);
  if (socket === 'refused') throw new KaragozError('CAPTURE_FAILED', "karagoz's runner stopped before it answered");
  const { status, body } = await get(socket, '/tree', READ_TIMEOUT_MS);
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new KaragozError('CAPTURE_FAILED', `cannot parse the runner's answer: ${body.slice(0, 100)}`);
  }
  if (status === 200 && isRecord(parsed) && parsed.root !== undefined) return parsed.root;
  const error = isRecord(parsed) && typeof parsed.error === 'string' ? parsed.error : `status ${status}`;
  if (isRecord(parsed) && parsed.kind === 'private') {
    throw new KaragozError(
      'HELPER_FAILED',
      `${error}: this iOS changed an interface karagoz's runner uses; update karagoz`,
    );
  }
  throw new KaragozError('CAPTURE_FAILED', error);
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
