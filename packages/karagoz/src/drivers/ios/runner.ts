import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { apps, installApp, profiles, removeProfile, uninstallApp } from './devicectl.js';
import { buildVersion, CACHE_ROOT, owns, teams, xcode } from './xcode.js';

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
