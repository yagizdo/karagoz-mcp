import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { readLines, runTool } from '../../tool.js';

// The first call after login starts CoreSimulatorService: 8.9 s in one report, and 15 s was too short in two
// projects (K32).
export const TIMEOUT_MS = 30_000;

// Sized when the screenshot PNG (2.9 MB, measured) came on stdout; it now comes through a file. Kept: lowering it
// gains nothing. Node's 1 MB default failed adb's PNG (K22).
const MAX_BUFFER = 64 * 1024 * 1024;

// ponytail: Apple's private path, the binary Xcode's simctl shim execs. Calling it directly skips xcrun's install
// dialog and the shim's `xcodebuild -runFirstLaunch`, which hangs without a TTY (K32). If Apple moves it, iOS reads
// as SIMCTL_NOT_FOUND; the fix is to read the path from the shim's exec line.
const FRAMEWORK = '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl';
// The framework's Info.plist: its CFBundleVersion is the CoreSimulator version a shim's EXPECTED_VERSION names.
export const FRAMEWORK_PLIST = join(dirname(FRAMEWORK), '..', 'Info.plist');

// DEVELOPER_DIR picks an Xcode as it does for xcrun, which also takes the .app path, with or without a trailing slash.
export function developerDir(): string | undefined {
  const env = process.env.DEVELOPER_DIR;
  if (!env) return undefined;
  const dev = resolve(env);
  return dev.endsWith('.app') ? join(dev, 'Contents', 'Developer') : dev;
}

// The line of a simctl or devicectl shim that names the framework version its Xcode was built for (K32).
export const EXPECTED = /^EXPECTED_VERSION="([^"]+)"$/m;

// An Xcode's usr/bin tool, or the framework binary when the tool is Apple's shim. The shim runs `xcodebuild
// -runFirstLaunch` before it execs that binary when the versions differ: a timeout kills only the shim and leaves the
// xcodebuild behind, and its output lands ahead of the tool's own. The binary takes DEVELOPER_DIR as it is (K32, K48).
export async function unshimmed(path: string, framework: string): Promise<string> {
  return EXPECTED.test(await readFile(path, 'utf8').catch(() => '')) ? framework : path;
}

export async function binary(): Promise<{ bin: string; missing: string }> {
  const dev = developerDir();
  const bin = dev ? await unshimmed(join(dev, 'usr', 'bin', 'simctl'), FRAMEWORK) : FRAMEWORK;
  if (bin === FRAMEWORK)
    return { bin, missing: `simctl not found (tried ${FRAMEWORK}). Install Xcode and open it once.` };
  return {
    bin,
    missing: `simctl not found (tried ${bin}, from DEVELOPER_DIR). Point DEVELOPER_DIR at an Xcode, not the Command Line Tools, or unset it.`,
  };
}

// simctl's exit code is the NSError code cut to 8 bits, so the header line, not the exit code, names a failure (K36).
const HEADER = /^An error was encountered processing the command \(domain=([^,]+), code=(-?\d+)\):$/m;

export function header(text: string): { domain: string; code: number } | undefined {
  const [, domain, code] = HEADER.exec(text) ?? [];
  return domain && code ? { domain, code: Number(code) } : undefined;
}

function timedOut(timeout: number): KaragozError {
  return new KaragozError(
    'SIMCTL_TIMEOUT',
    `simctl did not answer within ${timeout / 1000}s. The simulator service may still be starting (the first call after login can take several seconds) or be stuck.`,
  );
}

// simctl() decodes the bytes, as adb() does (K32, K33). simctl's stderr on success ("Wrote screenshot to: <path>") is dropped: it is noise
// on every capture.
async function simctlBytes(
  args: string[],
  timeout = TIMEOUT_MS,
  refusal?: 'INSTALL_FAILED' | 'UNINSTALL_FAILED',
): Promise<Buffer> {
  const { bin, missing } = await binary();
  const result = await runTool(bin, args, { timeout, maxBuffer: MAX_BUFFER });
  if (result.ok) return result.stdout;
  const { failure } = result;
  if (failure.kind === 'missing') throw new KaragozError('SIMCTL_NOT_FOUND', missing);
  if (failure.kind === 'timeout') throw timedOut(timeout);
  const { stderr } = failure;
  const match = refusal ? HEADER.exec(stderr) : null;
  if (refusal && match) {
    // The description lines sit between the header and the first Underlying error block. Not cut: a device build's
    // refusal runs past 300 characters (K36).
    const lines = stderr.slice(match.index + match[0].length).split('\n');
    const end = lines.findIndex((line) => /^\s*Underlying error \(/.test(line));
    const message = (end < 0 ? lines : lines.slice(0, end))
      .map((line) => line.trim())
      .filter(Boolean)
      .join(' ');
    throw new KaragozError(refusal, message || match[0], `${match[1]}:${Number(match[2])}`);
  }
  throw new KaragozError('SIMCTL_FAILED', (stderr || failure.message).slice(0, 300));
}

export async function simctl(
  args: string[],
  timeout?: number,
  refusal?: 'INSTALL_FAILED' | 'UNINSTALL_FAILED',
): Promise<string> {
  return (await simctlBytes(args, timeout, refusal)).toString('utf8');
}

function spawnFailed(err: Error, missing: string): KaragozError {
  if ('code' in err && err.code === 'ENOENT') return new KaragozError('SIMCTL_NOT_FOUND', missing);
  return new KaragozError('SIMCTL_FAILED', err.message.slice(0, 300));
}

// For output past any buffer: log show prints ~1.45 KB per record, 497 MB for an hour (K37). onLine runs for each
// stdout line; its first throw kills simctl and becomes the result. No killSignal: simctl does not pass SIGKILL on and
// the process inside the simulator is orphaned (WebKit #185164).
export async function simctlLines(args: string[], onLine: (line: string) => void): Promise<void> {
  const { bin, missing } = await binary();
  const signal = cancellation.getStore();
  signal?.throwIfAborted();
  let child;
  try {
    child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'], timeout: TIMEOUT_MS, ...(signal && { signal }) });
  } catch (err) {
    // ENOTDIR (a file on DEVELOPER_DIR's path) throws here; ENOENT and EACCES come as 'error'.
    if (!(err instanceof Error)) throw err;
    throw spawnFailed(err, missing);
  }
  const { code, ended, killed, stderr } = await readLines(child, onLine, (err) => spawnFailed(err, missing));
  if (killed) throw timedOut(TIMEOUT_MS);
  if (code === 0) return;
  // Every log call prints this line and exits 0 (K37).
  const text = stderr
    .split('\n')
    .filter((line) => !line.startsWith('getpwuid_r did not find a match'))
    .join('\n')
    .trim()
    .slice(0, 300);
  throw new KaragozError(
    'SIMCTL_FAILED',
    text || (ended ? `simctl ended by ${ended}` : `simctl exited with code ${code}`),
  );
}
