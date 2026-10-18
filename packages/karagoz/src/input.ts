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
import {
  key as iosKey,
  keyPhone,
  swipe as iosSwipe,
  swipePhone,
  tap as iosTap,
  tapElement,
  tapPhone,
  text as iosText,
  textPhone,
} from './drivers/ios/input.js';

export type { Target };

// Argument checks first, then the target: INVALID_ARGS comes before any device call (K5, K25).
export async function key(device: string | undefined, value: string) {
  const parsed = keyCode(value);
  const resolved = await resolveTarget(device, 'iphone');
  const { id } = resolved;
  if (resolved.platform === 'android') return androidKey(id, parsed);
  return resolved.kind === 'physical' ? keyPhone(id, parsed.name, parsed.code) : iosKey(id, parsed.name, parsed.code);
}

export async function tap(device: string | undefined, target: Target, duration: number | undefined, timeout: number) {
  const resolved = await resolveTarget(device, 'iphone');
  const { id } = resolved;
  if (resolved.platform === 'android') return androidTap(id, target, duration, timeout);
  if (target.kind !== 'point') return tapElement(id, target, duration, timeout, resolved.kind);
  return resolved.kind === 'physical'
    ? tapPhone(id, target.x, target.y, duration)
    : iosTap(id, target.x, target.y, duration);
}

export async function swipe(
  device: string | undefined,
  x1: number,
  y1: number,
  x2: number,
  y2: number,
  duration: number | undefined,
) {
  const resolved = await resolveTarget(device, 'iphone');
  const { id } = resolved;
  if (resolved.platform === 'android') return androidSwipe(id, x1, y1, x2, y2, duration);
  return resolved.kind === 'physical'
    ? swipePhone(id, x1, y1, x2, y2, duration)
    : iosSwipe(id, x1, y1, x2, y2, duration);
}

// Which characters can be typed depends on the platform, so that check runs after the target resolves; nothing is sent
// to the device before it (user decision, K35 3.4 plan).
export async function text(device: string | undefined, value: string) {
  const resolved = await resolveTarget(device, 'iphone');
  const { id } = resolved;
  if (resolved.platform === 'ios') return resolved.kind === 'physical' ? textPhone(id, value) : iosText(id, value);
  typable(value);
  return androidText(id, value);
}
