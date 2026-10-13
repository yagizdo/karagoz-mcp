import { androidTarget } from './devices.js';
import {
  key as androidKey,
  keyCode,
  swipe as androidSwipe,
  tap as androidTap,
  text as androidText,
  typable,
  type Target,
} from './drivers/android/input.js';

export type { Target };

// Argument checks first, then the target: INVALID_ARGS and TEXT_UNSUPPORTED come before any device call (K5, K25).
export async function key(device: string | undefined, value: string) {
  const parsed = keyCode(value);
  return androidKey(await androidTarget(device, 'key'), parsed);
}

export async function tap(device: string | undefined, target: Target, duration: number | undefined, timeout: number) {
  return androidTap(await androidTarget(device, 'tap'), target, duration, timeout);
}

export async function swipe(
  device: string | undefined,
  x1: number,
  y1: number,
  x2: number,
  y2: number,
  duration: number | undefined,
) {
  return androidSwipe(await androidTarget(device, 'swipe'), x1, y1, x2, y2, duration);
}

export async function text(device: string | undefined, value: string) {
  typable(value);
  return androidText(await androidTarget(device, 'text'), value);
}
