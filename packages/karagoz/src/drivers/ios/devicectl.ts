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

// The first verb on an idle iPhone brings its tunnel up (3.89 s measured) and may mount the developer disk image; 30 s is
// what simctl gets (K32, K40).
const PHONE_TIMEOUT_MS = 30_000;

export const TRUST =
  'Unlock the iPhone, tap Trust on "Trust This Computer?" and enter the passcode; if no prompt shows, unplug it and plug it in again.';

// What the iPhone's user has to do, by the text devicectl prints, first match wins (K40). Matched on the whole stderr:
// a Developer Mode or lock line can follow a long disk-image error.
const PHONE_STATES: [string[], string][] = [
  [['must be paired'], `it is not paired with this Mac. ${TRUST}`],
  [
    ['developer mode is turned off', 'developer mode is disabled', 'developer mode is no longer enabled'],
    'Developer Mode is off. Turn it on in Settings > Privacy & Security > Developer Mode, then restart the iPhone.',
  ],
  [['device is locked', 'still locked'], 'it is locked. Unlock the iPhone and try again.'],
];

// Every devicectl call; udid names the iPhone a device verb targets, whose failures may be one of PHONE_STATES. No
// --timeout (devicectl refuses values under 5 s) and no --omit-deprecated-fields-in-json (devicectl before 642 rejects
// it) (K39).
async function devicectl(args: string[], timeout: number, udid?: string): Promise<string> {
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
    const lower = stderr.toLowerCase();
    const state = udid === undefined ? undefined : PHONE_STATES.find(([texts]) => texts.some((t) => lower.includes(t)));
    if (state) throw new KaragozError('DEVICE_NOT_READY', `device ${udid} is not ready: ${state[1]}`);
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

function rotationOf(display: Record<string, unknown> | undefined): number | null {
  const orientation = display?.currentOrientation;
  return typeof orientation === 'string' ? (ROTATION.get(orientation) ?? null) : null;
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
  return rotationOf(primaryDisplay(stdout));
}

// An iPhone's point scale, interface orientation and native panel size (portrait), from the display capture screenshot
// takes by default. Unlike a simulator's rotation, the scale is required, so a failure is an error.
export async function displayOf(
  udid: string,
): Promise<{ scale: number; rotation: number | null; panel: { width: number; height: number } | undefined }> {
  const stdout = await devicectl(
    ['device', 'info', 'displays', '--device', udid, '--json-output', '-', '-q'],
    PHONE_TIMEOUT_MS,
    udid,
  );
  const display = primaryDisplay(stdout);
  const scale = display?.pointScale;
  if (typeof scale !== 'number' || !Number.isFinite(scale) || scale <= 0) {
    throw new KaragozError('CAPTURE_FAILED', "cannot read scale from 'devicectl device info displays'");
  }
  const size = display?.nativeSize;
  const pair: unknown[] = Array.isArray(size) ? size : [];
  const [width, height] = pair;
  const panel = typeof width === 'number' && typeof height === 'number' ? { width, height } : undefined;
  return { scale, rotation: rotationOf(display), panel };
}

// devicectl writes the PNG to a .png path in an existing directory; it refuses - (K40).
export async function captureScreen(udid: string, file: string): Promise<void> {
  try {
    await devicectl(
      ['device', 'capture', 'screenshot', '--device', udid, '--destination', file, '-q'],
      PHONE_TIMEOUT_MS,
      udid,
    );
  } catch (err) {
    // Xcode 26's devicectl has no capture verb and rejects the call at argument parsing (Unknown option '--device'),
    // a usage text no device failure prints (K40).
    const message = err instanceof KaragozError && err.code === 'DEVICECTL_FAILED' ? err.message.toLowerCase() : '';
    if (message.includes("unknown option '") || message.includes("unexpected argument 'capture'")) {
      throw new KaragozError(
        'NOT_SUPPORTED',
        "'screenshot' on an iPhone needs Xcode 27 or later: this Mac's devicectl has no 'device capture screenshot'. Install Xcode 27 and open it once.",
      );
    }
    throw err;
  }
}

// devicectl's JSON on stdout, or DEVICECTL_FAILED naming what it printed instead.
function json(stdout: string): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    // Not JSON fails the same check as JSON without a result.
  }
  const result = isRecord(parsed) ? parsed.result : undefined;
  if (!isRecord(result)) {
    throw new KaragozError(
      'DEVICECTL_FAILED',
      `unexpected devicectl output: ${(stdout.split('\n')[0] ?? '').slice(0, 300)}`,
    );
  }
  return result;
}

// The apps devicectl lists by default, the ones a developer installed, which is where karagoz's runner shows (K41).
export async function apps(udid: string): Promise<{ id: string }[]> {
  const result = json(
    await devicectl(['device', 'info', 'apps', '--device', udid, '--json-output', '-', '-q'], PHONE_TIMEOUT_MS, udid),
  );
  const list = Array.isArray(result.apps) ? result.apps : [];
  return list.flatMap((app: unknown) =>
    isRecord(app) && typeof app.bundleIdentifier === 'string' ? [{ id: app.bundleIdentifier }] : [],
  );
}

// Installing the runner sends a few MB over USB and installs its profile; measured in 4.3's phone run (K41).
const INSTALL_TIMEOUT_MS = 120_000;

export async function installApp(udid: string, path: string): Promise<void> {
  try {
    await devicectl(['device', 'install', 'app', '--device', udid, path, '-q'], INSTALL_TIMEOUT_MS, udid);
  } catch (err) {
    if (err instanceof KaragozError && err.code === 'DEVICECTL_FAILED') {
      throw new KaragozError('INSTALL_FAILED', err.message);
    }
    throw err;
  }
}

export async function uninstallApp(udid: string, id: string): Promise<void> {
  try {
    await devicectl(['device', 'uninstall', 'app', '--device', udid, id, '-q'], PHONE_TIMEOUT_MS, udid);
  } catch (err) {
    if (err instanceof KaragozError && err.code === 'DEVICECTL_FAILED') {
      throw new KaragozError('UNINSTALL_FAILED', err.message);
    }
    throw err;
  }
}

// Every string in a value, depth first.
const strings = (value: unknown): string[] =>
  typeof value === 'string'
    ? [value]
    : Array.isArray(value)
      ? value.flatMap(strings)
      : isRecord(value)
        ? Object.values(value).flatMap(strings)
        : [];

// Provisioning profiles on the phone with their UUID and every application identifier (TEAMID.bundle.id) they carry.
// ponytail: read by key name and value shape, not a fixed path; the JSON layout was first seen in 4.3's phone run.
export async function profiles(udid: string): Promise<{ uuid: string; appIds: string[] }[]> {
  const result = json(
    await devicectl(
      ['device', 'profile', 'list', '--device', udid, '--type', 'provisioning', '--json-output', '-', '-q'],
      PHONE_TIMEOUT_MS,
      udid,
    ),
  );
  const list = Object.values(result).find(Array.isArray) ?? [];
  return list.flatMap((profile: unknown) => {
    if (!isRecord(profile)) return [];
    const uuid = Object.entries(profile).find(([key]) => key.toLowerCase() === 'uuid')?.[1];
    if (typeof uuid !== 'string') return [];
    return [{ uuid, appIds: strings(profile).filter((text) => /^[A-Z0-9]{10}\.\S+$/.test(text)) }];
  });
}

export async function removeProfile(udid: string, uuid: string): Promise<void> {
  await devicectl(['device', 'profile', 'remove', '--device', udid, uuid, '-q'], PHONE_TIMEOUT_MS, udid);
}
