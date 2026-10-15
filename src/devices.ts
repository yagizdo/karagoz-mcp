import { describe, entries, listDevices } from './drivers/android/devices.js';
import { listSimulators } from './drivers/ios/devices.js';
import { KaragozError } from './errors.js';

type Platform = 'android' | 'ios';
type Row = { id: string; platform: string; kind: string; state: string; name: string | null };
type Listing<T> = { platform: Platform; rows: T[] } | { platform: Platform; error: KaragozError };
// A device as resolution sees it. Android names stay null until no id matches: each one costs an adb call (K21).
type Candidate = { id: string; platform: Platform; state: string; name: string | null };

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

// When every platform tried fails, Android's error is the envelope, as before 3.1.
export async function listAll() {
  const listings = await Promise.all([
    attempt<Row>('android', listDevices),
    ...(IS_MAC ? [attempt<Row>('ios', listSimulators)] : []),
  ]);
  const failed = listings.flatMap((listing) => ('error' in listing ? [listing] : []));
  const [first] = failed;
  if (first && failed.length === listings.length) throw first.error;
  const devices = listings.flatMap((listing) => ('rows' in listing ? listing.rows : []));
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
  ? 'no device found. Start an emulator (emulator -avd <name>), connect a phone with USB debugging on, or boot a simulator (open -a Simulator; on Xcode 27, xcrun simctl boot <name>).'
  : 'no device found. Start an emulator (emulator -avd <name>) or connect a phone with USB debugging on.';

// Ids first on both platforms, then names: iOS names come with the listing, Android names through describe(), the
// same function devices prints (K21). A name is case-sensitive and no platform wins a clash (K21 3.1 note).
async function find(device: string | undefined): Promise<Candidate> {
  const listings = await Promise.all([
    attempt<Candidate>('android', async () =>
      (await entries()).map(({ id, state }) => ({ id, platform: 'android' as const, state, name: null })),
    ),
    ...(IS_MAC
      ? [
          attempt<Candidate>('ios', async () =>
            (await listSimulators()).map(({ id, state, name }) => ({ id, platform: 'ios' as const, state, name })),
          ),
        ]
      : []),
  ]);
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

function ready({ id, platform, state }: Candidate): string {
  if (state === (platform === 'ios' ? 'Booted' : 'device')) return id;
  const hint = state === 'unauthorized' ? ' Accept the USB debugging prompt on the device.' : '';
  throw new KaragozError('DEVICE_NOT_READY', `device ${id} is not ready (state: ${state}).${hint}`);
}

// Every later adb call passes -s <id> and every simctl call the UDID, so the tools' own defaults never apply (K21).
export async function resolveTarget(device: string | undefined): Promise<{ id: string; platform: Platform }> {
  const target = await find(device);
  return { id: ready(target), platform: target.platform };
}
