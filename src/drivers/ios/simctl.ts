import { execFile, spawn } from 'node:child_process';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';

const run = promisify(execFile);

// The first call after login starts CoreSimulatorService: 8.9 s in one report, and 15 s was too short in two
// projects (K32).
export const TIMEOUT_MS = 30_000;

// Sized when the screenshot PNG (2.9 MB, measured) came on stdout; it now comes through a file. Kept: lowering it
// gains nothing. Node's 1 MB default failed adb's PNG (K22).
const MAX_BUFFER = 64 * 1024 * 1024;

// ponytail: Apple's private path, the binary Xcode's simctl shim execs. Calling it directly skips xcrun's install
// dialog and the shim's `xcodebuild -runFirstLaunch`, which hangs without a TTY (K32). If Apple moves it, iOS reads
// as SIMCTL_NOT_FOUND; the fallback is the selected Xcode's shim after checking its EXPECTED_VERSION.
const FRAMEWORK = '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl';

// DEVELOPER_DIR picks an Xcode as it does for xcrun, which also takes the .app path, with or without a trailing slash.
export function developerDir(): string | undefined {
  const env = process.env.DEVELOPER_DIR;
  if (!env) return undefined;
  const dev = resolve(env);
  return dev.endsWith('.app') ? join(dev, 'Contents', 'Developer') : dev;
}

function binary(): { bin: string; missing: string } {
  const dev = developerDir();
  if (!dev)
    return { bin: FRAMEWORK, missing: `simctl not found (tried ${FRAMEWORK}). Install Xcode and open it once.` };
  const bin = join(dev, 'usr', 'bin', 'simctl');
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

// The bytes form keeps err.stderr a Buffer, so SIMCTL_FAILED carries simctl's own text; simctl() decodes the same
// result, as adb() does (K32, K33). simctl's stderr on success ("Wrote screenshot to: <path>") is dropped: it is noise
// on every capture.
async function simctlBytes(
  args: string[],
  timeout = TIMEOUT_MS,
  refusal?: 'INSTALL_FAILED' | 'UNINSTALL_FAILED',
): Promise<Buffer> {
  const { bin, missing } = binary();
  const signal = cancellation.getStore();
  // An aborted signal still spawns simctl and kills it a tick later.
  signal?.throwIfAborted();
  try {
    return (
      await run(bin, args, {
        timeout,
        encoding: 'buffer',
        maxBuffer: MAX_BUFFER,
        ...(signal && { signal }),
      })
    ).stdout;
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    // The SDK sends no response for a cancelled call, so the abort passes through unmapped (K31).
    if (signal?.aborted) throw err;
    if ('code' in err && err.code === 'ENOENT') {
      throw new KaragozError('SIMCTL_NOT_FOUND', missing);
    }
    if ('killed' in err && err.killed) throw timedOut(timeout);
    const stderr = 'stderr' in err && Buffer.isBuffer(err.stderr) ? err.stderr.toString('utf8').trim() : '';
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
    throw new KaragozError('SIMCTL_FAILED', (stderr || err.message).slice(0, 300));
  }
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
  const { bin, missing } = binary();
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
  // Listeners go on before any await: readline drops lines that arrive while nothing listens (K37).
  let failure: Error | undefined;
  child.on('error', (err) => {
    failure = err;
  });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk: string) => {
    if (stderr.length < 4096) stderr += chunk;
  });
  const reader = createInterface({ input: child.stdout, crlfDelay: Infinity });
  let thrown: { err: unknown } | undefined;
  const read = (line: string) => {
    try {
      onLine(line);
    } catch (err) {
      // Already killed by the timeout or an abort: this is the cut last line, and that result wins.
      if (child.killed) return;
      thrown = { err };
      child.kill();
      reader.off('line', read);
    }
  };
  reader.on('line', read);
  const [code, ended] = await new Promise<[number | null, NodeJS.Signals | null]>((done) => {
    child.on('close', (exit, by) => done([exit, by]));
  });
  // The SDK sends no response for a cancelled call, so the abort passes through unmapped (K31).
  signal?.throwIfAborted();
  if (failure) throw spawnFailed(failure, missing);
  if (thrown) throw thrown.err;
  if (child.killed) throw timedOut(TIMEOUT_MS);
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
