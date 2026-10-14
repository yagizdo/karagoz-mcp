import { stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { resolveTarget } from './devices.js';
import {
  checkPackage,
  install as androidInstall,
  launch as androidLaunch,
  terminate as androidTerminate,
  uninstall as androidUninstall,
} from './drivers/android/app.js';
import {
  install as iosInstall,
  launch as iosLaunch,
  terminate as iosTerminate,
  uninstall as iosUninstall,
} from './drivers/ios/app.js';
import { KaragozError } from './errors.js';

// On GMS phones Android waits up to 17 s for Play Protect's scan, and Xiaomi's and vivo's USB-install prompts refuse
// on their own after 10-11.6 s; a 10 s base gave up just before either answered (K28 2.5 note).
const INSTALL_BASE_MS = 30_000;

// Argument checks first, then the target: INVALID_ARGS comes before any device call (K5, K28).
export async function install(device: string | undefined, apk: string) {
  const path = resolve(apk);
  // Not extname: it reads '/tmp/.apk' as a dotfile with no extension, which main's endsWith('.apk') accepted.
  const kind = path.toLowerCase().slice(-4);
  if (kind !== '.apk' && kind !== '.app' && kind !== '.ipa') {
    throw new KaragozError('INVALID_ARGS', `'${path}' is not an .apk, .app or .ipa file`);
  }
  // Missing, a path through a file, no permission: the caller fixes each the same way, so the cause is dropped.
  const info = await stat(path).catch(() => undefined);
  if (!info) throw new KaragozError('INVALID_ARGS', `no file at '${path}'`);
  // An .app is a bundle directory; an .apk and an .ipa are archives (K36).
  if (kind === '.app' && !info.isDirectory()) throw new KaragozError('INVALID_ARGS', `'${path}' is not a directory`);
  if (kind !== '.app' && !info.isFile()) throw new KaragozError('INVALID_ARGS', `'${path}' is not a file`);
  // One more second per started MB, as input.ts adds a gesture's duration (K19 note, K28). A .app directory's own
  // size is a few bytes, so it gets 31 s (K36).
  const timeout = INSTALL_BASE_MS + Math.ceil(info.size / 1_000_000) * 1000;
  const { id, platform } = await resolveTarget(device);
  if (platform === 'ios' && kind === '.apk') {
    throw new KaragozError('INVALID_ARGS', `'${path}' is an Android app; ${id} is an iOS simulator`);
  }
  if (platform === 'android' && kind !== '.apk') {
    throw new KaragozError('INVALID_ARGS', `'${path}' is an iOS app; ${id} is an Android device`);
  }
  return platform === 'ios' ? iosInstall(id, path, timeout) : androidInstall(id, path, timeout);
}

// iOS's bundle id alphabet, of which Android's package names are a subset; Android's own check runs once the target is
// known. The value reaches a device shell or simctl, so garbage stops here (K28, K36).
async function target(device: string | undefined, pkg: string) {
  if (!/^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/.test(pkg)) {
    throw new KaragozError('INVALID_ARGS', `'${pkg}' is not a package name`);
  }
  const resolved = await resolveTarget(device);
  if (resolved.platform === 'android') checkPackage(pkg);
  return resolved;
}

export async function launch(device: string | undefined, pkg: string) {
  const { id, platform } = await target(device, pkg);
  return platform === 'ios' ? iosLaunch(id, pkg) : androidLaunch(id, pkg);
}

export async function terminate(device: string | undefined, pkg: string) {
  const { id, platform } = await target(device, pkg);
  return platform === 'ios' ? iosTerminate(id, pkg) : androidTerminate(id, pkg);
}

export async function uninstall(device: string | undefined, pkg: string) {
  const { id, platform } = await target(device, pkg);
  return platform === 'ios' ? iosUninstall(id, pkg) : androidUninstall(id, pkg);
}
