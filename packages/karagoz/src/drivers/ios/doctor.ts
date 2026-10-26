import { access, constants, readdir, readFile, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { KaragozError } from '../../errors.js';
import { COREDEVICE_PLIST, devicectlPath } from './devicectl.js';
import { notOnPath } from './logs.js';
import { runnerBuild, xcodebuild, xctestrun } from './runner.js';
import { binary, EXPECTED, FRAMEWORK_PLIST } from './simctl.js';
import { helperPath, swiftc } from './ui-tree.js';
import { daemonPath, unreachable } from './usbmux.js';
import { bundleVersion, DTUHIDD_FROM, NO_XCODE, noTeam, older, owns, selected, teams, type Team } from './xcode.js';

// doctor reads files, and runs nothing but plutil, which only converts Xcode's preference file and the CoreSimulator
// and CoreDevice Info.plists, binary on some Macs. simctl would start CoreSimulatorService and rewrite
// device_set.plist, and a shim under DEVELOPER_DIR can start Xcode's first launch, which waits for a password (K30 3.7
// note, K32, K41). xcodebuild can do the same, and usbmuxd is not connected to (K30 4.7).

type Entry = { status: 'ok' | 'missing' | 'failed'; path?: string; version?: string; message?: string };
type Helper = { status: 'ok' | 'not built' | 'failed'; path?: string; message?: string };
type Signing = { status: 'ok' | 'missing' | 'failed'; teams?: Team[]; message?: string };
type RunnerBuild = { status: 'ok' | 'not built' | 'failed'; path?: string; teams?: string[]; message?: string };
type Report = {
  xcode: {
    status: 'ok' | 'outdated' | 'failed' | 'missing';
    source?: 'DEVELOPER_DIR' | 'xcode-select' | 'default';
    path?: string;
    version?: string;
    build?: string;
    message?: string;
    simctl: Entry;
    swiftc: Entry;
    devicectl: Entry;
    helper: Helper;
    signing: Signing;
    iosRunner: RunnerBuild;
    xcodebuild: Entry;
    usbmuxd: Entry;
    tar: Entry;
    log: Entry;
  };
};

// tap, swipe and key need Xcode 27's simulator HID service (K35), text its automation session (K47).
const FLOOR = 27;
const OUTDATED = `tap, swipe, text and key on a simulator need Xcode ${FLOOR} or later`;

// Below CoreSimulator 1155.4 karagoz's runner plays the four inside the simulator, whatever the Xcode (K49).
const runnerCovers = (entry: Entry) => entry.version !== undefined && older(entry.version, DTUHIDD_FROM);

const text = (path: string) => readFile(path, 'utf8').catch(() => '');
const plistString = (plist: string, key: string) =>
  new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`).exec(plist)?.[1];

// What spawn would hit: stat follows links as exec does, and access(X_OK) alone passes a directory.
async function tool(path: string, missing: string): Promise<Entry> {
  try {
    if (!(await stat(path)).isFile()) return { status: 'failed', path, message: `cannot run ${path} (EISDIR)` };
    await access(path, constants.X_OK);
    return { status: 'ok', path };
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    const code = 'code' in err ? String(err.code) : err.message;
    if (code === 'ENOENT') return { status: 'missing', path, message: missing };
    return { status: 'failed', path, message: `cannot run ${path} (${code})` };
  }
}

const errCode = (err: Error) => ('code' in err ? String(err.code) : err.message);

// The socket the runner and an iPhone's logs connect to, judged without connecting: connect() gives ENOTSOCK for
// anything but a socket (measured on a file and a directory).
async function socket(): Promise<Entry> {
  const path = daemonPath();
  try {
    if (!(await stat(path)).isSocket()) return { status: 'failed', path, message: unreachable(path, 'ENOTSOCK') };
    await access(path, constants.R_OK | constants.W_OK);
    return { status: 'ok', path };
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    const status = errCode(err) === 'ENOENT' ? 'missing' : 'failed';
    return { status, path, message: unreachable(path, errCode(err)) };
  }
}

// iPhone logs spawns tar and log by bare name, so libuv walks PATH (unset: /usr/bin:/bin; an empty entry is the cwd):
// ENOENT and ENOTDIR go on, a file it cannot run is remembered and passed over, any other error stops (R3, K30 4.7).
async function executable(name: 'tar' | 'log'): Promise<Entry> {
  let denied: string | undefined;
  for (const dir of (process.env.PATH ?? '/usr/bin:/bin').split(':')) {
    const path = resolve(dir, name);
    try {
      if ((await stat(path)).isFile()) {
        await access(path, constants.X_OK);
        return { status: 'ok', path };
      }
      denied ??= path;
    } catch (err) {
      if (!(err instanceof Error)) throw err;
      if (errCode(err) === 'EACCES') denied ??= path;
      else if (errCode(err) !== 'ENOENT' && errCode(err) !== 'ENOTDIR')
        return { status: 'failed', path, message: `cannot run ${path} (${errCode(err)})` };
    }
  }
  return denied
    ? { status: 'failed', path: denied, message: `cannot run ${denied} (EACCES)` }
    : { status: 'missing', message: notOnPath(name) };
}

// A missing or older framework than the selected Xcode's shim names: its first launch has not finished. A newer one is
// fine: karagoz runs the framework's binary, never the shim that would run `xcodebuild -runFirstLaunch` for it (K32,
// K48).
function firstLaunch(framework: string, shim: string, current: string | undefined) {
  const expected = EXPECTED.exec(shim)?.[1];
  if (expected === undefined || (current && !older(current, expected))) return undefined;
  return `the selected Xcode expects ${framework} ${expected}, this Mac has ${current ?? 'none'}: open Xcode once to finish installing its components`;
}

async function simctl(dev: string | undefined): Promise<Entry> {
  const { bin, missing } = await binary();
  const [entry, framework, shim] = await Promise.all([
    tool(bin, missing),
    // Binary on an Xcode 26 Mac, XML on another; a KaragozError is plutil's timeout, reported like devicectl's.
    bundleVersion(FRAMEWORK_PLIST).catch((err: unknown) => {
      if (err instanceof KaragozError) return err;
      throw err;
    }),
    dev ? text(join(dev, 'usr', 'bin', 'simctl')) : '',
  ]);
  if (entry.status === 'missing') return entry;
  const version = framework instanceof KaragozError ? undefined : framework;
  const problem =
    entry.status !== 'ok'
      ? undefined
      : framework instanceof KaragozError
        ? framework.message
        : firstLaunch('CoreSimulator', shim, version);
  const message = problem ?? entry.message;
  return {
    status: problem ? 'failed' : entry.status,
    path: bin,
    ...(version !== undefined && { version }),
    ...(message !== undefined && { message }),
  };
}

async function devicectl(dev: string | undefined): Promise<Entry> {
  const path = await devicectlPath();
  const [entry, shim] = await Promise.all([
    tool(
      path,
      `devicectl not found (tried ${path}): iPhones are not listed or reachable, and a simulator's rotation reads as null`,
    ),
    dev ? text(join(dev, 'usr', 'bin', 'devicectl')) : '',
  ]);
  if (entry.status !== 'ok' || !EXPECTED.test(shim)) return entry;
  let problem: string | undefined;
  try {
    problem = firstLaunch('CoreDevice', shim, await bundleVersion(COREDEVICE_PLIST));
  } catch (err) {
    if (!(err instanceof KaragozError)) throw err;
    problem = err.message;
  }
  return problem ? { status: 'failed', path, message: problem } : entry;
}

async function helper(dev: string | undefined): Promise<Helper> {
  if (!dev) return { status: 'not built' };
  let bin: string | undefined;
  try {
    const paths = await helperPath(dev);
    bin = paths.bin;
    const built =
      (await owns(paths.root, 'directory')) && (await owns(paths.dir, 'directory')) && (await owns(bin, 'file'));
    return { status: built ? 'ok' : 'not built', path: bin };
  } catch (err) {
    if (!(err instanceof KaragozError)) throw err;
    return { status: 'failed', ...(bin !== undefined && { path: bin }), message: err.message };
  }
}

// The Apple development teams karagoz's iPhone runner can be built with (K41).
async function signing(): Promise<Signing> {
  let found: { signedIn: boolean; teams: Team[] };
  try {
    found = await teams();
  } catch (err) {
    if (!(err instanceof KaragozError)) throw err;
    return { status: 'failed', message: err.message };
  }
  if (!found.teams.length)
    return {
      status: 'missing',
      message: `${noTeam(found.signedIn)}, to build karagoz's iPhone runner with install-runner`,
    };
  return { status: 'ok', teams: found.teams };
}

// The runner builds this karagoz and Xcode have, one per team (install-runner makes them).
async function iosRunner(dev: string | undefined): Promise<RunnerBuild> {
  if (!dev) return { status: 'not built' };
  let root: string | undefined;
  try {
    root = await runnerBuild(dev);
    if (!(await owns(root, 'directory'))) return { status: 'not built', path: root };
    const built: string[] = [];
    for (const team of (await readdir(root)).sort()) {
      if (await xctestrun(root, team)) built.push(team);
    }
    return built.length ? { status: 'ok', path: root, teams: built } : { status: 'not built', path: root };
  } catch (err) {
    if (!(err instanceof KaragozError)) throw err;
    return { status: 'failed', ...(root !== undefined && { path: root }), message: err.message };
  }
}

export async function doctor(): Promise<Report> {
  const found = await selected();
  const dev = found?.dev;
  const compiler = dev ? swiftc(dev) : undefined;
  const builder = dev ? xcodebuild(dev) : undefined;
  const [
    plist,
    simctlEntry,
    swiftcEntry,
    devicectlEntry,
    helperEntry,
    signingEntry,
    runnerEntry,
    xcodebuildEntry,
    usbmuxdEntry,
    tarEntry,
    logEntry,
  ] = await Promise.all([
    // Text, not join(): join drops '..' lexically, while the kernel resolves a DEVELOPER_DIR symlink to Developer first.
    dev ? text(`${dev}/../version.plist`) : '',
    simctl(dev),
    compiler ? tool(compiler.bin, compiler.missing) : ({ status: 'missing', message: NO_XCODE } satisfies Entry),
    devicectl(dev),
    helper(dev),
    signing(),
    iosRunner(dev),
    builder ? tool(builder.bin, builder.missing) : ({ status: 'missing', message: NO_XCODE } satisfies Entry),
    socket(),
    executable('tar'),
    executable('log'),
  ]);
  const version = plistString(plist, 'CFBundleShortVersionString');
  const build = plistString(plist, 'ProductBuildVersion');
  const tools = [simctlEntry, swiftcEntry, devicectlEntry];
  const status =
    simctlEntry.status === 'missing' && swiftcEntry.status === 'missing'
      ? 'missing'
      : tools.some((entry) => entry.status !== 'ok') || helperEntry.status === 'failed'
        ? 'failed'
        : version !== undefined && Number(version.split('.')[0]) < FLOOR && !runnerCovers(simctlEntry)
          ? 'outdated'
          : 'ok';
  const message =
    status === 'outdated'
      ? OUTDATED
      : [...tools, helperEntry].find((entry) => entry.status !== 'ok' && entry.status !== 'not built')?.message;
  return {
    xcode: {
      status,
      ...(found && { source: found.source, path: found.dev }),
      ...(version !== undefined && { version }),
      ...(build !== undefined && { build }),
      ...(message !== undefined && { message }),
      simctl: simctlEntry,
      swiftc: swiftcEntry,
      devicectl: devicectlEntry,
      helper: helperEntry,
      signing: signingEntry,
      iosRunner: runnerEntry,
      // What the iPhone runner and logs need; like signing and iosRunner, outside status (K30 4.7).
      xcodebuild: xcodebuildEntry,
      usbmuxd: usbmuxdEntry,
      tar: tarEntry,
      log: logEntry,
    },
  };
}
