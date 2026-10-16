import { lstatSync } from 'node:fs';
import { cachedAdb, candidates, INSTALL_HINT, onPath, skipped, type Source, TIMEOUT_MS, version } from './adb.js';

// doctor never sets adb.ts's resolved and never talks to the adb server: it only runs `adb version` (K30).

type Found =
  | { source: Source; status: 'ok' | 'outdated'; path?: string; version: string; message?: string }
  | { source: Source; status: 'failed'; path?: string; message: string };
type Candidate = { source: Source; status: 'unset' } | { source: Source; status: 'missing'; path?: string } | Found;
// used: the lookup in adbBytes() stops at this candidate.
type Probe = { candidate: Candidate; used: false } | { candidate: Found; used: true };

type Report = {
  adb: {
    status: Found['status'] | 'missing';
    source?: Source;
    path?: string;
    version?: string;
    message?: string;
    install?: string;
    candidates: Candidate[];
  };
};

// Debian's 8.1.0 package prints its package version, epoch first: `Version 1:8.1.0+r23-8` (K30).
const VERSION = /^Version ((?:\d+:)?(\d+)\.\d+\.\d+(?:[-+].*)?)$/m;
// install passes --no-incremental, first in platform-tools 30.0.0 (K19 note).
const FLOOR = 30;

async function probe(source: Source, bin: string | undefined): Promise<Probe> {
  if (bin === undefined) return { candidate: { source, status: 'unset' }, used: false };
  const target = bin === 'adb' ? onPath() : bin;
  if (target === undefined) return { candidate: { source, status: 'missing' }, used: false };
  // A POSIX PATH candidate runs by bare name: only adb's "Installed as" line says which file ran.
  let path = target === 'adb' ? undefined : target;
  const at = () => (path === undefined ? {} : { path });
  const failed = (message: string, used = true): Probe => ({
    candidate: { source, status: 'failed', ...at(), message: message.slice(0, 300) },
    used,
  });
  try {
    const out = await version(target);
    path ??= /^Installed as (.*)$/m.exec(out)?.[1];
    const [, found, major] = VERSION.exec(out) ?? [];
    if (found === undefined) return failed(`no Version line in 'adb version' output: ${out.split(/\r?\n/)[0]}`);
    if (Number(major) >= FLOOR) return { candidate: { source, status: 'ok', ...at(), version: found }, used: true };
    const message = `karagoz install needs platform-tools ${FLOOR}.0.0 or newer`;
    return { candidate: { source, status: 'outdated', ...at(), version: found, message }, used: true };
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    if (!skipped(err)) return failed(reason(err));
    // The lookup passes over it either way (K19); something at the path means it is there but cannot start.
    if (path !== undefined && exists(path)) {
      return failed('exists but could not be started (ENOENT): a missing interpreter or a broken link', false);
    }
    return { candidate: { source, status: 'missing', ...at() }, used: false };
  }
}

// lstat, not existsSync or stat: those follow a dangling link and report nothing there.
function exists(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

function reason(err: Error): string {
  // `adb version` never touches the server, so this is the binary hanging, not the port (K30).
  if ('killed' in err && err.killed === true) return `did not answer within ${TIMEOUT_MS / 1000}s`;
  if ('code' in err && typeof err.code === 'number') {
    const stderr = 'stderr' in err && typeof err.stderr === 'string' ? err.stderr.trim() : '';
    return stderr || `exited with ${err.code}`;
  }
  if ('signal' in err && typeof err.signal === 'string') return `killed by ${err.signal}`;
  return err.message;
}

export async function doctor(): Promise<Report> {
  const sources = candidates();
  const probes = await Promise.all(sources.map(({ source, bin }) => probe(source, bin)));
  const list = probes.map(({ candidate }) => candidate);
  // The cached adb stays in use while it starts, even after an earlier candidate appears; the CLI never has one.
  const cached = cachedAdb();
  const kept =
    probes[sources.findIndex(({ bin }) => cached !== undefined && (bin === 'adb' ? onPath() : bin) === cached)];
  const used = (kept?.used ? kept : probes.find((probe) => probe.used))?.candidate;
  if (!used) return { adb: { status: 'missing', install: INSTALL_HINT, candidates: list } };
  const { source, status, ...fields } = used;
  return {
    adb: { status, source, ...fields, ...(status === 'ok' ? {} : { install: INSTALL_HINT }), candidates: list },
  };
}
