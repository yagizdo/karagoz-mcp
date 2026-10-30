import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { copyFile, mkdir, open, readdir, readFile, writeFile, type FileHandle } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { apps, installApp, PHONE_TIMEOUT_MS, profiles, removeProfile, uninstallApp } from './devicectl.js';
import { simctl } from './simctl.js';
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
// From xcodebuild's start to the runner's first answer; prior art budgets 45-60 s, 4.3's phone run measured it (K41).
export const START_BUDGET_MS = 60_000;
// How long a call waits for a phone's lock: the holder's devicectl app list, its start budget, and slack for the health
// checks around them.
export const PHONE_LOCK_MS = PHONE_TIMEOUT_MS + START_BUDGET_MS + 15_000;
export const POLL_MS = 500;
// Darwin's O_EXLOCK, which Node does not name: open() takes an exclusive lock the kernel drops when its holder exits,
// crashed or not, so a lock file needs no staleness rule (K41).
const O_EXLOCK = 0x20;

// The xcodebuild that builds and starts the runner, with the message for its absence; doctor reads the same (K30 4.7).
export function xcodebuild(dev: string): { bin: string; missing: string } {
  return {
    bin: join(dev, 'usr', 'bin', 'xcodebuild'),
    missing: `xcodebuild not found in ${dev}; install Xcode and select it (xcode-select -s <Xcode.app>)`,
  };
}

// The test bundle's id for a team; the team keeps it unique on a free account (K41).
function runnerId(team: string): string {
  return ID_PREFIX + team.toLowerCase();
}

// The team in an installed runner's app id, com.karagozmcp.runner.<team>.xctrunner; undefined for any other app.
export function teamOf(appId: string): string | undefined {
  if (!appId.startsWith(ID_PREFIX) || !appId.endsWith(APP_SUFFIX)) return undefined;
  const team = appId.slice(ID_PREFIX.length, -APP_SUFFIX.length).toUpperCase();
  return TEAM.test(team) ? team : undefined;
}

// Where this karagoz's runner, built by this Xcode, lives: one directory per team below it for an iPhone, and under
// runner-sim the simulator build, kept apart because doctor reads every directory under runner as a team (K49).
export async function runnerBuild(dev: string, dir: 'runner' | 'runner-sim' = 'runner'): Promise<string> {
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
  return join(CACHE_ROOT, dir, key);
}

// The .xctestrun the build in root/folder (a team, or the simulator build) left, undefined when there is none. Xcode
// names it KaragozRunner_<sdk>; the session copies start() writes beside it are not builds (K42).
export async function xctestrun(root: string, folder: string): Promise<string | undefined> {
  const products = join(root, folder, 'Build', 'Products');
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

// Copies the project into derived/project and builds it for testing there; extra holds the destination and, for an
// iPhone, the signing settings.
async function build(dev: string, derived: string, extra: string[]): Promise<void> {
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
      xcodebuild(dev).bin,
      [
        '-quiet',
        'build-for-testing',
        '-project',
        join(project, 'KaragozRunner.xcodeproj'),
        '-scheme',
        'KaragozRunner',
        '-derivedDataPath',
        derived,
        ...extra,
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
      throw new KaragozError('HELPER_FAILED', xcodebuild(dev).missing);
    }
    const errors = output.split('\n').filter((line) => line.includes('error:'));
    const reason = (
      errors.length ? [...new Set(errors.map((line) => line.trim()))].slice(0, 3).join(' ') : err.message
    ).slice(0, 300);
    throw new KaragozError('HELPER_FAILED', `the runner build failed: ${reason} (log: ${log})`);
  }
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
  await locked(`team-${team}`, BUILD_LOCK_MS, () =>
    build(dev, derived, [
      '-destination',
      `id=${udid}`,
      '-allowProvisioningUpdates',
      '-allowProvisioningDeviceRegistration',
      `DEVELOPMENT_TEAM=${team}`,
      `PRODUCT_BUNDLE_IDENTIFIER=${id}`,
      'CODE_SIGN_STYLE=Automatic',
    ]),
  );
  await installApp(udid, join(derived, 'Build', 'Products', 'Debug-iphoneos', 'KaragozRunner-Runner.app'));
  return { device: udid, bundleId: id + APP_SUFFIX, team };
}

// The simulator build of this karagoz and Xcode, made by the first input that needs it: no team and no signing
// settings, so Xcode signs it to run locally. One build serves every simulator (K49).
export async function simulatorBuild(udid: string, dev: string): Promise<string> {
  const root = await runnerBuild(dev, 'runner-sim');
  await ownedDir(join(CACHE_ROOT, 'runner-sim'));
  await ownedDir(root);
  const derived = join(root, 'build');
  return locked(`runner-sim-${basename(root)}`, BUILD_LOCK_MS, async () => {
    const found = await xctestrun(root, 'build');
    if (found) return found;
    await ownedDir(derived);
    await build(dev, derived, ['-destination', `id=${udid}`]);
    const built = await xctestrun(root, 'build');
    if (built) return built;
    throw new KaragozError(
      'HELPER_FAILED',
      `xcodebuild built karagoz's runner but left no .xctestrun (log: ${join(derived, 'build.log')})`,
    );
  });
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

// The runner app on a simulator: the build keeps the project's bundle id, which no team suffix makes unique there.
const SIMULATOR_APP = 'com.karagozmcp.runner' + APP_SUFFIX;

// Removes the runner from a simulator. Its running xcodebuild ends by itself within about 25 s (measured); a start
// meanwhile works, on a new port (K49).
export async function uninstallSimulatorRunner(udid: string) {
  return locked(udid, PHONE_LOCK_MS, async () => {
    const installed = (await simctl(['listapps', udid])).includes(`"${SIMULATOR_APP}"`);
    if (installed) await simctl(['uninstall', udid, SIMULATOR_APP], undefined, 'UNINSTALL_FAILED');
    return { device: udid, apps: installed ? [SIMULATOR_APP] : [], profiles: [] };
  });
}

// Runs work while holding the lock file name.lock, waiting up to waitMs for it: a phone's UDID, so concurrent first calls
// start one runner and an uninstall waits for a start (K3 4.0 note), or team-<ID> for one build at a time.
export async function locked<T>(name: string, waitMs: number, work: () => Promise<T>): Promise<T> {
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
