import { execFile } from 'node:child_process';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { isRecord } from './devices.js';
import { developerDir } from './simctl.js';

const run = promisify(execFile);

// Measured at 0.06 s; the timeout only bounds a stuck CoreDevice service.
const TIMEOUT_MS = 10_000;

// ponytail: Apple's private path, the binary Xcode's devicectl shim execs, called directly for the reason simctl's is
// (K32). If Apple moves it, rotation reads as null.
const FRAMEWORK = '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl';

// Apple's rotN and Android's ROTATION_N turn opposite ways: landscapeLeft (turned counter-clockwise) is rot270 in
// devicectl and ROTATION_90 on Android (K34).
const ROTATION = new Map([
  ['rot0', 0],
  ['rot90', 270],
  ['rot180', 180],
  ['rot270', 90],
]);

// The simulator's interface orientation. It is metadata, so any failure is null, meaning unknown, rather than an error
// (K6 3.2 note); Xcode 26's devicectl does not read simulators.
export async function rotation(udid: string): Promise<number | null> {
  const dev = developerDir();
  const bin = dev ? join(dev, 'usr', 'bin', 'devicectl') : FRAMEWORK;
  const signal = cancellation.getStore();
  // An aborted signal still spawns devicectl and kills it a tick later.
  signal?.throwIfAborted();
  let parsed: unknown;
  try {
    const { stdout } = await run(bin, ['device', 'info', 'displays', '--device', udid, '--json-output', '-', '-q'], {
      timeout: TIMEOUT_MS,
      ...(signal && { signal }),
    });
    parsed = JSON.parse(stdout);
  } catch (err) {
    // The SDK sends no response for a cancelled call, so the abort passes through (K31); anything else is unknown.
    if (signal?.aborted) throw err;
    return null;
  }
  const result = isRecord(parsed) ? parsed.result : undefined;
  const displays = isRecord(result) && Array.isArray(result.displays) ? result.displays.filter(isRecord) : [];
  const display = displays.find((d) => d.primary === true) ?? displays[0];
  const orientation = display?.currentOrientation;
  return typeof orientation === 'string' ? (ROTATION.get(orientation) ?? null) : null;
}
