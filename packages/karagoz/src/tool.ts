import { type ChildProcessByStdio, execFile } from 'node:child_process';
import { createInterface } from 'node:readline';
import type { Readable } from 'node:stream';
import { promisify } from 'node:util';
import { cancellation } from './cancellation.js';
import type { KaragozError } from './errors.js';

const run = promisify(execFile);

// Why a tool run failed: missing is a spawn ENOENT, timeout is the kill by the timeout, failed is everything else.
export type Failure = {
  kind: 'missing' | 'timeout' | 'failed';
  // The exit code, or the spawn or Node error's code (ENOENT, EACCES, ERR_CHILD_PROCESS_STDIO_MAXBUFFER).
  code: string | number | undefined;
  signal: string | undefined;
  stderr: string;
  stdout: string;
  message: string;
};

// Runs an external tool under the call's cancellation signal and sorts a failure into a Failure; each caller maps that
// to its own tool's error codes and messages.
export async function runTool(
  bin: string,
  args: string[],
  options: { timeout: number; maxBuffer?: number },
): Promise<{ ok: true; stdout: Buffer; stderr: Buffer } | { ok: false; failure: Failure }> {
  const { timeout, maxBuffer } = options;
  const signal = cancellation.getStore();
  // An aborted signal still spawns the tool and kills it a tick later.
  signal?.throwIfAborted();
  try {
    const { stdout, stderr } = await run(bin, args, {
      timeout,
      encoding: 'buffer',
      ...(maxBuffer !== undefined && { maxBuffer }),
      ...(signal && { signal }),
    });
    return { ok: true, stdout, stderr };
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    // The SDK sends no response for a cancelled call, so the abort passes through unmapped (K31).
    if (signal?.aborted) throw err;
    const code = 'code' in err && (typeof err.code === 'string' || typeof err.code === 'number') ? err.code : undefined;
    const kind = code === 'ENOENT' ? 'missing' : 'killed' in err && err.killed === true ? 'timeout' : 'failed';
    return {
      ok: false,
      failure: {
        kind,
        code,
        signal: 'signal' in err && typeof err.signal === 'string' ? err.signal : undefined,
        stderr: 'stderr' in err && Buffer.isBuffer(err.stderr) ? err.stderr.toString('utf8').trim() : '',
        stdout: 'stdout' in err && Buffer.isBuffer(err.stdout) ? err.stdout.toString('utf8') : '',
        message: err.message,
      },
    };
  }
}

// Hands each stdout line of a tool the caller just spawned to onLine; its first throw kills the tool and becomes the
// result. failed maps a spawn error; the caller maps the timeout and the exit, so each tool keeps its own texts.
export async function readLines(
  child: ChildProcessByStdio<null, Readable, Readable>,
  onLine: (line: string) => void,
  failed: (err: Error) => KaragozError,
): Promise<{ code: number | null; ended: NodeJS.Signals | null; killed: boolean; stderr: string }> {
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
  cancellation.getStore()?.throwIfAborted();
  if (failure) throw failed(failure);
  if (thrown) throw thrown.err;
  return { code, ended, killed: child.killed, stderr };
}
