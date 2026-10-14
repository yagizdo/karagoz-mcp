import { stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { androidTarget } from './devices.js';
import {
  checkPackage,
  install as androidInstall,
  launch as androidLaunch,
  terminate as androidTerminate,
  uninstall as androidUninstall,
} from './drivers/android/app.js';
import { KaragozError } from './errors.js';

// On GMS phones Android waits up to 17 s for Play Protect's scan, and Xiaomi's and vivo's USB-install prompts refuse
// on their own after 10-11.6 s; a 10 s base gave up just before either answered (K28 2.5 note).
const INSTALL_BASE_MS = 30_000;

// Argument checks first, then the target: INVALID_ARGS comes before any device call (K5, K28).
export async function install(device: string | undefined, apk: string) {
  const path = resolve(apk);
  if (!path.toLowerCase().endsWith('.apk')) throw new KaragozError('INVALID_ARGS', `'${path}' is not an .apk file`);
  // Missing, a path through a file, no permission: the caller fixes each the same way, so the cause is dropped.
  const info = await stat(path).catch(() => undefined);
  if (!info) throw new KaragozError('INVALID_ARGS', `no file at '${path}'`);
  if (!info.isFile()) throw new KaragozError('INVALID_ARGS', `'${path}' is not a file`);
  const id = await androidTarget(device, 'install');
  // One more second per started MB, as input.ts adds a gesture's duration (K19 note, K28).
  const timeout = INSTALL_BASE_MS + Math.ceil(info.size / 1_000_000) * 1000;
  return androidInstall(id, path, timeout);
}

export async function launch(device: string | undefined, pkg: string) {
  checkPackage(pkg);
  return androidLaunch(await androidTarget(device, 'launch'), pkg);
}

export async function terminate(device: string | undefined, pkg: string) {
  checkPackage(pkg);
  return androidTerminate(await androidTarget(device, 'terminate'), pkg);
}

export async function uninstall(device: string | undefined, pkg: string) {
  checkPackage(pkg);
  return androidUninstall(await androidTarget(device, 'uninstall'), pkg);
}
