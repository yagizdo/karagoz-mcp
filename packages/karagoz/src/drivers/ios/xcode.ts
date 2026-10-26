import { execFile } from 'node:child_process';
import { access, lstat, mkdir, readFile, readlink } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { isRecord } from './record.js';
import { binary, developerDir } from './simctl.js';

const run = promisify(execFile);

const XCODE_SELECT = '/var/db/xcode_select_link';
const DEFAULT_XCODE = '/Applications/Xcode.app/Contents/Developer';
// The simulator helper and the iPhone runner build here, one directory per key (K34, K41).
export const CACHE_ROOT = join(homedir(), 'Library', 'Caches', 'karagoz');
export const CACHE_HINT = 'delete ~/Library/Caches/karagoz';

export const NO_XCODE = `no Xcode selected: set DEVELOPER_DIR or run xcode-select -s <Xcode.app> (${XCODE_SELECT} and ${DEFAULT_XCODE} are missing)`;

// The developer dir the helper builds with, and which rule picked it; undefined when there is none. doctor reports the
// same lookup the commands use (K30).
export async function selected(): Promise<
  { dev: string; source: 'DEVELOPER_DIR' | 'xcode-select' | 'default' } | undefined
> {
  const dev = developerDir();
  if (dev) return { dev, source: 'DEVELOPER_DIR' };
  try {
    return { dev: await readlink(XCODE_SELECT), source: 'xcode-select' };
  } catch {
    // No link (never selected, or xcode-select -r): xcode-select's default search, which xcrun follows, takes over.
  }
  try {
    await access(DEFAULT_XCODE);
    return { dev: DEFAULT_XCODE, source: 'default' };
  } catch {
    // Neither is there: no Xcode is selected.
    return undefined;
  }
}

export async function xcode(): Promise<string> {
  const found = await selected();
  // The message says how to pick one.
  if (!found) throw new KaragozError('HELPER_FAILED', NO_XCODE);
  return found.dev;
}

// One key of the selected Xcode's version.plist, or '' when the file is missing. The path is text, not join(): join
// drops '..' lexically, while the kernel resolves a DEVELOPER_DIR symlink to Developer first.
async function versionKey(dev: string, key: string): Promise<string> {
  const plist = await readFile(`${dev}/../version.plist`, 'utf8').catch(() => '');
  return new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`).exec(plist)?.[1] ?? '';
}

// The selected Xcode's build, such as 27A9275.
export const buildVersion = (dev: string) => versionKey(dev, 'ProductBuildVersion');
// The selected Xcode's version, such as 27.1.
export const shortVersion = (dev: string) => versionKey(dev, 'CFBundleShortVersionString');

// The cache sits in the user's home, but a directory or binary someone else owns there is refused, as screenshot
// refuses a shared temp directory (src/screenshot.ts).
const owned = (info: { uid: number }) => !process.getuid || info.uid === process.getuid();

// true when the user's own directory or file is at path, false when nothing is there yet.
export async function owns(path: string, kind: 'directory' | 'file'): Promise<boolean> {
  let info;
  try {
    info = await lstat(path);
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    const code = 'code' in err ? String(err.code) : err.message;
    if (code === 'ENOENT') return false;
    throw new KaragozError('HELPER_FAILED', `cannot check ${path} (${code}); ${CACHE_HINT}`);
  }
  if (!(kind === 'directory' ? info.isDirectory() : info.isFile()) || !owned(info)) {
    throw new KaragozError('HELPER_FAILED', `${path} is not a ${kind} owned by the current user; ${CACHE_HINT}`);
  }
  return true;
}

// The user's own directory at path, created when missing.
export async function ownedDir(path: string): Promise<void> {
  try {
    await mkdir(path, { recursive: true, mode: 0o700 });
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    throw new KaragozError('HELPER_FAILED', err.message);
  }
  await owns(path, 'directory');
}

// Converting one preference file takes milliseconds; the timeout only bounds a stuck plutil.
const PLUTIL_TIMEOUT_MS = 5_000;

export type Team = { id: string; name: string; free: boolean };

// One key of a property list in plutil's json or raw form, undefined when the file or key is missing. plutil only reads
// and converts the file, binary or XML; no Xcode process starts (K41).
async function plistValue(path: string, key: string, form: 'json' | 'raw'): Promise<string | undefined> {
  const signal = cancellation.getStore();
  signal?.throwIfAborted();
  let stdout: string;
  try {
    ({ stdout } = await run('/usr/bin/plutil', ['-extract', key, form, '-o', '-', path], {
      timeout: PLUTIL_TIMEOUT_MS,
      ...(signal && { signal }),
    }));
  } catch (err) {
    // The SDK sends no response for a cancelled call, so the abort passes through (K31).
    if (signal?.aborted) throw err;
    if (!(err instanceof Error)) throw err;
    if ('killed' in err && err.killed) {
      throw new KaragozError('HELPER_FAILED', `plutil did not read ${path} within ${PLUTIL_TIMEOUT_MS / 1000} s`);
    }
    // plutil exits 1 when the file or the key is missing.
    return undefined;
  }
  return stdout;
}

async function preference(key: string): Promise<unknown> {
  const stdout = await plistValue(join(homedir(), 'Library', 'Preferences', 'com.apple.dt.Xcode.plist'), key, 'json');
  try {
    return stdout === undefined ? undefined : JSON.parse(stdout);
  } catch {
    // plutil printed something other than JSON: read as missing, which the callers explain.
    return undefined;
  }
}

// A framework's CFBundleVersion, undefined when it cannot be read. CoreDevice's Info.plist is binary, and holds values
// JSON cannot carry, so plutil's json form refuses it (K47).
export async function bundleVersion(plist: string): Promise<string | undefined> {
  return (await plistValue(plist, 'CFBundleVersion', 'raw'))?.trim() || undefined;
}

// Numeric per component, a missing component counting as 0, as the simctl shim's version sort does.
export function older(a: string, b: string): boolean {
  const x = a.split('.').map(Number);
  const y = b.split('.').map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) < (y[i] ?? 0);
  }
  return false;
}

// The CoreSimulator of the simctl karagoz runs: the Info.plist of its framework, or beside the bin folder of a simctl
// under DEVELOPER_DIR that is not Apple's shim (the smokes' fakes). undefined when there is none.
export async function coreSimulator(): Promise<string | undefined> {
  const { bin } = await binary();
  return bundleVersion(join(dirname(bin), '..', 'Info.plist'));
}

// The simulator's own input service, dtuhidd, came with CoreSimulator 1155.4. Any newer Xcode overwrites the framework,
// so its version, not the selected Xcode's, says whether it is there (K49).
export const DTUHIDD_FROM = '1155.4';

// Below that version karagoz's runner plays tap, swipe, text and key inside the simulator (K49). An unreadable version
// keeps the helper's path, which reports what it finds.
export async function runnerOnSimulators(): Promise<boolean> {
  const version = await coreSimulator();
  return version !== undefined && older(version, DTUHIDD_FROM);
}

// The development teams of the Apple accounts signed in to Xcode. Xcode writes them only once it has shown a team list,
// such as a project's Signing & Capabilities tab, not at sign-in (measured, K41).
export async function teams(): Promise<{ signedIn: boolean; teams: Team[] }> {
  const [byAccount, accounts] = await Promise.all([
    preference('IDEProvisioningTeamByIdentifier'),
    preference('DVTDeveloperAccountManagerAppleIDLists'),
  ]);
  const found = new Map<string, Team>();
  for (const list of isRecord(byAccount) ? Object.values(byAccount) : []) {
    for (const team of Array.isArray(list) ? list : []) {
      if (!isRecord(team) || typeof team.teamID !== 'string' || found.has(team.teamID)) continue;
      found.set(team.teamID, {
        id: team.teamID,
        name: typeof team.teamName === 'string' ? team.teamName : '',
        free: team.isFreeProvisioningTeam === true,
      });
    }
  }
  const signedIn = isRecord(accounts) && Object.values(accounts).some((ids) => Array.isArray(ids) && ids.length > 0);
  return { signedIn: signedIn || found.size > 0, teams: [...found.values()] };
}

// What to tell someone whose Xcode lists no team, by whether an account is signed in.
export function noTeam(signedIn: boolean): string {
  return signedIn
    ? "Xcode has your Apple account but has not saved its teams yet: open any project's Signing & Capabilities tab in Xcode once, or pass --team <Team ID>"
    : 'Xcode lists no Apple account: sign in to Xcode > Settings > Accounts with your Apple ID';
}
