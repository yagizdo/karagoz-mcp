import { dirname, join } from 'node:path';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { runTool } from '../../tool.js';
import { isRecord } from './record.js';
import { developerDir } from './simctl.js';

// list devices measured at 0.06 s, a simulator's info displays 0.06-0.11 s; the timeout only bounds a stuck CoreDevice
// service.
const TIMEOUT_MS = 10_000;

// list devices prints simulators too: 48 KB for one phone and four simulators, measured (K39).
const MAX_BUFFER = 64 * 1024 * 1024;

// ponytail: Apple's private path, the binary Xcode's devicectl shim execs, called directly for the reason simctl's is
// (K32). If Apple moves it, rotation reads as null.
const FRAMEWORK = '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl';

// Its Info.plist: CFBundleVersion is the CoreDevice version a devicectl shim's EXPECTED_VERSION names.
export const COREDEVICE_PLIST = join(dirname(FRAMEWORK), '..', 'Info.plist');

export function devicectlPath(): string {
  const dev = developerDir();
  return dev ? join(dev, 'usr', 'bin', 'devicectl') : FRAMEWORK;
}

// The first verb on an idle iPhone brings its tunnel up (3.89 s measured) and may mount the developer disk image; 30 s is
// what simctl gets (K32, K40).
export const PHONE_TIMEOUT_MS = 30_000;

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
  // A launch on a locked iPhone says "…because the device was not, or could not be, unlocked." (K43).
  [['device is locked', 'still locked', 'could not be, unlocked'], 'it is locked. Unlock the iPhone and try again.'],
];

// One error of devicectl's JSON on stdout, outermost first, each with the sentence it carries.
type Link = { domain: string; code: number; description: string | undefined; sentence: string | undefined };

const text = (value: unknown) => (isRecord(value) && typeof value.string === 'string' ? value.string : undefined);

// The error chain of a failed call run with --json-output -: the phone's own cause sits a few links down (K43).
function links(stdout: string): Link[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    // Not devicectl's JSON (an argument error writes none): no chain.
    return [];
  }
  const chain: Link[] = [];
  let error = isRecord(parsed) ? parsed.error : undefined;
  while (isRecord(error) && typeof error.domain === 'string' && typeof error.code === 'number') {
    const info = isRecord(error.userInfo) ? error.userInfo : {};
    const description = text(info.NSLocalizedDescription);
    const sentence = text(info.NSLocalizedFailureReason) ?? text(info.NSLocalizedRecoverySuggestion) ?? description;
    chain.push({ domain: error.domain, code: error.code, description, sentence });
    error = isRecord(info.NSUnderlyingError) ? info.NSUnderlyingError.error : undefined;
  }
  return chain;
}

// The outermost description, then the deepest sentence: "Failed to install the app on the device." and why.
function said(chain: Link[]): string {
  const deepest = chain.findLast((link) => link.sentence !== undefined)?.sentence;
  const parts = [chain[0]?.description, deepest].filter((part): part is string => part !== undefined);
  return [...new Set(parts)].join(' ').slice(0, 300);
}

// <domain>:<code> of the deepest link, the phone's own cause; the outermost is CoreDeviceError 3002 for every refused
// install (K43).
const at = (chain: Link[]) => {
  const deepest = chain.at(-1);
  return deepest && `${deepest.domain}:${deepest.code}`;
};

const has = (chain: Link[], domain: string, code: number) =>
  chain.some((link) => link.domain === domain && link.code === code);

// Every devicectl call; udid names the iPhone a device verb targets, whose failures may be one of PHONE_STATES. With
// failed, a failure that left devicectl's JSON error chain on stdout goes to it: it returns the error to throw, or null
// when the failure counts as done. No --timeout (devicectl refuses values under 5 s) and no
// --omit-deprecated-fields-in-json (devicectl before 642 rejects it) (K39).
async function devicectl(
  args: string[],
  timeout: number,
  udid?: string,
  failed?: (chain: Link[]) => KaragozError | null,
): Promise<string> {
  const bin = devicectlPath();
  const result = await runTool(bin, args, { timeout, maxBuffer: MAX_BUFFER });
  if (result.ok) return result.stdout.toString('utf8');
  const { failure } = result;
  if (failure.kind === 'missing') {
    throw new KaragozError(
      'DEVICECTL_NOT_FOUND',
      developerDir()
        ? `devicectl not found (tried ${bin}, from DEVELOPER_DIR). Point DEVELOPER_DIR at an Xcode 15 or later, not the Command Line Tools, or unset it.`
        : `devicectl not found (tried ${bin}). Install Xcode 15 or later and open it once.`,
    );
  }
  if (failure.kind === 'timeout') {
    throw new KaragozError(
      'DEVICECTL_TIMEOUT',
      `devicectl did not answer within ${timeout / 1000}s. CoreDevice's service may still be starting or be stuck.`,
    );
  }
  const lower = failure.stderr.toLowerCase();
  const state = udid === undefined ? undefined : PHONE_STATES.find(([texts]) => texts.some((t) => lower.includes(t)));
  if (state) throw new KaragozError('DEVICE_NOT_READY', `device ${udid} is not ready: ${state[1]}`);
  const chain = failed ? links(failure.stdout) : [];
  if (failed && chain.length) {
    const error = failed(chain);
    if (error) throw error;
    return '';
  }
  throw new KaragozError('DEVICECTL_FAILED', (failure.stderr || failure.message).slice(0, 300));
}

// Each group is read from Xcode 27's properties dictionary, else from the key it deprecates (Xcode 15-26).
const group = (current: unknown, deprecated: unknown) =>
  isRecord(current) ? current : isRecord(deprecated) ? deprecated : {};

// Attached iPhones only, not the simulators, remembered phones and other devices devicectl also lists. state is the
// pairing state, the one field that says "tap Trust"; name is the model, never the owner-set name (K18 4.1 note).
// ponytail: iOS 16 and older phones show as unavailable without a UDID, so they are not listed (K39).
export async function listPhones() {
  const out = await devicectl(['list', 'devices', '--json-output', '-', '-q'], TIMEOUT_MS);
  const { devices } = json(out);
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
    return [{ id: udid, platform: 'ios' as const, kind: 'physical' as const, state: pairingState, name }];
  });
}

// An iPhone is ready once paired; Developer Mode is not in the listing while its tunnel is idle, so the capture's own
// failure reports it (K21 4.2 note). undefined when ready; otherwise what the person does, empty when nothing helps.
export function notReadyPhone(state: string): string | undefined {
  if (state === 'paired') return undefined;
  if (state === 'unpaired') return TRUST;
  return state === 'pairingInProgress' ? 'Finish pairing on the iPhone: tap Trust, then enter the passcode.' : '';
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

// Provisioning profiles on the phone with their UUID and application identifier (TEAMID.bundle.id, or TEAMID.* for a
// team wildcard), as devicectl 651.13.5 lists them (measured, K41).
export async function profiles(udid: string): Promise<{ uuid: string; appId: string }[]> {
  const result = json(
    await devicectl(
      ['device', 'profile', 'list', '--device', udid, '--type', 'provisioning', '--json-output', '-', '-q'],
      PHONE_TIMEOUT_MS,
      udid,
    ),
  );
  const list = Array.isArray(result.provisioningProfiles) ? result.provisioningProfiles : [];
  return list.flatMap((profile: unknown) =>
    isRecord(profile) && typeof profile.uuid === 'string' && typeof profile.appIdentifier === 'string'
      ? [{ uuid: profile.uuid, appId: profile.appIdentifier }]
      : [],
  );
}

export async function removeProfile(udid: string, uuid: string): Promise<void> {
  await devicectl(['device', 'profile', 'remove', '--device', udid, uuid, '-q'], PHONE_TIMEOUT_MS, udid);
}

const RESIGN =
  ' karagoz installs an app as it was built and does not re-sign it: build it for this iPhone (Xcode or Flutter sign it with a profile that includes this iPhone).';

// A user's .app or .ipa as it was built (K43). A refusal's reason is the phone's own cause; the code-signing check
// (MIInstallerErrorDomain 13, ApplicationVerificationFailed) also refuses a simulator build and an unsigned app.
export async function installOn(udid: string, path: string, timeout: number): Promise<void> {
  await devicectl(
    ['device', 'install', 'app', '--device', udid, path, '--json-output', '-', '-q'],
    timeout,
    udid,
    (chain) => {
      const hint = has(chain, 'MIInstallerErrorDomain', 13) ? RESIGN : '';
      return new KaragozError('INSTALL_FAILED', said(chain) + hint, at(chain));
    },
  );
}

// Returns at spawn, before the app is in front; a running app comes to the front with the same pid (K43).
export async function launchOn(udid: string, id: string): Promise<void> {
  const stdout = await devicectl(
    ['device', 'process', 'launch', '--device', udid, id, '--json-output', '-', '-q'],
    PHONE_TIMEOUT_MS,
    udid,
    (chain) =>
      // LaunchServices' "no such app" under CoreDeviceError 10002 (K43).
      has(chain, 'NSOSStatusErrorDomain', -10814)
        ? new KaragozError('APP_NOT_FOUND', `app '${id}' is not installed on ${udid}`)
        : new KaragozError('DEVICECTL_FAILED', said(chain)),
  );
  const process = json(stdout).process;
  if (!isRecord(process) || typeof process.processIdentifier !== 'number') {
    throw new KaragozError(
      'DEVICECTL_FAILED',
      `unexpected devicectl output: ${(stdout.split('\n')[0] ?? '').slice(0, 300)}`,
    );
  }
}

// The installed app's bundle URL, system apps included; undefined when it is not installed.
export async function appOn(udid: string, id: string): Promise<string | undefined> {
  const result = json(
    await devicectl(
      ['device', 'info', 'apps', '--device', udid, '--bundle-id', id, '--include-all-apps', '--json-output', '-', '-q'],
      PHONE_TIMEOUT_MS,
      udid,
    ),
  );
  const list = Array.isArray(result.apps) ? result.apps : [];
  const app: unknown = list.find((entry: unknown) => isRecord(entry) && entry.bundleIdentifier === id);
  return isRecord(app) && typeof app.url === 'string' ? app.url : undefined;
}

// Every process running from the app's bundle, its extensions included. Matched by path, never by executable name:
// every Flutter app's executable is Runner (K43).
export async function pidsUnder(udid: string, url: string): Promise<number[]> {
  const result = json(
    await devicectl(
      ['device', 'info', 'processes', '--device', udid, '--json-output', '-', '-q'],
      PHONE_TIMEOUT_MS,
      udid,
    ),
  );
  const list = Array.isArray(result.runningProcesses) ? result.runningProcesses : [];
  const bundle = url.endsWith('/') ? url : `${url}/`;
  return list.flatMap((entry: unknown) =>
    isRecord(entry) &&
    typeof entry.executable === 'string' &&
    entry.executable.startsWith(bundle) &&
    typeof entry.processIdentifier === 'number'
      ? [entry.processIdentifier]
      : [],
  );
}

// SIGKILL, as Android's force-stop; a process that is already gone (NSPOSIXErrorDomain 3) counts as stopped.
export async function kill(udid: string, pid: number): Promise<void> {
  await devicectl(
    ['device', 'process', 'terminate', '--device', udid, '--pid', String(pid), '--kill', '--json-output', '-', '-q'],
    PHONE_TIMEOUT_MS,
    udid,
    (chain) => (has(chain, 'NSPOSIXErrorDomain', 3) ? null : new KaragozError('DEVICECTL_FAILED', said(chain))),
  );
}

export async function uninstallFrom(udid: string, id: string): Promise<void> {
  await devicectl(
    ['device', 'uninstall', 'app', '--device', udid, id, '--json-output', '-', '-q'],
    PHONE_TIMEOUT_MS,
    udid,
    (chain) => new KaragozError('UNINSTALL_FAILED', said(chain), at(chain)),
  );
}
