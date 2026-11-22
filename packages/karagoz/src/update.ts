import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pkg from '../package.json' with { type: 'json' };

// At most one registry request a day (K78).
const INTERVAL_MS = 24 * 60 * 60 * 1000;
// The registry answers dist-tags in under 0.7 s (measured, K78). Nobody waits for the refresh, so this only ends a
// stuck request.
const TIMEOUT_MS = 5_000;
// Only a plain release counts. The value reaches the MCP client's model, so nothing else from the cache or the
// registry may pass.
const VERSION = /^(\d+)\.(\d+)\.(\d+)$/;

export type Update = {
  // The newer release, when the last check found one.
  newer: string | undefined;
  install: 'npm' | 'mcpb';
  // The last check is older than a day, or there is none.
  due: boolean;
};

type Cache = { checked: number; latest: string };

// Only a global npm install and the Desktop extension stay old. npx re-resolves an unversioned spec on every start
// (P0); a project's own node_modules, npx's cache and a clone, where the smokes run, are another layout, and
// npm install -g would not update them.
function install(): Update['install'] | undefined {
  if (process.env.KARAGOZ_INSTALL === 'mcpb') return 'mcpb';
  // The module's own path: symlinks are resolved, unlike argv[1], which is the bin link. npm's global folder is
  // <prefix>/lib/node_modules, and %APPDATA%\\npm\\node_modules on Windows.
  const path = fileURLToPath(import.meta.url);
  return /[\\/](lib|npm)[\\/]node_modules[\\/]karagoz-mcp[\\/]/.test(path) ? 'npm' : undefined;
}

function off(): boolean {
  const { env } = process;
  return Boolean(env.KARAGOZ_NO_UPDATE_CHECK || env.NO_UPDATE_NOTIFIER || env.CI);
}

function cacheFile(): string | undefined {
  const { env } = process;
  const xdg = env.XDG_CACHE_HOME && isAbsolute(env.XDG_CACHE_HOME) ? env.XDG_CACHE_HOME : undefined;
  const base =
    process.platform === 'darwin'
      ? join(homedir(), 'Library', 'Caches')
      : process.platform === 'win32'
        ? env.LOCALAPPDATA
        : (xdg ?? join(homedir(), '.cache'));
  return base ? join(base, 'karagoz', 'update.json') : undefined;
}

async function readCache(file: string): Promise<Cache | undefined> {
  try {
    const data: unknown = JSON.parse(await readFile(file, 'utf8'));
    if (
      typeof data === 'object' &&
      data !== null &&
      'checked' in data &&
      typeof data.checked === 'number' &&
      'latest' in data &&
      typeof data.latest === 'string' &&
      VERSION.test(data.latest)
    ) {
      return { checked: data.checked, latest: data.latest };
    }
  } catch {
    // Missing, unreadable or not JSON: as if never checked, so the next refresh rewrites it.
  }
  return undefined;
}

function newer(latest: string, current: string): boolean {
  const a = VERSION.exec(latest)?.slice(1).map(Number) ?? [];
  const b = VERSION.exec(current)?.slice(1).map(Number) ?? [];
  for (let i = 0; i < 3; i++) {
    if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  }
  return false;
}

// What the cache says, read from disk only; undefined when the check is off or does not apply to this install.
export async function updateCheck(): Promise<Update | undefined> {
  const kind = install();
  const file = cacheFile();
  if (!kind || !file || off()) return undefined;
  const cache = await readCache(file);
  return {
    newer: cache && newer(cache.latest, pkg.version) ? cache.latest : undefined,
    install: kind,
    // A clock set back past the last check counts as due too. ponytail: a cache that cannot be written (a folder left
    // to root by sudo) stays due, so each command at a terminal asks again; add a fallback stamp if anyone hits it.
    due: !cache || !(Date.now() - cache.checked < INTERVAL_MS && Date.now() >= cache.checked),
  };
}

// Asks the registry for the latest tag and writes it to the cache. Best effort: every failure is dropped, and a
// failed request still records the time, so an offline Mac asks once a day, not on every command.
export async function refresh(): Promise<void> {
  const file = cacheFile();
  if (!file) return;
  const previous = await readCache(file);
  // npm sets npm_config_registry for what it runs; a shell started without npm has the public registry.
  const registry = (process.env.npm_config_registry || 'https://registry.npmjs.org/').replace(/\/*$/, '/');
  let latest = previous?.latest ?? pkg.version;
  try {
    const response = await fetch(`${registry}-/package/${pkg.name}/dist-tags`, {
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const tags: unknown = response.ok ? await response.json() : undefined;
    if (typeof tags === 'object' && tags !== null && 'latest' in tags && typeof tags.latest === 'string') {
      if (VERSION.test(tags.latest)) latest = tags.latest;
    }
  } catch {
    // Offline, a proxy, a timeout, a body that is not JSON: the notice is best effort (K78).
  }
  try {
    await mkdir(dirname(file), { recursive: true, mode: 0o700 });
    const temp = `${file}.${process.pid}`;
    await writeFile(temp, JSON.stringify({ checked: Date.now(), latest } satisfies Cache));
    // rename replaces the file in one step, so a reader in another process never sees half of it.
    await rename(temp, file);
  } catch {
    // A cache that cannot be written (another owner, a full disk) leaves the notice as it was; nothing else reads it.
  }
}
