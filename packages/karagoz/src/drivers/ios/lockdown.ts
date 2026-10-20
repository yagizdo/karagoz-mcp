import type { Socket } from 'node:net';
import { Transform, type Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { connect as tlsConnect, type TLSSocket } from 'node:tls';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { TRUST } from './devicectl.js';
import { isRecord } from './devices.js';
import { connect, pairRecord, parse, plist, type Plist } from './usbmux.js';

// lockdownd's port on every iPhone, reached through usbmuxd like the runner's (K41, K44).
const LOCKDOWN = 62078;
// The phone's log relay: CreateArchive streams the stored records back, unlike the live-only requests (K44).
const SERVICE = 'com.apple.os_trace_relay';
// usbmux.ts's budget; every lockdown answer came within milliseconds (K44 M2, M4).
const TIMEOUT_MS = 10_000;
// The archive's first byte came after ~50 ms and the stream never paused (K44 M5); this long is a phone that stopped.
const IDLE_MS = 30_000;
// A lockdown answer is a small plist; a larger length is not one.
const MAX_ANSWER = 1 << 20;

// Exactly n bytes; what follows stays in the socket, paused, for the next read or the pipe.
function take(socket: Socket, n: number, timeoutMs: number, silence: string): Promise<Buffer> {
  const signal = cancellation.getStore();
  return new Promise((resolve, reject) => {
    let buffer = Buffer.alloc(0);
    const stop = () => {
      clearTimeout(timer);
      socket.off('data', data);
      socket.off('error', failed);
      socket.off('close', closed);
      socket.pause();
    };
    // The SDK sends no response for a cancelled call, so the abort passes through (K31).
    const fail = (err: KaragozError) => {
      stop();
      reject(signal?.aborted ? signal.reason : err);
    };
    const data = (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length < n) return;
      stop();
      if (buffer.length > n) socket.unshift(buffer.subarray(n));
      resolve(buffer.subarray(0, n));
    };
    const failed = (err: Error) =>
      fail(
        new KaragozError(
          'HELPER_FAILED',
          `the connection to the iPhone failed (${'code' in err ? String(err.code) : err.message})`,
        ),
      );
    const closed = () => fail(new KaragozError('HELPER_FAILED', 'the iPhone closed the connection'));
    const timer = setTimeout(() => {
      socket.destroy();
      fail(new KaragozError('HELPER_FAILED', silence));
    }, timeoutMs);
    socket.on('data', data);
    socket.on('error', failed);
    socket.on('close', closed);
    socket.resume();
  });
}

// Lockdown's framing: a 4-byte big-endian length, then an XML plist.
function send(socket: Socket, fields: Record<string, string | number>): void {
  const body = Buffer.from(plist(fields));
  const head = Buffer.alloc(4);
  head.writeUInt32BE(body.length, 0);
  socket.write(Buffer.concat([head, body]));
}

async function ask(socket: Socket, fields: Record<string, string | number>): Promise<Record<string, unknown>> {
  send(socket, { Label: 'karagoz', ...fields });
  const request = String(fields.Request);
  const silence = `the iPhone did not answer ${request} within ${TIMEOUT_MS / 1000} s`;
  const length = (await take(socket, 4, TIMEOUT_MS, silence)).readUInt32BE(0);
  const odd = new KaragozError('HELPER_FAILED', `unexpected answer from the iPhone to ${request}`);
  if (length > MAX_ANSWER) throw odd;
  const body = await take(socket, length, TIMEOUT_MS, silence);
  let reply: Plist;
  try {
    reply = parse(body.toString('utf8'));
  } catch {
    // The parser's position adds nothing for the caller.
    throw odd;
  }
  if (!isRecord(reply)) throw odd;
  return reply;
}

// The phone's certificate is signed by the pairing's own root, which no system store holds, so it is not verified.
function secure(socket: Socket, record: { cert: Buffer; key: Buffer }): Promise<TLSSocket> {
  const signal = cancellation.getStore();
  return new Promise((resolve, reject) => {
    const tls = tlsConnect({ socket, cert: record.cert, key: record.key, rejectUnauthorized: false });
    const fail = (why: string) => {
      clearTimeout(timer);
      tls.destroy();
      reject(
        signal?.aborted
          ? signal.reason
          : new KaragozError('HELPER_FAILED', `the TLS handshake with the iPhone failed (${why})`),
      );
    };
    const timer = setTimeout(() => fail(`no answer within ${TIMEOUT_MS / 1000} s`), TIMEOUT_MS);
    tls.once('error', (err: Error) => fail('code' in err ? String(err.code) : err.message));
    tls.once('secureConnect', () => {
      clearTimeout(timer);
      // A later failure reaches the read waiting on the socket; with none waiting there is nobody to tell.
      tls.on('error', () => {});
      resolve(tls);
    });
  });
}

async function reach(udid: string, port: number): Promise<Socket> {
  const socket = await connect(udid, port, TIMEOUT_MS, "an iPhone's log");
  if (socket === 'refused') throw new KaragozError('HELPER_FAILED', `nothing answers on the iPhone's port ${port}`);
  return socket;
}

// A lockdown session with this Mac's pairing (no sudo, K44): the phone's clock and its log relay, over TLS. The
// session closes once the relay is open.
export async function relay(udid: string): Promise<{ clock: number; socket: Socket }> {
  const record = await pairRecord(udid, TIMEOUT_MS);
  const lockdown = await reach(udid, LOCKDOWN);
  let session: Socket = lockdown;
  try {
    await ask(lockdown, { Request: 'QueryType' });
    const started = await ask(lockdown, {
      Request: 'StartSession',
      ProtocolVersion: '2',
      HostID: record.hostId,
      SystemBUID: record.systemBuid,
    });
    if (typeof started.Error === 'string') {
      throw new KaragozError(
        'DEVICE_NOT_READY',
        `device ${udid} is not ready: the iPhone refused a session (${started.Error}). ${TRUST}`,
      );
    }
    if (started.EnableSessionSSL === true) session = await secure(lockdown, record);
    const { Value: clock } = await ask(session, { Request: 'GetValue', Key: 'TimeIntervalSince1970' });
    if (typeof clock !== 'number') throw new KaragozError('HELPER_FAILED', 'the iPhone did not tell its time');
    const service = await ask(session, { Request: 'StartService', Service: SERVICE });
    if (typeof service.Error === 'string') {
      throw new KaragozError('HELPER_FAILED', `the iPhone did not start its log service (${service.Error})`);
    }
    if (typeof service.Port !== 'number') {
      throw new KaragozError('HELPER_FAILED', 'the iPhone did not say where its log service listens');
    }
    const raw = await reach(udid, service.Port);
    try {
      return { clock, socket: service.EnableServiceSSL === true ? await secure(raw, record) : raw };
    } catch (err) {
      raw.destroy();
      throw err;
    }
  } finally {
    session.destroy();
    lockdown.destroy();
  }
}

// The relay sends the archive's tar in frames: 0x03, a little-endian length, the bytes (K44).
function deframe(): Transform {
  let pending: Buffer = Buffer.alloc(0);
  return new Transform({
    transform(chunk: Buffer, _encoding, done) {
      pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
      while (pending.length >= 5) {
        if (pending[0] !== 3) {
          done(new KaragozError('HELPER_FAILED', "unexpected data in the iPhone's log stream"));
          return;
        }
        const size = pending.readUInt32LE(1);
        if (pending.length < 5 + size) break;
        this.push(pending.subarray(5, 5 + size));
        pending = pending.subarray(5 + size);
      }
      done();
    },
    flush(done) {
      done(pending.length ? new KaragozError('HELPER_FAILED', "the iPhone's log archive ended early") : null);
    },
  });
}

// The phone's records from startTime (whole seconds, its clock) on, as a tar written into sink as it arrives: the
// archive is ~230 MB for a minute and never whole in memory (K44 M5). The phone builds it from whole files, so it
// starts somewhat earlier. Both ends are closed when this returns or throws.
export async function archive(socket: Socket, startTime: number, sink: Writable): Promise<void> {
  const signal = cancellation.getStore();
  const silence = `the iPhone sent no log data for ${IDLE_MS / 1000} s`;
  try {
    send(socket, { Request: 'CreateArchive', StartTime: startTime });
    const head = await take(socket, 5, IDLE_MS, silence);
    if (head[0] !== 1 || head.readUInt32BE(1) > MAX_ANSWER) {
      throw new KaragozError('HELPER_FAILED', "unexpected answer from the iPhone's log service");
    }
    const status = await take(socket, head.readUInt32BE(1), IDLE_MS, silence);
    // A binary plist with one key, Status; its text tells success apart.
    if (!status.toString('latin1').includes('RequestSuccessful')) {
      const text = status
        .toString('latin1')
        .replace(/[^\x20-\x7e]+/g, ' ')
        .trim();
      throw new KaragozError(
        'HELPER_FAILED',
        `the iPhone's log service did not build an archive: ${text.slice(0, 300)}`,
      );
    }
    socket.setTimeout(IDLE_MS, () => socket.destroy(new KaragozError('HELPER_FAILED', silence)));
    await (signal ? pipeline(socket, deframe(), sink, { signal }) : pipeline(socket, deframe(), sink));
  } catch (err) {
    signal?.throwIfAborted();
    throw err;
  } finally {
    socket.destroy();
    sink.destroy();
  }
}
