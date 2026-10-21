import { createConnection, type Socket } from 'node:net';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { TRUST } from './devicectl.js';
import { isRecord } from './devices.js';

// Apple's USB multiplexer daemon; any user may connect (srw-rw-rw-). The phone sees the connection on its loopback, so
// karagoz's runner listens there only (K41).
const DAEMON = '/var/run/usbmuxd';
// Each message: length (header included), version 1, message type 8 (XML plist), tag; little-endian.
const HEADER = 16;
// usbmuxd's result codes: 0 connected, 2 no such device, 3 nothing listens on that port.
const REFUSED = 3;

export type Plist = string | number | boolean | Plist[] | { [key: string]: Plist };

// The variable other usbmux clients read; only its UNIX:<path> form is honored, which the smoke's fake daemon uses.
export function daemonPath(): string {
  const address = process.env.USBMUXD_SOCKET_ADDRESS;
  return address?.startsWith('UNIX:') ? address.slice('UNIX:'.length) : DAEMON;
}

// Also doctor's text for a socket it cannot use (K30 4.7).
export const unreachable = (path: string, code: string) => `cannot reach usbmuxd at ${path} (${code})`;

const escape = (text: string) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// An XML plist of flat string and integer fields: every usbmux and lockdown request karagoz sends is one.
export function plist(fields: Record<string, string | number>): string {
  const entries = Object.entries(fields)
    .map(([key, value]) =>
      typeof value === 'number'
        ? `<key>${key}</key><integer>${String(value)}</integer>`
        : `<key>${key}</key><string>${escape(value)}</string>`,
    )
    .join('');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>${entries}</dict></plist>\n`;
}

function message(fields: Record<string, string | number>): Buffer {
  const body = Buffer.from(plist({ ClientVersionString: 'karagoz', ProgName: 'karagoz', ...fields }));
  const header = Buffer.alloc(HEADER);
  header.writeUInt32LE(HEADER + body.length, 0);
  header.writeUInt32LE(1, 4);
  header.writeUInt32LE(8, 8);
  header.writeUInt32LE(1, 12);
  return Buffer.concat([header, body]);
}

const ENTITIES = new Map([
  ['&lt;', '<'],
  ['&gt;', '>'],
  ['&amp;', '&'],
  ['&quot;', '"'],
  ['&apos;', "'"],
]);

// The XML plist usbmuxd answers with: dict, array, string, integer, real, true, false, data (kept as its text).
export function parse(xml: string): Plist {
  const tokens = [...xml.matchAll(/<[?!][^>]*>|<(\/?)(\w+)[^>]*?(\/?)>|([^<]+)/g)].filter(
    (token) => token[2] !== undefined || (token[4] !== undefined && token[4].trim() !== ''),
  );
  let at = 0;
  const text = () => {
    const token = tokens[at];
    if (token?.[4] === undefined) return '';
    at++;
    return token[4].replace(/&\w+;/g, (entity) => ENTITIES.get(entity) ?? entity);
  };
  const close = (tag: string) => {
    if (tokens[at]?.[1] !== '/' || tokens[at]?.[2] !== tag) throw new Error(`no </${tag}>`);
    at++;
  };
  const value = (): Plist => {
    const token = tokens[at++];
    const tag = token?.[2];
    if (tag === undefined || token?.[1] === '/') throw new Error('expected a value');
    if (tag === 'plist') {
      const inner = value();
      close('plist');
      return inner;
    }
    if (token?.[3] === '/')
      return tag === 'true' ? true : tag === 'false' ? false : tag === 'dict' ? {} : tag === 'array' ? [] : '';
    if (tag === 'dict') {
      const dict: { [key: string]: Plist } = {};
      while (tokens[at]?.[2] === 'key' && tokens[at]?.[1] !== '/') {
        at++;
        const key = text();
        close('key');
        dict[key] = value();
      }
      close('dict');
      return dict;
    }
    if (tag === 'array') {
      const list: Plist[] = [];
      while (tokens[at]?.[1] !== '/') list.push(value());
      close('array');
      return list;
    }
    const content = text();
    close(tag);
    return tag === 'integer' || tag === 'real' ? Number(content) : content;
  };
  return value();
}

// One request and its reply frame. Bytes after the frame already belong to the raw stream and go back to the socket.
function exchange(socket: Socket, request: Buffer, timeoutMs: number): Promise<Plist> {
  return new Promise((resolve, reject) => {
    let buffer = Buffer.alloc(0);
    const done = (finish: () => void) => {
      socket.off('data', data);
      socket.off('error', failed);
      socket.off('close', closed);
      socket.off('timeout', timedOut);
      socket.setTimeout(0);
      finish();
    };
    const data = (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length < HEADER) return;
      const length = buffer.readUInt32LE(0);
      if (buffer.length < length) return;
      socket.pause();
      const rest = buffer.subarray(length);
      if (rest.length) socket.unshift(rest);
      done(() => {
        try {
          resolve(parse(buffer.subarray(HEADER, length).toString('utf8')));
        } catch (err) {
          reject(
            new KaragozError(
              'HELPER_FAILED',
              `unexpected usbmuxd reply: ${err instanceof Error ? err.message : String(err)}`,
            ),
          );
        }
      });
    };
    const failed = (err: Error) => done(() => reject(err));
    const closed = () => done(() => reject(new KaragozError('HELPER_FAILED', 'usbmuxd closed the connection')));
    const timedOut = () => {
      socket.destroy();
      done(() => reject(new KaragozError('HELPER_FAILED', `usbmuxd did not answer within ${timeoutMs / 1000} s`)));
    };
    socket.on('data', data);
    socket.on('error', failed);
    socket.on('close', closed);
    socket.on('timeout', timedOut);
    socket.setTimeout(timeoutMs);
    socket.write(request);
  });
}

function open(timeoutMs: number): Promise<Socket> {
  const signal = cancellation.getStore();
  signal?.throwIfAborted();
  const path = daemonPath();
  return new Promise((resolve, reject) => {
    const socket = createConnection({ path, ...(signal && { signal }) });
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new KaragozError('HELPER_FAILED', `usbmuxd at ${path} did not accept within ${timeoutMs / 1000} s`));
    }, timeoutMs);
    socket.once('connect', () => {
      clearTimeout(timer);
      socket.off('error', failed);
      resolve(socket);
    });
    const failed = (err: Error) => {
      clearTimeout(timer);
      // The SDK sends no response for a cancelled call, so the abort passes through (K31).
      if (signal?.aborted) return reject(err);
      const code = 'code' in err ? String(err.code) : err.message;
      reject(new KaragozError('HELPER_FAILED', unreachable(path, code)));
    };
    socket.once('error', failed);
  });
}

// The usbmux device ids of the phones attached by cable, by UDID (usbmuxd's SerialNumber, compared case-insensitively).
async function attached(timeoutMs: number): Promise<Map<string, number>> {
  const socket = await open(timeoutMs);
  try {
    const reply = await exchange(socket, message({ MessageType: 'ListDevices' }), timeoutMs);
    const list = isRecord(reply) && Array.isArray(reply.DeviceList) ? reply.DeviceList : [];
    const found = new Map<string, number>();
    for (const entry of list) {
      const properties = isRecord(entry) && isRecord(entry.Properties) ? entry.Properties : {};
      const { SerialNumber: serial, DeviceID: id, ConnectionType: type } = properties;
      if (typeof serial === 'string' && typeof id === 'number' && type === 'USB') found.set(serial.toUpperCase(), id);
    }
    return found;
  } finally {
    socket.destroy();
  }
}

// reach names what the caller wanted from the phone: its runner, or its log.
function notOnUsb(udid: string, reach: string): KaragozError {
  return new KaragozError(
    'DEVICE_NOT_READY',
    `device ${udid} is not ready: it is not connected by USB. karagoz reaches ${reach} over a USB cable; connect the iPhone with one.`,
  );
}

// A raw stream to the phone's loopback port, paused (the caller resumes it once it listens), or 'refused' when nothing
// listens there yet. Not attached by cable is DEVICE_NOT_READY, never retried.
export async function connect(
  udid: string,
  port: number,
  timeoutMs: number,
  reach = 'its runner',
): Promise<Socket | 'refused'> {
  const id = (await attached(timeoutMs)).get(udid.toUpperCase());
  if (id === undefined) throw notOnUsb(udid, reach);
  const socket = await open(timeoutMs);
  try {
    // usbmuxd wants the port in network byte order inside the integer.
    const swapped = ((port & 0xff) << 8) | (port >> 8);
    const reply = await exchange(
      socket,
      message({ MessageType: 'Connect', DeviceID: id, PortNumber: swapped }),
      timeoutMs,
    );
    const result = isRecord(reply) ? reply.Number : undefined;
    if (result === 0) return socket;
    socket.destroy();
    if (result === REFUSED) return 'refused';
    if (result === 2) throw notOnUsb(udid, reach);
    throw new KaragozError(
      'HELPER_FAILED',
      `usbmuxd refused the connection (result ${typeof result === 'number' ? result : 'missing'})`,
    );
  } catch (err) {
    socket.destroy();
    throw err;
  }
}

// <data> keeps its base64 text, line breaks included.
const bytes = (value: unknown) =>
  typeof value === 'string' ? Buffer.from(value.replace(/\s/g, ''), 'base64') : undefined;

// What a lockdown session needs from this Mac's pairing with the phone, which usbmuxd hands any local user (K44). It
// stays in memory: no message, log or file ever carries a value of it.
export async function pairRecord(
  udid: string,
  timeoutMs: number,
): Promise<{ hostId: string; systemBuid: string; cert: Buffer; key: Buffer }> {
  const socket = await open(timeoutMs);
  let reply: Plist;
  try {
    reply = await exchange(socket, message({ MessageType: 'ReadPairRecord', PairRecordID: udid }), timeoutMs);
  } finally {
    socket.destroy();
  }
  const data = bytes(isRecord(reply) ? reply.PairRecordData : undefined);
  if (!data) {
    throw new KaragozError(
      'DEVICE_NOT_READY',
      `device ${udid} is not ready: this Mac holds no pairing record for it. ${TRUST}`,
    );
  }
  const unreadable = new KaragozError(
    'HELPER_FAILED',
    `this Mac's pairing record for ${udid} is not in a form karagoz reads`,
  );
  let record: Plist;
  try {
    record = parse(data.toString('utf8'));
  } catch {
    // ponytail: only an XML record is read, which macOS 27 stores; another form gets this message, not its content.
    throw unreadable;
  }
  if (!isRecord(record)) throw unreadable;
  const { HostID: hostId, SystemBUID: systemBuid } = record;
  const cert = bytes(record.HostCertificate);
  const key = bytes(record.HostPrivateKey);
  if (typeof hostId !== 'string' || typeof systemBuid !== 'string' || !cert || !key) throw unreadable;
  return { hostId, systemBuid, cert, key };
}
