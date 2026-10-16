import { KaragozError } from '../../errors.js';
import { adb, adbBytes } from './adb.js';

// LOGGER_ENTRY_MAX_LEN: no entry, header included, is longer (K29).
const MAX_ENTRY = 5120;

// Node's message for output past adbBytes' maxBuffer. When adb also wrote to stderr, adbBytes reports that text instead
// and the plain ADB_FAILED passes through (K29 2.6 note).
const OVERFLOW = 'stdout maxBuffer length exceeded';

type LogRecord = { time: number; pid: number; tid: number; level: string; tag: string; message: string };
type Entry = { uid: number | undefined; record: LogRecord };

// The end of the NUL-terminated field that starts at `from`; a truncated entry has no NUL (K29).
function fieldEnd(payload: Buffer, from: number): number {
  const nul = payload.indexOf(0, from);
  return nul === -1 ? payload.length : nul;
}

// `logcat -B` writes logger_entry records: len u16 (payload bytes), hdr_size u16, pid i32, tid u32, sec u32, nsec u32,
// lid u32, uid u32 (from hdr_size 28), then the payload: priority, tag, NUL, message, NUL (K29). exec-out exits 0 and
// puts logcat's own errors on stdout, so output that is not whole records is that error (K22, K29).
async function read(id: string, since: string | undefined): Promise<Entry[]> {
  const start = since === undefined ? [] : ['-t', since];
  // ponytail: the whole window is read because logcat counts -t N before any uid filter. A ring grown past adbBytes'
  // 64 MB maxBuffer gets an error that sends the caller to --since; a streaming reader lifts it (K29, open question 13).
  const out = await adbBytes(['-s', id, 'exec-out', 'logcat', '-d', '-B', ...start]).catch((err: unknown) => {
    if (!(err instanceof KaragozError) || err.message !== OVERFLOW) throw err;
    throw new KaragozError(
      'ADB_FAILED',
      'the device log is larger than the 64 MB karagoz reads at once. Pass --since to read only records after a recent time on the device clock (`adb shell date +%s` prints it).',
    );
  });
  const entries: Entry[] = [];
  let off = 0;
  while (off + 4 <= out.length) {
    const len = out.readUInt16LE(off);
    const hdr = out.readUInt16LE(off + 2);
    if (hdr < 24 || len < 2 || hdr + len > MAX_ENTRY || off + hdr + len > out.length) break;
    const payload = out.subarray(off + hdr, off + hdr + len);
    const tagEnd = fieldEnd(payload, 1);
    const sec = out.readUInt32LE(off + 12);
    const nsec = out.readUInt32LE(off + 16);
    entries.push({
      uid: hdr >= 28 ? out.readUInt32LE(off + 24) : undefined,
      record: {
        // Rounded up, so the largest time passed back as --since excludes its own record (K29).
        time: (sec * 1_000_000 + Math.ceil(nsec / 1000)) / 1e6,
        pid: out.readInt32LE(off + 4),
        tid: out.readUInt32LE(off + 8),
        level: '??VDIWEF'[payload.readUInt8(0)] ?? '?',
        tag: payload.toString('utf8', 1, tagEnd),
        message: payload.toString('utf8', tagEnd + 1, fieldEnd(payload, tagEnd + 1)),
      },
    });
    off += hdr + len;
  }
  if (off !== out.length) {
    const text = out.toString('utf8', off).trim().slice(0, 300);
    throw new KaragozError('ADB_FAILED', text || 'logcat printed no records and no error');
  }
  return entries;
}

// pm list packages matches substrings: `package:<name> uid:<n>` for every package whose name contains <name>, and
// nothing when none does (K29).
async function uidOf(id: string, pkg: string): Promise<number> {
  // From Android 13, pm without --user walks every user and throws at one the shell may not access (K29 2.6 note).
  const out = (await adb(['-s', id, 'exec-out', 'pm', 'list', 'packages', '-U', '--user', '0', pkg])).trim();
  const lines = out
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
  // An Error: line or a missing service while the device boots is not a missing package.
  if (lines.some((line) => !line.startsWith('package:'))) throw new KaragozError('ADB_FAILED', out);
  const line = lines.find((each) => each.split(' ')[0] === `package:${pkg}`);
  if (!line) throw new KaragozError('APP_NOT_FOUND', `package '${pkg}' is not installed on ${id}`);
  const uid = /\buid:(\d+)/.exec(line)?.[1];
  if (!uid) throw new KaragozError('ADB_FAILED', out);
  return Number(uid);
}

function newest(entries: Entry[], lines: number) {
  const records = entries.map(({ record }) => record);
  return { records: records.slice(-lines), omitted: Math.max(0, records.length - lines) };
}

export async function logs(id: string, pkg: string | undefined, since: string | undefined, lines: number) {
  if (pkg === undefined) return { device: id, ...newest(await read(id, since), lines) };
  const uid = await uidOf(id, pkg);
  // A header under 28 bytes has no uid, so its record never matches (K29).
  const own = (await read(id, since)).filter((entry) => entry.uid === uid);
  return { device: id, package: pkg, uid, ...newest(own, lines) };
}
