import { access, lstat, readFile, readlink } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { KaragozError } from '../../errors.js';
import { developerDir } from './simctl.js';

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

// The selected Xcode's build (ProductBuildVersion), or '' when its version.plist is missing.
export async function buildVersion(dev: string): Promise<string> {
  const plist = await readFile(join(dev, '..', 'version.plist'), 'utf8').catch(() => '');
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
