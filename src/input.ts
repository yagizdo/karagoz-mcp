import { resolveTarget } from './devices.js';
import {
  key as androidKey,
  keyCode,
  swipe as androidSwipe,
  tap as androidTap,
  text as androidText,
  typable,
  type Target,
} from './drivers/android/input.js';
import { key as iosKey, swipe as iosSwipe, tap as iosTap, tapElement } from './drivers/ios/input.js';
import { KaragozError } from './errors.js';

export type { Target };

// Argument checks first, then the target: INVALID_ARGS and TEXT_UNSUPPORTED come before any device call (K5, K25).
export async function key(device: string | undefined, value: string) {
  const parsed = keyCode(value);
  const { id, platform } = await resolveTarget(device);
  return platform === 'ios' ? iosKey(id, parsed.name, parsed.code) : androidKey(id, parsed);
}

export async function tap(device: string | undefined, target: Target, duration: number | undefined, timeout: number) {
  const { id, platform } = await resolveTarget(device);
  if (platform === 'android') return androidTap(id, target, duration, timeout);
  return target.kind === 'point' ? iosTap(id, target.x, target.y, duration) : tapElement(id, target, duration, timeout);
}

export async function swipe(
  device: string | undefined,
  x1: number,
  y1: number,
  x2: number,
  y2: number,
  duration: number | undefined,
) {
  const { id, platform } = await resolveTarget(device);
  return platform === 'ios' ? iosSwipe(id, x1, y1, x2, y2, duration) : androidSwipe(id, x1, y1, x2, y2, duration);
}

export async function text(device: string | undefined, value: string) {
  typable(value);
  const { id, platform } = await resolveTarget(device);
  if (platform === 'ios') throw new KaragozError('NOT_SUPPORTED', "'text' does not run on iOS simulators yet");
  return androidText(id, value);
}
