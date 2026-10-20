import { type ChildProcess, spawn } from 'node:child_process';
import { closeSync, existsSync, openSync, readSync, rmSync } from 'node:fs';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { createInterface } from 'node:readline';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { bundleOf, installed } from './app.js';
import { isRecord } from './devices.js';
import { archive, relay } from './lockdown.js';
import { simctlLines, TIMEOUT_MS } from './simctl.js';

type LogRecord = {
  time: number;
  pid: number;
  tid: number;
  level: string;
  tag: string;
  subsystem: string;
  category: string;
  message: string;
};

// Default is what Logger.notice and NSLog write; Android's I is the nearest letter (K37).
const LEVELS = new Map<unknown, string>([
  ['Debug', 'D'],
  ['Info', 'I'],
  ['Default', 'I'],
  ['Error', 'E'],
  ['Fault', 'F'],
]);

// Local time to the microsecond; a zero offset prints Z (K37).
const TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{6})(?:([+-])(\d{2})(\d{2})|Z)$/;

// Every log show writes its own "log run noninteractively" record inside the window it reads (K37).
const OTHERS = 'type == logEvent AND NOT (process == "log" AND composedMessage BEGINSWITH "log run noninteractively")';

// An NSPredicate string literal. A raw line break is a Bad predicate (K37).
function quoted(text: string): string {
  const escaped = text.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r');
  return `"${escaped}"`;
}

// LC_UUID, the build UUID the linker derives from the code (Apple TN3178).
const LC_UUID = 0x1b;

// The build UUIDs of a Mach-O file, one per architecture; none when the file is missing or not a 64-bit Mach-O.
function buildIds(file: string): Set<string> {
  const ids = new Set<string>();
  let fd: number;
  try {
    fd = openSync(file, 'r');
  } catch {
    // A process image this install does not have is not this build.
    return ids;
  }
  try {
    const at = (offset: number, size: number) => {
      const buf = Buffer.alloc(size);
      return buf.subarray(0, readSync(fd, buf, 0, size, offset));
    };
    const head = at(0, 8);
    const magic = head.length === 8 ? head.readUInt32BE(0) : 0;
    const wide = magic === 0xcafebabf;
    const count = magic === 0xcafebabe || wide ? Math.min(head.readUInt32BE(4), 16) : 0;
    const table = at(8, count * (wide ? 32 : 20));
    const slices = count
      ? Array.from({ length: Math.floor(table.length / (wide ? 32 : 20)) }, (_, i) =>
          wide ? Number(table.readBigUInt64BE(i * 32 + 8)) : table.readUInt32BE(i * 20 + 8),
        )
      : [0];
    for (const base of slices) {
      const mach = at(base, 32);
      if (mach.length < 32 || mach.readUInt32LE(0) !== 0xfeedfacf) continue;
      const cmds = at(base + 32, Math.min(mach.readUInt32LE(20), 1 << 20));
      for (let off = 0; off + 8 <= cmds.length;) {
        const size = cmds.readUInt32LE(off + 4);
        if (cmds.readUInt32LE(off) === LC_UUID && off + 24 <= cmds.length) {
          const hex = cmds.toString('hex', off + 8, off + 24).toUpperCase();
          ids.add(`${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`);
        }
        if (size < 8) break;
        off += size;
      }
    }
  } finally {
    closeSync(fd);
  }
  return ids;
}

// log prints the path of a build's first install: uuidtext keeps one path per build UUID, so a reinstalled build logs
// under an older folder (K37). The folder name picks candidates; the file's own LC_UUID in this install decides.
// ponytail: two apps whose executables are byte-identical (two template Flutter apps with the same plugins) share a
// UUID and mix; telling them apart needs the bundle id, which no record carries.
function sameBuild(app: string): (image: string, build: string) => boolean {
  const folder = `/${basename(app)}/`;
  const seen = new Map<string, Set<string>>();
  return (image, build) => {
    const at = image.indexOf(folder);
    // Outside the folder: launchd's exit line, let through by its own clause of the predicate.
    if (at === -1) return true;
    const file = join(app, image.slice(at + folder.length));
    let ids = seen.get(file);
    if (!ids) {
      ids = buildIds(file);
      seen.set(file, ids);
    }
    return ids.has(build.toUpperCase());
  };
}

// The code names the tool that printed the line: simctl on a simulator, karagoz's own read on an iPhone.
type Failure = 'SIMCTL_FAILED' | 'HELPER_FAILED';

function unexpected(line: string, code: Failure): KaragozError {
  return new KaragozError(code, `unexpected log output: ${line.slice(0, 300)}`);
}

// log prints a week-year (YYYY): December 26-31 can carry next year (week 1 may start on Dec 26) and, under ISO rules,
// January 1-3 last year (K37).
// ponytail: a genuine January 1-3 record from more than a year ago moves forward too; the stores measured held days.
function time(match: RegExpExecArray): number | undefined {
  const [, year, month, day, hour, minute, second, micro, sign, offHour, offMinute] = match;
  if (!year || !month || !day || !hour || !minute || !second || !micro) return undefined;
  const offset = sign ? (sign === '-' ? -1 : 1) * (Number(offHour) * 3600 + Number(offMinute) * 60) : 0;
  const at = (y: number) =>
    Date.UTC(y, Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second)) / 1000 - offset;
  const now = Date.now() / 1000;
  let y = Number(year);
  const date = `${month}-${day}`;
  if (date >= '12-26' && at(y) > now) y -= 1;
  else if (date <= '01-03' && at(y + 1) <= now) y += 1;
  return (at(y) * 1e6 + Number(micro)) / 1e6;
}

type Parsed = { record: LogRecord; image: string; build: string };

// One ndjson line: a logEvent record with its process image's path and build UUID, or the summary line that proves
// the read finished (K37).
function parse(line: string, code: Failure): Parsed | 'finished' {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    // The line itself goes into the message; JSON.parse's position adds nothing to it.
    throw unexpected(line, code);
  }
  if (!isRecord(value)) throw unexpected(line, code);
  if ('finished' in value) return 'finished';
  const { timestamp, processID, threadID, messageType, processImagePath, processImageUUID, subsystem, category } =
    value;
  const { eventMessage } = value;
  const match = typeof timestamp === 'string' ? TIMESTAMP.exec(timestamp) : null;
  const at = match ? time(match) : undefined;
  if (at === undefined || typeof processID !== 'number' || typeof threadID !== 'number') throw unexpected(line, code);
  if (typeof eventMessage !== 'string') throw unexpected(line, code);
  const path = typeof processImagePath === 'string' ? processImagePath : '';
  const record = {
    time: at,
    pid: processID,
    tid: threadID,
    level: LEVELS.get(messageType) ?? '?',
    tag: path.slice(path.lastIndexOf('/') + 1),
    subsystem: typeof subsystem === 'string' ? subsystem : '',
    category: typeof category === 'string' ? category : '',
    message: eventMessage,
  };
  return { record, image: path, build: typeof processImageUUID === 'string' ? processImageUUID : '' };
}

// Every line before the summary is a record; a line after it, or no summary at all, means the read was cut (K37).
async function collect(
  source: (onLine: (line: string) => void) => Promise<void>,
  code: Failure,
  onRecord: (parsed: Parsed) => void,
): Promise<void> {
  // An object, not a let: TypeScript would read the check after the call as if the callback never ran.
  const read = { done: false };
  await source((line) => {
    if (read.done) throw unexpected(line, code);
    const parsed = parse(line, code);
    if (parsed === 'finished') read.done = true;
    else onRecord(parsed);
  });
  if (!read.done) throw new KaragozError(code, 'log show ended without its summary line');
}

// log show has no record count: without --since, the window is the last minute, or the whole store for one app (K37).
export async function logs(udid: string, pkg: string | undefined, since: string | undefined, lines: number) {
  // --start takes whole seconds; karagoz keeps only records after the exact value (K37).
  const bound =
    since !== undefined ? ['--start', `@${since.split('.')[0]}`] : pkg === undefined ? ['--last', '1m'] : [];
  const app = pkg === undefined ? undefined : await installed(udid, pkg);
  // Processes started from a bundle with the app's folder name, and launchd's exit line, the only trace of a signal
  // crash (K37).
  const predicate =
    app === undefined
      ? OTHERS
      : `type == logEvent AND (processImagePath CONTAINS ${quoted(`/${basename(app)}/`)} OR (process == "launchd_sim" AND subsystem CONTAINS "UIKitApplication:${pkg}[" AND composedMessage BEGINSWITH "exited "))`;
  const ours = app === undefined ? undefined : sameBuild(app);
  const after = since === undefined ? -Infinity : Number(since);
  const ring: Ring = { records: [], matched: 0 };
  // ponytail: no byte cap. A far --since with --lines in the millions can keep ~1.3 M records within the 30 s (heap
  // ~0.5 GB), and a result past V8's string limit fails as INTERNAL; a byte cap on the ring lifts it.
  await collect(
    (onLine) =>
      simctlLines(
        ['spawn', udid, 'log', 'show', '--style', 'ndjson', '--info', '--debug', ...bound, '--predicate', predicate],
        onLine,
      ),
    'SIMCTL_FAILED',
    ({ record, image, build }) => {
      if (record.time <= after || (ours && !ours(image, build))) return;
      keep(ring, record, lines);
    },
  ).catch((err: unknown) => {
    if (!(err instanceof KaragozError) || err.code !== 'SIMCTL_TIMEOUT') throw err;
    throw new KaragozError(
      'SIMCTL_TIMEOUT',
      'log show did not finish within 30s. Pass a later --since, or --package, to read less of the simulator log.',
    );
  });
  const records = ring.records.slice(-lines);
  const omitted = ring.matched - records.length;
  return pkg === undefined ? { device: udid, records, omitted } : { device: udid, package: pkg, records, omitted };
}

// simctlLines' twin for macOS's own log (K44): listeners before any await, the first throw kills it and wins, K37's
// 30 s.
// ponytail: log and tar are found on PATH, so smoke 4.6 can put a fake log first; a user's own earlier `log` would be
// called instead of macOS's.
async function logLines(args: string[], onLine: (line: string) => void): Promise<void> {
  const signal = cancellation.getStore();
  signal?.throwIfAborted();
  const child = spawn('log', args, {
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: TIMEOUT_MS,
    ...(signal && { signal }),
  });
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
  if (failure) {
    const missing = 'code' in failure && failure.code === 'ENOENT';
    throw new KaragozError(
      'HELPER_FAILED',
      missing ? 'log not found on PATH' : `log did not start (${failure.message})`,
    );
  }
  if (thrown) throw thrown.err;
  if (child.killed) {
    throw new KaragozError(
      'HELPER_FAILED',
      `log show did not finish within ${TIMEOUT_MS / 1000} s. Pass a later --since, or --package, to read less of the iPhone log.`,
    );
  }
  if (code === 0) return;
  throw new KaragozError(
    'HELPER_FAILED',
    stderr.trim().slice(0, 300) || (ended ? `log ended by ${ended}` : `log exited with code ${code}`),
  );
}

// tar's own result decides, unless the stream failed first with a reason of its own; a tar that ends cleanly at a file
// boundary leaves no Info.plist, which the phone sends last (K44 M5).
async function unpacked(tar: ChildProcess, streaming: Promise<void>, dir: string): Promise<void> {
  let failure: Error | undefined;
  let stderr = '';
  tar.stderr?.setEncoding('utf8');
  tar.stderr?.on('data', (chunk: string) => {
    if (stderr.length < 4096) stderr += chunk;
  });
  const exited = new Promise<number | null>((done) => {
    tar.on('error', (err) => {
      failure = err;
      done(null);
    });
    tar.on('close', (code) => done(code));
  });
  const streamed = await streaming.then(
    () => undefined,
    (err: unknown) => err,
  );
  const code = await exited;
  cancellation.getStore()?.throwIfAborted();
  if (failure) {
    const missing = 'code' in failure && failure.code === 'ENOENT';
    throw new KaragozError(
      'HELPER_FAILED',
      missing ? 'tar not found on PATH' : `tar did not start (${failure.message})`,
    );
  }
  if (streamed instanceof KaragozError) throw streamed;
  if (code !== 0) {
    const text = stderr.trim().slice(0, 300) || `exit ${String(code)}`;
    throw new KaragozError('HELPER_FAILED', `tar could not unpack the iPhone's log archive: ${text}`);
  }
  if (streamed !== undefined) {
    const why = streamed instanceof Error ? ('code' in streamed ? String(streamed.code) : streamed.message) : 'unknown';
    throw new KaragozError('HELPER_FAILED', `the iPhone's log stream broke (${why})`);
  }
  if (!existsSync(join(dir, 'Info.plist')))
    throw new KaragozError('HELPER_FAILED', "the iPhone's log archive ended early");
}

// The newest records of a simulator read or of one install folder on an iPhone; the older ones are only counted (K37).
type Ring = { records: LogRecord[]; matched: number };

function keep(ring: Ring, record: LogRecord, lines: number): void {
  ring.matched += 1;
  ring.records.push(record);
  if (ring.records.length === 2 * lines) ring.records.splice(0, lines);
}

// The pid launchd names at the end of an app's job label: "user/501/UIKitApplication:<id>[ab12][rb-legacy] [6711]".
const LAUNCHD_PID = / \[(\d+)\]$/;

// An iPhone's log, read over USB with this Mac's pairing (K44): the phone archives its records from a start time, tar
// unpacks them into a temporary .logarchive, and macOS's log show prints them in the simulator's ndjson. Without
// --since: the last minute, or the last hour with --package (user decision, K44).
export async function logsPhone(udid: string, pkg: string | undefined, since: string | undefined, lines: number) {
  // file:///private/var/containers/Bundle/Application/<G>/<Name>.app/ (K43)
  const current = pkg === undefined ? undefined : decodeURIComponent(new URL(await bundleOf(udid, pkg)).pathname);
  const signal = cancellation.getStore();
  const root = await mkdtemp(join(tmpdir(), 'karagoz-logs-')).catch((err: unknown) => {
    throw new KaragozError('WRITE_FAILED', err instanceof Error ? err.message : String(err));
  });
  let tar: ChildProcess | undefined;
  // cli.ts and mcp.ts exit right after the abort, before any await could run, so this cleans up on its own; tar goes
  // first, or it keeps writing into the folder being removed.
  const wipe = () => {
    tar?.kill('SIGKILL');
    try {
      rmSync(root, { recursive: true, force: true, maxRetries: 3 });
    } catch {
      // The process is exiting; there is nobody left to tell.
    }
  };
  signal?.addEventListener('abort', wipe, { once: true });
  try {
    // log show reads only a directory named *.logarchive (K44 M6).
    const dir = join(root, 'phone.logarchive');
    await mkdir(dir);
    const { clock, socket } = await relay(udid);
    const window = pkg === undefined ? 60 : 3600;
    const start = since === undefined ? Math.floor(clock) - window : Number(since.split('.')[0]);
    const child = spawn('tar', ['-x', '-f', '-', '-C', dir], { stdio: ['pipe', 'ignore', 'pipe'] });
    tar = child;
    await unpacked(child, archive(socket, start, child.stdin), dir);
    const show = ['show', '--archive', dir, '--style', 'ndjson', '--info', '--debug'];
    if (current === undefined) {
      const bound = since === undefined ? ['--last', '1m'] : ['--start', `@${String(start)}`];
      const after = since === undefined ? -Infinity : Number(since);
      const ring: Ring = { records: [], matched: 0 };
      await collect(
        (onLine) => logLines([...show, ...bound, '--predicate', 'type == logEvent'], onLine),
        'HELPER_FAILED',
        ({ record }) => {
          if (record.time > after) keep(ring, record, lines);
        },
      );
      const records = ring.records.slice(-lines);
      return { device: udid, records, omitted: ring.matched - records.length };
    }
    // No window for log show: the proof below may rest on a record from before --since (K44).
    const folder = `/${basename(current)}/`;
    const after = since === undefined ? clock - window : Number(since);
    const folders = new Map<string, { ring: Ring; pids: Set<number> }>();
    const exits: Ring = { records: [], matched: 0 };
    const tied = new Set<number>();
    const predicate = `type == logEvent AND (processImagePath CONTAINS ${quoted(folder)} OR (process == "launchd" AND subsystem CONTAINS "UIKitApplication:${pkg ?? ''}["))`;
    await collect(
      (onLine) => logLines([...show, '--predicate', predicate], onLine),
      'HELPER_FAILED',
      ({ record, image }) => {
        const at = image.indexOf(folder);
        if (at === -1) {
          // launchd's lines for this bundle id: their pids tie folders to it; only the exit line is output (K37).
          const pid = LAUNCHD_PID.exec(record.subsystem)?.[1];
          if (pid !== undefined) tied.add(Number(pid));
          if (record.message.startsWith('exited ') && record.time > after) keep(exits, record, lines);
          return;
        }
        const path = image.slice(0, at + folder.length);
        let entry = folders.get(path);
        if (!entry) {
          entry = { ring: { records: [], matched: 0 }, pids: new Set() };
          folders.set(path, entry);
        }
        entry.pids.add(record.pid);
        if (record.time > after) keep(entry.ring, record, lines);
      },
    );
    // A folder is this app's when it is the current install or launchd ran one of its processes under the bundle id;
    // with no proof at all, every folder with the app's folder name (user decision, K44).
    const proven = [...folders].filter(
      ([path, { pids }]) => path === current || [...pids].some((pid) => tied.has(pid)),
    );
    const chosen = (proven.length ? proven : [...folders]).map(([, { ring }]) => ring);
    chosen.push(exits);
    const records = chosen
      .flatMap((ring) => ring.records)
      .sort((a, b) => a.time - b.time)
      .slice(-lines);
    const matched = chosen.reduce((sum, ring) => sum + ring.matched, 0);
    return { device: udid, package: pkg, records, omitted: matched - records.length };
  } finally {
    signal?.removeEventListener('abort', wipe);
    await rm(root, { recursive: true, force: true, maxRetries: 3 });
  }
}
