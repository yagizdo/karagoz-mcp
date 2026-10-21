import { KaragozError } from '../../errors.js';
import { isRecord } from './record.js';
import { simctl } from './simctl.js';

// iPads share the iOS runtime. watchOS, tvOS and visionOS (xrOS-) runtimes are dropped: no karagoz command acts on
// them (K18 3.1 note).
const IOS_RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-';

// `list devices --json` is {devices: {<runtime id>: [device, ...]}} since Xcode 10.2 (K32). Only running, available
// simulators are listed: karagoz cannot boot one, and adb lists only running devices too (K18 3.1 note).
export async function listSimulators() {
  const out = await simctl(['list', 'devices', '--json']);
  let parsed: unknown;
  try {
    parsed = JSON.parse(out);
  } catch {
    // Output that is not JSON fails the shape check below with the same message as JSON of the wrong shape.
  }
  const runtimes = isRecord(parsed) ? parsed.devices : undefined;
  if (!isRecord(runtimes) || !Object.values(runtimes).every((list) => Array.isArray(list))) {
    throw new KaragozError('SIMCTL_FAILED', `unexpected simctl output: ${(out.split('\n')[0] ?? '').slice(0, 300)}`);
  }
  return Object.entries(runtimes)
    .filter(([runtime]) => runtime.startsWith(IOS_RUNTIME))
    .flatMap(([, list]) => (Array.isArray(list) ? list : []))
    .flatMap((device: unknown) => {
      if (!isRecord(device)) return [];
      const { udid, name, state, isAvailable } = device;
      if (typeof udid !== 'string' || typeof name !== 'string' || typeof state !== 'string') return [];
      if (isAvailable !== true || state === 'Shutdown') return [];
      return [{ id: udid, platform: 'ios', kind: 'simulator', state, name }];
    });
}
