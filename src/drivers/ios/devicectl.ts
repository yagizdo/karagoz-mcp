import { execFile } from 'node:child_process';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { isRecord } from './devices.js';
import { developerDir } from './simctl.js';

const run = promisify(execFile);

// list devices measured at 0.06 s, a simulator's info displays 0.06-0.11 s; the timeout only bounds a stuck CoreDevice
// service.
const TIMEOUT_MS = 10_000;

// list devices prints simulators too: 48 KB for one phone and four simulators, measured (K39).
const MAX_BUFFER = 64 * 1024 * 1024;

// ponytail: Apple's private path, the binary Xcode's devicectl shim execs, called directly for the reason simctl's is
// (K32). If Apple moves it, rotation reads as null.
const FRAMEWORK = '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl';

export function devicectlPath(): string {
  const dev = developerDir();
  return dev ? join(dev, 'usr', 'bin', 'devicectl') : FRAMEWORK;
}

// Every devicectl call. No --timeout (devicectl refuses values under 5 s) and no --omit-deprecated-fields-in-json
// (devicectl before 642 rejects it) (K39).
async function devicectl(args: string[], timeout: number): Promise<string> {
  const bin = devicectlPath();
  const signal = cancellation.getStore();
  // An aborted signal still spawns devicectl and kills it a tick later.
  signal?.throwIfAborted();
  try {
    return (await run(bin, args, { timeout, maxBuffer: MAX_BUFFER, ...(signal && { signal }) })).stdout;
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    // The SDK sends no response for a cancelled call, so the abort passes through unmapped (K31).
    if (signal?.aborted) throw err;
    if ('code' in err && err.code === 'ENOENT') {
      throw new KaragozError(
        'DEVICECTL_NOT_FOUND',
        developerDir()
          ? `devicectl not found (tried ${bin}, from DEVELOPER_DIR). Point DEVELOPER_DIR at an Xcode 15 or later, not the Command Line Tools, or unset it.`
          : `devicectl not found (tried ${bin}). Install Xcode 15 or later and open it once.`,
      );
    }
    if ('killed' in err && err.killed) {
      throw new KaragozError(
        'DEVICECTL_TIMEOUT',
        `devicectl did not answer within ${timeout / 1000}s. CoreDevice's service may still be starting or be stuck.`,
      );
    }
    const stderr = 'stderr' in err && typeof err.stderr === 'string' ? err.stderr.trim() : '';
    throw new KaragozError('DEVICECTL_FAILED', (stderr || err.message).slice(0, 300));
  }
}

// Each group is read from Xcode 27's properties dictionary, else from the key it deprecates (Xcode 15-26).
const group = (current: unknown, deprecated: unknown) =>
  isRecord(current) ? current : isRecord(deprecated) ? deprecated : {};

// Attached iPhones only, not the simulators, remembered phones and other devices devicectl also lists. state is the
// pairing state, the one field that says "tap Trust"; name is the model, never the owner-set name (K18 4.1 note).
// ponytail: iOS 16 and older phones show as unavailable without a UDID, so they are not listed (K39).
export async function listPhones() {
  const out = await devicectl(['list', 'devices', '--json-output', '-', '-q'], TIMEOUT_MS);
  let parsed: unknown;
  try {
    parsed = JSON.parse(out);
  } catch {
    // Output that is not JSON fails the shape check below with the same message as JSON of the wrong shape.
  }
  const result = isRecord(parsed) ? parsed.result : undefined;
  const devices = isRecord(result) ? result.devices : undefined;
  if (!Array.isArray(devices)) {
    throw new KaragozError(
      'DEVICECTL_FAILED',
      `unexpected devicectl output: ${(out.split('\n')[0] ?? '').slice(0, 300)}`,
    );
  }
  return devices.flatMap((device: unknown) => {
    if (!isRecord(device)) return [];
    const properties = isRecord(device.properties) ? device.properties : {};
    const { udid, reality, platform, marketingName } = group(properties.hardware, device.hardwareProperties);
    const connection = group(properties.connection, device.connectionProperties);
    const { pairingState } = connection;
    // devicectl 642.16 omits reality for an unpaired phone (measured).
    if ((reality !== undefined && reality !== 'physical') || platform !== 'iOS') return [];
    if ((connection.state ?? connection.tunnelState) === 'unavailable') return [];
    if (device.visibilityClass !== undefined && device.visibilityClass !== 'default') return [];
    if (typeof udid !== 'string' || typeof pairingState !== 'string') return [];
    const name = typeof marketingName === 'string' ? marketingName : null;
    return [{ id: udid, platform: 'ios', kind: 'physical', state: pairingState, name }];
  });
}

// Apple's rotN and Android's ROTATION_N turn opposite ways: landscapeLeft (turned counter-clockwise) is rot270 in
// devicectl and ROTATION_90 on Android (K34).
const ROTATION = new Map([
  ['rot0', 0],
  ['rot90', 270],
  ['rot180', 180],
  ['rot270', 90],
]);

// The display info displays marks primary, else the first; undefined when the output is not that JSON.
function primaryDisplay(stdout: string): Record<string, unknown> | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    // Not JSON reads as no display, which each caller already handles.
    return undefined;
  }
  const result = isRecord(parsed) ? parsed.result : undefined;
  const displays = isRecord(result) && Array.isArray(result.displays) ? result.displays.filter(isRecord) : [];
  return displays.find((d) => d.primary === true) ?? displays[0];
}

// The simulator's interface orientation. It is metadata, so any failure is null, meaning unknown, rather than an error
// (K6 3.2 note); Xcode 26's devicectl does not read simulators.
export async function rotation(udid: string): Promise<number | null> {
  let stdout: string;
  try {
    stdout = await devicectl(['device', 'info', 'displays', '--device', udid, '--json-output', '-', '-q'], TIMEOUT_MS);
  } catch (err) {
    // The SDK sends no response for a cancelled call, so the abort passes through (K31); anything else is unknown.
    if (cancellation.getStore()?.aborted) throw err;
    return null;
  }
  const orientation = primaryDisplay(stdout)?.currentOrientation;
  return typeof orientation === 'string' ? (ROTATION.get(orientation) ?? null) : null;
}
