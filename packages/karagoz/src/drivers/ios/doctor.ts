import { access, constants, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { KaragozError } from '../../errors.js';
import { devicectlPath } from './devicectl.js';
import { binary, FRAMEWORK_PLIST } from './simctl.js';
import { helperPath, NO_XCODE, owns, selected, swiftc } from './ui-tree.js';

// doctor reads files only. simctl would start CoreSimulatorService and rewrite device_set.plist, and a shim under
// DEVELOPER_DIR can start Xcode's first launch, which waits for a password (K30 3.7 note, K32).

type Entry = { status: 'ok' | 'missing' | 'failed'; path?: string; version?: string; message?: string };
type Helper = { status: 'ok' | 'not built' | 'failed'; path?: string; message?: string };
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
  };
};

// tap, swipe and key need Xcode 27's simulator HID service (K35).
const FLOOR = 27;
const OUTDATED = `tap, swipe and key on a simulator need Xcode ${FLOOR} or later`;
// The first line of Xcode 27's simctl shim that names the CoreSimulator it was built for (K32).
const EXPECTED = /^EXPECTED_VERSION="([^"]+)"$/m;

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

// Numeric per component, a missing component counting as 0, as the shim's version sort does.
function older(a: string, b: string): boolean {
  const x = a.split('.').map(Number);
  const y = b.split('.').map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) < (y[i] ?? 0);
  }
  return false;
}

async function simctl(dev: string | undefined): Promise<Entry> {
  const { bin, missing } = binary();
  const [entry, framework, shim] = await Promise.all([
    tool(bin, missing),
    text(FRAMEWORK_PLIST),
    dev ? text(join(dev, 'usr', 'bin', 'simctl')) : '',
  ]);
  if (entry.status === 'missing') return entry;
  const version = plistString(framework, 'CFBundleVersion');
  const expected = EXPECTED.exec(shim)?.[1];
  // The shim's own rule: an older framework means Xcode's first launch has not finished. Without DEVELOPER_DIR
  // karagoz skips the shim, but the install is still incomplete. ponytail: Xcode 26.2's shim also runs it for a newer
  // framework, which this misses; revisit with K32 M1 before v1.
  const pending = entry.status === 'ok' && expected !== undefined && (!version || older(version, expected));
  const message = pending
    ? `the selected Xcode expects CoreSimulator ${expected}, this Mac has ${version ?? 'none'}: open Xcode once to finish installing its components`
    : entry.message;
  return {
    status: pending ? 'failed' : entry.status,
    path: bin,
    ...(version !== undefined && { version }),
    ...(message !== undefined && { message }),
  };
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

export async function doctor(): Promise<Report> {
  const found = await selected();
  const dev = found?.dev;
  const compiler = dev ? swiftc(dev) : undefined;
  const devicectl = devicectlPath();
  const [plist, simctlEntry, swiftcEntry, devicectlEntry, helperEntry] = await Promise.all([
    dev ? text(join(dev, '..', 'version.plist')) : '',
    simctl(dev),
    compiler ? tool(compiler.bin, compiler.missing) : ({ status: 'missing', message: NO_XCODE } satisfies Entry),
    tool(devicectl, `devicectl not found (tried ${devicectl}): rotation reads as null, taken as portrait`),
    helper(dev),
  ]);
  const version = plistString(plist, 'CFBundleShortVersionString');
  const build = plistString(plist, 'ProductBuildVersion');
  const tools = [simctlEntry, swiftcEntry, devicectlEntry];
  const status =
    simctlEntry.status === 'missing' && swiftcEntry.status === 'missing'
      ? 'missing'
      : tools.some((entry) => entry.status !== 'ok') || helperEntry.status === 'failed'
        ? 'failed'
        : version !== undefined && Number(version.split('.')[0]) < FLOOR
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
    },
  };
}
