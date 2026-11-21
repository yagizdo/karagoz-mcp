import { resolveTarget } from './devices.js';
import {
  doubleTap as androidDoubleTap,
  key as androidKey,
  swipe as androidSwipe,
  tap as androidTap,
  text as androidText,
  type Target,
} from './drivers/android/input.js';
import {
  doubleTap as iosDoubleTap,
  doubleTapElement,
  doubleTapElementPhone,
  doubleTapPhone,
  key as iosKey,
  keyPhone,
  swipe as iosSwipe,
  swipePhone,
  tap as iosTap,
  tapElement,
  tapElementPhone,
  tapPhone,
  text as iosText,
  textPhone,
} from './drivers/ios/input.js';
import { KaragozError } from './errors.js';
import { keyCode } from './keys.js';
import { typable } from './text.js';
import { settledTree, type Resolved } from './ui-tree.js';

export type { Target };

// The action already happened, so a failed read after it is reported beside its result, not as an error: an error
// would tell the agent the action failed, and it would tap again on a screen that already moved on (K73).
async function withTree<T extends object>(resolved: Resolved, result: T, tree: boolean) {
  if (!tree) return result;
  try {
    return { ...result, tree: await settledTree(resolved) };
  } catch (err) {
    if (!(err instanceof KaragozError)) throw err;
    return { ...result, treeError: { code: err.code, message: err.message } };
  }
}

// Argument checks first, then the target: INVALID_ARGS comes before any device call (K5, K25).
export async function key(device: string | undefined, value: string, tree = false) {
  const parsed = keyCode(value);
  const resolved = await resolveTarget(device);
  const { id } = resolved;
  const result = await (resolved.platform === 'android'
    ? androidKey(id, parsed)
    : resolved.kind === 'physical'
      ? keyPhone(id, parsed.name, parsed.code)
      : iosKey(id, parsed.name, parsed.code));
  return withTree(resolved, result, tree);
}

export async function tap(
  device: string | undefined,
  target: Target,
  duration: number | undefined,
  timeout: number,
  tree = false,
) {
  const resolved = await resolveTarget(device);
  const { id } = resolved;
  const result = await (resolved.platform === 'android'
    ? androidTap(id, target, duration, timeout)
    : target.kind !== 'point'
      ? resolved.kind === 'physical'
        ? tapElementPhone(id, target, duration, timeout)
        : tapElement(id, target, duration, timeout)
      : resolved.kind === 'physical'
        ? tapPhone(id, target.x, target.y, duration)
        : iosTap(id, target.x, target.y, duration));
  return withTree(resolved, result, tree);
}

export async function doubleTap(device: string | undefined, target: Target, timeout: number, tree = false) {
  const resolved = await resolveTarget(device);
  const { id } = resolved;
  const result = await (resolved.platform === 'android'
    ? androidDoubleTap(id, target, timeout)
    : target.kind !== 'point'
      ? resolved.kind === 'physical'
        ? doubleTapElementPhone(id, target, timeout)
        : doubleTapElement(id, target, timeout)
      : resolved.kind === 'physical'
        ? doubleTapPhone(id, target.x, target.y)
        : iosDoubleTap(id, target.x, target.y));
  return withTree(resolved, result, tree);
}

export async function swipe(
  device: string | undefined,
  x1: number,
  y1: number,
  x2: number,
  y2: number,
  duration: number | undefined,
  tree = false,
) {
  const resolved = await resolveTarget(device);
  const { id } = resolved;
  const result = await (resolved.platform === 'android'
    ? androidSwipe(id, x1, y1, x2, y2, duration)
    : resolved.kind === 'physical'
      ? swipePhone(id, x1, y1, x2, y2, duration)
      : iosSwipe(id, x1, y1, x2, y2, duration));
  return withTree(resolved, result, tree);
}

// The character check names the target, so it runs after the target resolves; nothing is sent to the device before it
// (user decision, K35 3.4 plan).
export async function text(device: string | undefined, value: string, tree = false) {
  const resolved = await resolveTarget(device);
  const { id } = resolved;
  const where =
    resolved.platform === 'android' ? 'Android' : resolved.kind === 'physical' ? 'an iPhone' : 'an iOS simulator';
  typable(value, where);
  const result = await (resolved.platform === 'android'
    ? androidText(id, value)
    : resolved.kind === 'physical'
      ? textPhone(id, value)
      : iosText(id, value));
  return withTree(resolved, result, tree);
}
