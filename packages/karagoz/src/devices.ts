import { describe, entries, listDevices, notReady as notReadyAndroid } from './drivers/android/devices.js';
import { listPhones, notReadyPhone } from './drivers/ios/devicectl.js';
import { listSimulators, notReady as notReadySimulator } from './drivers/ios/devices.js';
import { runnerStates } from './drivers/ios/runner.js';
import { runnerOnSimulators } from './drivers/ios/xcode.js';
import { KaragozError } from './errors.js';

type Platform = 'android' | 'ios';
type Listing<T> = { platform: Platform; rows: T[] } | { platform: Platform; error: KaragozError };
type Ios = { id: string; platform: 'ios'; kind: 'simulator' | 'physical'; state: string; name: string | null };
// A device as resolution sees it. Android names stay null until no id matches: each one costs an adb call (K21).
type AndroidCandidate = { id: string; platform: 'android'; state: string; name: string | null };
type Candidate = AndroidCandidate | Ios;

// iOS simulators exist only on macOS (K18 3.1 note).
export const IS_MAC = process.platform === 'darwin';

// A missing or broken tool becomes a per-platform failure instead of hiding the other platform's devices (K18 3.1
// note). Anything else, a bug or a cancelled MCP call, still fails the command.
async function attempt<T>(platform: Platform, list: () => Promise<T[]>): Promise<Listing<T>> {
  try {
    return { platform, rows: await list() };
  } catch (err) {
    if (!(err instanceof KaragozError)) throw err;
    return { platform, error: err };
  }
}

// Every platform's listing, Android first: listAll() and find() fall back to Android's error.
function listPlatforms<T>(android: () => Promise<T[]>) {
  return Promise.all([
    attempt<T | Ios>('android', android),
    ...(IS_MAC ? [attempt<T | Ios>('ios', listSimulators), attempt<T | Ios>('ios', listPhones)] : []),
  ]);
}

// When every platform tried fails, Android's error is the envelope, as before 3.1.
export async function listAll() {
  const listings = await listPlatforms(listDevices);
  const failed = listings.flatMap((listing) => ('error' in listing ? [listing] : []));
  const [first] = failed;
  if (first && failed.length === listings.length) throw first.error;
  const rows = listings.flatMap((listing) => ('rows' in listing ? listing.rows : []));
  // iPhone rows gain runner, last, so every other row stays as it was (K18).
  const states = await runnerStates(rows.filter(({ platform, kind }) => platform === 'ios' && kind === 'physical'));
  const devices = rows.map((row) => (states.has(row.id) ? { ...row, runner: states.get(row.id) ?? null } : row));
  if (!failed.length) return { devices };
  return {
    devices,
    errors: failed.map(({ platform, error }) => ({ platform, code: error.code, message: error.message })),
  };
}

// Order: --device, KARAGOZ_DEVICE, ANDROID_SERIAL (K4 3.2 note). Empty variables count as unset.
function requested(device: string | undefined) {
  if (device !== undefined) return { wanted: device, from: '--device' };
  const karagoz = process.env.KARAGOZ_DEVICE;
  if (karagoz) return { wanted: karagoz, from: 'KARAGOZ_DEVICE' };
  const serial = process.env.ANDROID_SERIAL;
  if (serial) return { wanted: serial, from: 'ANDROID_SERIAL' };
  return undefined;
}

const NO_DEVICE = IS_MAC
  ? 'no device found. Start an emulator (emulator -avd <name>), connect a phone with USB debugging on, or boot a simulator (xcrun simctl boot <name>; on Xcode 26 and older, open -a Simulator also boots one).'
  : 'no device found. Start an emulator (emulator -avd <name>) or connect a phone with USB debugging on.';

// Ids first on both platforms, then names: iOS names come with the listing, Android names through describe(), the
// same function devices prints (K21). A name is case-sensitive and no platform wins a clash (K21 3.1 note).
async function find(device: string | undefined): Promise<Candidate> {
  const listings = await listPlatforms<AndroidCandidate>(async () =>
    (await entries()).map(({ id, state }) => ({ id, platform: 'android' as const, state, name: null })),
  );
  const listed = listings.flatMap((listing) => ('rows' in listing ? listing.rows : []));
  const failed = listings.flatMap((listing) => ('error' in listing ? [listing.error] : []));
  const request = requested(device);
  const [android] = listings;
  // Nothing listed and adb could not look (every platform failing included): Android's error, as before 3.2, so a
  // Mac without adb still gets the install hint rather than NO_DEVICE.
  if ('error' in android && !listed.length) throw android.error;
  // A missing tool means that platform has no devices. Any other failure may hide one, so it stops the call unless
  // the value names a listed id exactly.
  const hiding = failed.find((error) => !error.code.endsWith('_NOT_FOUND'));
  if (hiding && !(request && listed.some(({ id }) => id === request.wanted))) throw hiding;

  let found = listed;
  if (request) {
    const { wanted, from } = request;
    found = listed.filter(({ id }) => id === wanted);
    if (!found.length) {
      const named = await Promise.all(
        listed.map(async (candidate) =>
          candidate.platform === 'android' ? { ...candidate, name: (await describe(candidate)).name } : candidate,
        ),
      );
      found = named.filter(({ name }) => name === wanted);
      if (!found.length) {
        const ids = named.map(({ id, name }) => (name ? `${id} (${name})` : id));
        const listing = ids.length ? `Listed: ${ids.join(', ')}.` : 'No device is listed.';
        throw new KaragozError(
          'DEVICE_NOT_FOUND',
          `device '${wanted}' from ${from} matches no device id or name. ${listing}`,
        );
      }
    }
  }
  const [target, ...others] = found;
  if (!target) throw new KaragozError('NO_DEVICE', NO_DEVICE);
  // With several devices and none named, karagoz refuses as adb does: an agent on the wrong device is worse.
  if (others.length) {
    const ids = found.map(({ id }) => id).join(', ');
    throw new KaragozError(
      'DEVICE_AMBIGUOUS',
      `more than one device: ${ids}. Pick one with --device <id> or KARAGOZ_DEVICE.`,
    );
  }
  return target;
}

// Each driver knows its tool's states: undefined means ready, else the hint, empty when there is none.
function ready(target: Candidate): string {
  const hint =
    target.platform === 'android'
      ? notReadyAndroid(target.state)
      : target.kind === 'simulator'
        ? notReadySimulator(target.state)
        : notReadyPhone(target.state);
  if (hint === undefined) return target.id;
  throw new KaragozError(
    'DEVICE_NOT_READY',
    `device ${target.id} is not ready (state: ${target.state}).${hint ? ` ${hint}` : ''}`,
  );
}

// Every later adb call passes -s <id> and every simctl call the UDID, so the tools' own defaults never apply (K21).
// Every command runs on an iPhone (K21 4.6 note); 'iphone-only' (the runner's own commands) refuses everything else, a
// permanent answer given before any readiness check (K21 4.3 note). 'runner' also takes a simulator on a Mac where
// karagoz's runner plays its input (K49).
export async function resolveTarget(
  device: string | undefined,
  accept?: 'iphone-only' | 'runner',
): Promise<{ id: string; platform: 'android' } | { id: string; platform: 'ios'; kind: 'simulator' | 'physical' }> {
  const target = await find(device);
  const physical = target.platform === 'ios' && target.kind === 'physical';
  const simulator = target.platform === 'ios' && target.kind === 'simulator';
  if (accept !== undefined && !physical && !(accept === 'runner' && simulator && (await runnerOnSimulators()))) {
    throw new KaragozError(
      'NOT_SUPPORTED',
      `device ${target.id} is not an iPhone; karagoz's runner runs only on iPhones.`,
    );
  }
  if (target.platform === 'android') return { id: ready(target), platform: 'android' };
  return { id: ready(target), platform: 'ios', kind: target.kind };
}
