import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, isAbsolute, join } from 'node:path';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';

const run = promisify(execFile);

// adb blocks forever when something holds the server port and never answers.
// A cold server start takes ~3.2 s: the server waits up to 3 s for its device scan.
// The default for every call: the dump passes a longer one, and input.ts adds a gesture's duration (K19 note).
export const TIMEOUT_MS = 10_000;

// Above the 33 MB of uncompressed RGBA for a 3840x2160 display. Node's 1 MB default failed a 1.37 MB
// screenshot PNG with ERR_CHILD_PROCESS_STDIO_MAXBUFFER (measured).
const MAX_BUFFER = 64 * 1024 * 1024;

const exe = process.platform === 'win32' ? 'adb.exe' : 'adb';

const INSTALL: Record<string, string> = {
  darwin: 'brew install --cask android-platform-tools',
  win32: 'winget install Google.PlatformTools',
};

// Printed, never run: the package manager may not be there, so the official download is always offered too.
const download = 'download https://developer.android.com/tools/releases/platform-tools and add it to PATH';
const manager = INSTALL[process.platform];
export const INSTALL_HINT = `Install platform-tools (${manager ? `${manager}, or ${download}` : download}) or set ANDROID_HOME to your Android SDK.`;

export type Source = 'ANDROID_HOME' | 'ANDROID_SDK_ROOT' | 'PATH' | 'default';

// Explicit SDK config first, then PATH, then Android Studio's default SDK location. bin is undefined when a source
// has no location (an unset or empty variable, no LOCALAPPDATA on Windows).
export function candidates(): { source: Source; bin: string | undefined }[] {
  const at = (sdk: string | undefined) => (sdk ? join(sdk, 'platform-tools', exe) : undefined);
  const local = process.env.LOCALAPPDATA;
  const defaultSdk: Record<string, string | undefined> = {
    darwin: join(homedir(), 'Library', 'Android', 'sdk'),
    linux: join(homedir(), 'Android', 'Sdk'),
    win32: local && join(local, 'Android', 'Sdk'),
  };
  return [
    { source: 'ANDROID_HOME', bin: at(process.env.ANDROID_HOME) },
    { source: 'ANDROID_SDK_ROOT', bin: at(process.env.ANDROID_SDK_ROOT) },
    { source: 'PATH', bin: 'adb' },
    { source: 'default', bin: at(defaultSdk[process.platform]) },
  ];
}

// The lookup's skip rule: a candidate that spawns with ENOENT is not there (K19).
export function skipped(err: Error): boolean {
  return 'code' in err && err.code === 'ENOENT';
}

// The 'adb' candidate. On Windows libuv looks a bare name up in the current directory before PATH,
// so an adb.exe in the directory karagoz runs from would win. PATH is walked here instead, absolute
// entries only: libuv resolves relative ones against the current directory too.
export function onPath(): string | undefined {
  if (process.platform !== 'win32') return 'adb';
  return (process.env.PATH ?? '')
    .split(delimiter)
    .map((dir) => dir.replaceAll('"', ''))
    .filter((dir) => isAbsolute(dir))
    .map((dir) => join(dir, exe))
    .find((bin) => existsSync(bin));
}

let resolved: string | undefined;

// For doctor: under `karagoz mcp` resolved lives for the session and adbBytes tries it first (K19 M notes).
export const cachedAdb = (): string | undefined => resolved;

// Runs adb and returns its stdout. adb's own stderr (e.g. "* daemon started successfully") is passed through.
// The bytes form exists because a screenshot PNG must not pass through a text decode; adb() below decodes the
// same result, so both share this one candidate loop, timeout and error mapping.
export async function adbBytes(args: string[], timeout = TIMEOUT_MS): Promise<Buffer> {
  // A cached adb that spawns with ENOENT (deleted, SDK moved) falls through to a full lookup in the same call (K19).
  const found = candidates().flatMap(({ bin }) => (bin ? [bin] : []));
  const tried = resolved ? [resolved, ...found.filter((bin) => bin !== resolved)] : found;
  const signal = cancellation.getStore();
  for (const candidate of tried) {
    const bin = candidate === 'adb' ? onPath() : candidate;
    if (!bin) continue;
    // An aborted signal still spawns adb and kills it a tick later.
    signal?.throwIfAborted();
    try {
      const { stdout, stderr } = await run(bin, args, {
        timeout,
        encoding: 'buffer',
        maxBuffer: MAX_BUFFER,
        ...(signal && { signal }),
      });
      resolved = bin;
      process.stderr.write(stderr);
      return stdout;
    } catch (err) {
      if (!(err instanceof Error)) throw err;
      // The SDK sends no response for a cancelled call, so the abort passes through unmapped and resolved stays (K31).
      if (signal?.aborted) throw err;
      if (skipped(err)) continue;
      resolved = bin;
      if ('killed' in err && err.killed) {
        throw new KaragozError(
          'ADB_TIMEOUT',
          `adb did not answer within ${timeout / 1000}s. Another process may hold the adb server port, or the server is stuck; try \`adb kill-server\`.`,
        );
      }
      const stderr = 'stderr' in err && Buffer.isBuffer(err.stderr) ? err.stderr.toString('utf8').trim() : '';
      throw new KaragozError('ADB_FAILED', stderr || err.message);
    }
  }
  resolved = undefined;
  const where = tried.map((bin) => (bin === 'adb' ? 'PATH' : bin)).join(', ');
  throw new KaragozError('ADB_NOT_FOUND', `adb not found (tried ${where}). ${INSTALL_HINT}`);
}

export async function adb(args: string[], timeout = TIMEOUT_MS): Promise<string> {
  return (await adbBytes(args, timeout)).toString('utf8');
}

// For doctor: `adb version` never connects to the server (K30). async turns execFile's synchronous spawn throws
// (ENOEXEC, ENOTDIR) into rejections.
export async function version(bin: string): Promise<string> {
  const signal = cancellation.getStore();
  return (await run(bin, ['version'], { timeout: TIMEOUT_MS, encoding: 'utf8', ...(signal && { signal }) })).stdout;
}
