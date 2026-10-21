import { execFile } from 'node:child_process';
import { access, lstat, mkdir, readFile, readlink } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { isRecord } from './record.js';
import { developerDir } from './simctl.js';

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

// The selected Xcode's build (ProductBuildVersion), or '' when its version.plist is missing. The path is text, not
// join(): join drops '..' lexically, while the kernel resolves a DEVELOPER_DIR symlink to Developer first.
export async function buildVersion(dev: string): Promise<string> {
  const plist = await readFile(`${dev}/../version.plist`, 'utf8').catch(() => '');
  return /<key>ProductBuildVersion<\/key>\s*<string>([^<]*)<\/string>/.exec(plist)?.[1] ?? '';
}

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

// One key of Xcode's preferences as JSON, undefined when the file or key is missing. plutil only reads and converts the
// file; no Xcode process starts (K41).
async function preference(key: string): Promise<unknown> {
  const prefs = join(homedir(), 'Library', 'Preferences', 'com.apple.dt.Xcode.plist');
  const signal = cancellation.getStore();
  signal?.throwIfAborted();
  let stdout: string;
  try {
    ({ stdout } = await run('/usr/bin/plutil', ['-extract', key, 'json', '-o', '-', prefs], {
      timeout: PLUTIL_TIMEOUT_MS,
      ...(signal && { signal }),
    }));
  } catch (err) {
    // The SDK sends no response for a cancelled call, so the abort passes through (K31).
    if (signal?.aborted) throw err;
    if (!(err instanceof Error)) throw err;
    if ('killed' in err && err.killed) {
      throw new KaragozError('HELPER_FAILED', `plutil did not read ${prefs} within ${PLUTIL_TIMEOUT_MS / 1000} s`);
    }
    // plutil exits 1 when the file or the key is missing.
    return undefined;
  }
  try {
    return JSON.parse(stdout);
  } catch {
    // plutil printed something other than JSON: read as missing, which the callers explain.
    return undefined;
  }
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
