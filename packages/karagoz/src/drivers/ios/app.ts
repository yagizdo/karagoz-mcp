import { KaragozError } from '../../errors.js';
import { header, simctl, TIMEOUT_MS } from './simctl.js';

// True when err is simctl's SIMCTL_FAILED with this NSPOSIXErrorDomain code in its header (K36).
function posix(err: unknown, code: number): boolean {
  if (!(err instanceof KaragozError) || err.code !== 'SIMCTL_FAILED') return false;
  const found = header(err.message);
  return found?.domain === 'NSPOSIXErrorDomain' && found.code === code;
}

// The simulator holds a stop, install or removal while a debugger has the app stopped, then finishes it (K36
// framework note). Any other error passes through.
function held(err: unknown, seconds: number, request: string): never {
  if (!(err instanceof KaragozError) || err.code !== 'SIMCTL_TIMEOUT') throw err;
  throw new KaragozError(
    'SIMCTL_TIMEOUT',
    `simctl did not answer within ${seconds}s. If a debugger such as Xcode has the app stopped (a breakpoint or a pause), the simulator holds the ${request} until the app continues or the debug session ends, then finishes it; until then other calls to this simulator can wait too. Otherwise the simulator service may still be starting (the first call after login can take several seconds) or be stuck.`,
  );
}

// get_app_container is the one call that tells "not installed" (NSPOSIXErrorDomain 2) apart: simctl's terminate and
// uninstall report the same result for a missing app as for an idle one (K36). Returns the bundle path.
export async function installed(udid: string, id: string): Promise<string> {
  try {
    return (await simctl(['get_app_container', udid, id])).trim();
  } catch (err) {
    if (posix(err, 2)) throw new KaragozError('APP_NOT_FOUND', `app '${id}' is not installed on ${udid}`);
    throw err;
  }
}

export async function install(udid: string, path: string, timeout: number) {
  await simctl(['install', udid, path], timeout, 'INSTALL_FAILED').catch((err: unknown) =>
    held(err, timeout / 1000, 'install'),
  );
  return { device: udid, path };
}

// simctl launch returns at spawn, before the app is in front, and a running app comes to the front as it is (K36).
export async function launch(udid: string, id: string) {
  let out: string;
  try {
    out = (await simctl(['launch', udid, id])).trim();
  } catch (err) {
    if (!(err instanceof KaragozError) || err.code !== 'SIMCTL_FAILED') throw err;
    // Launch says FBSOpenApplicationServiceErrorDomain 4 for a missing app and for other refusals alike (K36). Only
    // APP_NOT_FOUND from the check matters; any other failure of it would hide the launch error.
    await installed(udid, id).catch((check: unknown) => {
      if (check instanceof KaragozError && check.code === 'APP_NOT_FOUND') throw check;
    });
    throw err;
  }
  // "<id>: <pid>"; compared as text, since a RegExp built from the id would read its dots as any character.
  if (!out.startsWith(`${id}: `) || !/^\d+$/.test(out.slice(id.length + 2))) {
    throw new KaragozError('SIMCTL_FAILED', `unexpected simctl output: ${out.split('\n')[0]}`);
  }
  return { device: udid, package: id, activity: null };
}

export async function terminate(udid: string, id: string) {
  const stop = (err: unknown) => held(err, TIMEOUT_MS / 1000, 'stop');
  await installed(udid, id).catch(stop);
  try {
    await simctl(['terminate', udid, id]);
  } catch (err) {
    // NSPOSIXErrorDomain 3, "found nothing to terminate": installed but not running, which Android counts as done.
    if (!posix(err, 3)) stop(err);
  }
  return { device: udid, package: id };
}

export async function uninstall(udid: string, id: string) {
  // simctl uninstall reports success for an app that is not there. System apps live in the runtime root, user apps
  // under the device's Containers/Bundle/Application (K36).
  const removal = (err: unknown) => held(err, TIMEOUT_MS / 1000, 'removal');
  if (!(await installed(udid, id).catch(removal)).includes('/Containers/Bundle/Application/')) {
    throw new KaragozError(
      'UNINSTALL_FAILED',
      `'${id}' is a system app; a simulator does not remove system apps`,
      'SYSTEM_APP',
    );
  }
  await simctl(['uninstall', udid, id], undefined, 'UNINSTALL_FAILED').catch(removal);
  return { device: udid, package: id };
}
