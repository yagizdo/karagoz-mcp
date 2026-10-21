import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { cancellation } from './cancellation.js';

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
