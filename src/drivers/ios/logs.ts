import { KaragozError } from '../../errors.js';
import { installed } from './app.js';
import { isRecord } from './devices.js';
import { simctlLines } from './simctl.js';

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

function unexpected(line: string): KaragozError {
  return new KaragozError('SIMCTL_FAILED', `unexpected log output: ${line.slice(0, 300)}`);
}

// log prints a week-year (YYYY): December 29-31 can carry next year and January 1-3 last year (K37).
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
  if (date >= '12-29' && at(y) > now) y -= 1;
  else if (date <= '01-03' && at(y + 1) <= now) y += 1;
  return (at(y) * 1e6 + Number(micro)) / 1e6;
}

// One ndjson line: a logEvent record, or the summary line that proves the read finished (K37).
function parse(line: string): LogRecord | 'finished' {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    // The line itself goes into the message; JSON.parse's position adds nothing to it.
    throw unexpected(line);
  }
  if (!isRecord(value)) throw unexpected(line);
  if ('finished' in value) return 'finished';
  const { timestamp, processID, threadID, messageType, processImagePath, subsystem, category, eventMessage } = value;
  const match = typeof timestamp === 'string' ? TIMESTAMP.exec(timestamp) : null;
  const at = match ? time(match) : undefined;
  if (at === undefined || typeof processID !== 'number' || typeof threadID !== 'number') throw unexpected(line);
  if (typeof eventMessage !== 'string') throw unexpected(line);
  const path = typeof processImagePath === 'string' ? processImagePath : '';
  return {
    time: at,
    pid: processID,
    tid: threadID,
    level: LEVELS.get(messageType) ?? '?',
    tag: path.slice(path.lastIndexOf('/') + 1),
    subsystem: typeof subsystem === 'string' ? subsystem : '',
    category: typeof category === 'string' ? category : '',
    message: eventMessage,
  };
}

// log show has no record count: without --since, the window is the last minute, or the whole store for one app (K37).
export async function logs(udid: string, pkg: string | undefined, since: string | undefined, lines: number) {
  // --start takes whole seconds; karagoz keeps only records after the exact value (K37).
  const bound =
    since !== undefined ? ['--start', `@${since.split('.')[0]}`] : pkg === undefined ? ['--last', '1m'] : [];
  // The app's bundle and its extensions from this install, and launchd's exit line, the only trace of a signal
  // crash (K37).
  const predicate =
    pkg === undefined
      ? OTHERS
      : `type == logEvent AND (processImagePath BEGINSWITH ${quoted(`${await installed(udid, pkg)}/`)} OR (process == "launchd_sim" AND subsystem CONTAINS "UIKitApplication:${pkg}[" AND composedMessage BEGINSWITH "exited "))`;
  const after = since === undefined ? -Infinity : Number(since);
  const ring: LogRecord[] = [];
  // An object, not two lets: TypeScript would read the checks after the call as if the callback never ran.
  const read = { matched: 0, done: false };
  // ponytail: no byte cap. A far --since with --lines in the millions can keep ~1.3 M records within the 30 s (heap
  // ~0.5 GB), and a result past V8's string limit fails as INTERNAL; a byte cap on the ring lifts it.
  await simctlLines(
    ['spawn', udid, 'log', 'show', '--style', 'ndjson', '--info', '--debug', ...bound, '--predicate', predicate],
    (line) => {
      if (read.done) throw unexpected(line);
      const parsed = parse(line);
      if (parsed === 'finished') {
        read.done = true;
        return;
      }
      if (parsed.time <= after) return;
      read.matched += 1;
      ring.push(parsed);
      if (ring.length === 2 * lines) ring.splice(0, lines);
    },
  ).catch((err: unknown) => {
    if (!(err instanceof KaragozError) || err.code !== 'SIMCTL_TIMEOUT') throw err;
    throw new KaragozError(
      'SIMCTL_TIMEOUT',
      'log show did not finish within 30s. Pass a later --since, or --package, to read less of the simulator log.',
    );
  });
  if (!read.done) throw new KaragozError('SIMCTL_FAILED', 'log show ended without its summary line');
  const records = ring.slice(-lines);
  const omitted = read.matched - records.length;
  return pkg === undefined ? { device: udid, records, omitted } : { device: udid, package: pkg, records, omitted };
}
