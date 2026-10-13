import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { rotation } from './devicectl.js';
import { simctl } from './simctl.js';
import { CACHE_HINT, helper, RUN_TIMEOUT_MS, xcode } from './ui-tree.js';

const run = promisify(execFile);

// Android's swipe default, so both platforms state the same duration (K25, K35).
const SWIPE_MS = 300;

// K25 names to the HID usages dtuhidd takes (K35): hardware buttons on the consumer page (12), the rest on the
// keyboard page (7). A name in neither has no iOS key.
const BUTTONS = new Map([
  ['HOME', 64],
  ['POWER', 48],
  ['VOLUME_UP', 233],
  ['VOLUME_DOWN', 234],
]);
const KEYBOARD = new Map<string, number>([
  ...Array.from('ABCDEFGHIJKLMNOPQRSTUVWXYZ', (name, i): [string, number] => [name, 4 + i]),
  ...Array.from('1234567890', (name, i): [string, number] => [name, 30 + i]),
  ['ENTER', 40],
  ['ESCAPE', 41],
  ['DEL', 42],
  ['TAB', 43],
  ['SPACE', 44],
  ['MINUS', 45],
  ['EQUALS', 46],
  ['LEFT_BRACKET', 47],
  ['RIGHT_BRACKET', 48],
  ['BACKSLASH', 49],
  ['SEMICOLON', 51],
  ['APOSTROPHE', 52],
  ['GRAVE', 53],
  ['COMMA', 54],
  ['PERIOD', 55],
  ['SLASH', 56],
  ['CAPS_LOCK', 57],
  ...Array.from({ length: 12 }, (_, i): [string, number] => [`F${i + 1}`, 58 + i]),
  ['MOVE_HOME', 74],
  ['PAGE_UP', 75],
  ['FORWARD_DEL', 76],
  ['MOVE_END', 77],
  ['PAGE_DOWN', 78],
  ['DPAD_RIGHT', 79],
  ['DPAD_LEFT', 80],
  ['DPAD_DOWN', 81],
  ['DPAD_UP', 82],
  ...Array.from({ length: 12 }, (_, i): [string, number] => [`F${i + 13}`, 104 + i]),
  ['CTRL_LEFT', 224],
  ['SHIFT_LEFT', 225],
  ['ALT_LEFT', 226],
  ['META_LEFT', 227],
  ['CTRL_RIGHT', 228],
  ['SHIFT_RIGHT', 229],
  ['ALT_RIGHT', 230],
  ['META_RIGHT', 231],
]);

// The portrait panel in the tree's pixels, the size dtuhidd's ratios divide (K35).
async function panelSide(udid: string, side: 'WIDTH' | 'HEIGHT'): Promise<number> {
  const text = (await simctl(['getenv', udid, `SIMULATOR_MAINSCREEN_${side}`])).trim();
  const value = Number(text);
  if (!Number.isFinite(value) || value <= 0) {
    throw new KaragozError(
      'SIMCTL_FAILED',
      `cannot read the panel size from 'simctl getenv' (got '${text.slice(0, 100)}')`,
    );
  }
  return value;
}

// x, y are the tree's pixels in the interface orientation; dtuhidd takes 0-1 ratios of the unrotated portrait panel.
// A null rotation (Xcode 26, or devicectl failing) counts as portrait (K35).
async function panel(udid: string, rotated?: number | null) {
  const [turn, width, height] = await Promise.all([
    rotated === undefined ? rotation(udid) : rotated,
    panelSide(udid, 'WIDTH'),
    panelSide(udid, 'HEIGHT'),
  ]);
  return (x: number, y: number) => {
    const [px, py] =
      turn === 90 ? [width - y, x] : turn === 180 ? [width - x, height - y] : turn === 270 ? [y, height - x] : [x, y];
    return [px / width, py / height].map((ratio) => String(Math.round(ratio * 1e6) / 1e6));
  };
}

// One helper run per command; exit codes and stderr per the contract at the top of ax-helper.swift. The compile runs
// first, so HELPER_FAILED for a missing Xcode wins over the simulator's answer.
async function send(command: string, udid: string, args: string[], extraMs = 0): Promise<void> {
  const dev = await xcode();
  const bin = await helper(dev);
  const signal = cancellation.getStore();
  signal?.throwIfAborted();
  const timeout = RUN_TIMEOUT_MS + extraMs;
  try {
    await run(bin, [dev, udid, ...args], { timeout, ...(signal && { signal }) });
  } catch (err) {
    // The SDK sends no response for a cancelled call, so the abort passes through (K31).
    if (signal?.aborted) throw err;
    if (!(err instanceof Error)) throw err;
    const stderr = 'stderr' in err && typeof err.stderr === 'string' ? err.stderr.trim().slice(0, 300) : '';
    const code = 'code' in err ? err.code : undefined;
    if ('killed' in err && err.killed) {
      throw new KaragozError('HELPER_FAILED', `the simulator did not answer within ${timeout / 1000} s`);
    }
    if (code === 2) {
      throw new KaragozError(
        'HELPER_FAILED',
        `${stderr}; this Xcode changed a private interface karagoz uses; update karagoz`,
      );
    }
    // dtuhidd arrived with CoreSimulator 1155.4 (Xcode 27); the Xcode 26 route waits for its own round (K35).
    if (code === 4) throw new KaragozError('NOT_SUPPORTED', `'${command}' on iOS simulators needs Xcode 27 or later`);
    if (code === 5) {
      throw new KaragozError(
        'DEVICE_NOT_READY',
        `the simulator's input service did not answer within 4 s; it may still be starting after boot (${stderr})`,
      );
    }
    if (typeof code === 'number')
      throw new KaragozError('HELPER_FAILED', stderr || `the helper exited with code ${code}`);
    if ('signal' in err && typeof err.signal === 'string') {
      throw new KaragozError('HELPER_FAILED', `the helper crashed (${err.signal})`);
    }
    if (code === 'EACCES' || code === 'ENOENT') {
      throw new KaragozError('HELPER_FAILED', `cannot run ${bin} (${code}); ${CACHE_HINT}`);
    }
    throw new KaragozError('HELPER_FAILED', stderr || err.message.slice(0, 300));
  }
}

// rotated comes from a tree read the caller already made; a plain tap reads it itself.
export async function tap(udid: string, x: number, y: number, duration: number | undefined, rotated?: number | null) {
  const ratio = await panel(udid, rotated);
  await send('tap', udid, ['tap', ...ratio(x, y), String(duration ?? 0)], duration);
  return duration === undefined ? { device: udid, x, y } : { device: udid, x, y, duration };
}

export async function swipe(udid: string, x1: number, y1: number, x2: number, y2: number, duration = SWIPE_MS) {
  const ratio = await panel(udid);
  await send('swipe', udid, ['swipe', ...ratio(x1, y1), ...ratio(x2, y2), String(duration)], duration);
  return { device: udid, x1, y1, x2, y2, duration };
}

// The name check runs before anything compiles: an iOS-less key is wrong for this target and stays wrong (K35).
export async function key(udid: string, name: string, code: number) {
  const button = BUTTONS.get(name);
  const usage = KEYBOARD.get(name);
  if (button === undefined && usage === undefined) {
    const hint = name === 'BACK' ? "; tap the app's back button or swipe from the left edge" : '';
    throw new KaragozError(
      'INVALID_ARGS',
      `'${name}' has no iOS simulator key; iOS takes HOME, POWER, VOLUME_UP, VOLUME_DOWN and keyboard keys (letters, digits, ENTER, DEL, TAB, ESCAPE, DPAD_*, F1-F24)${hint}`,
    );
  }
  await send('key', udid, button === undefined ? ['key', String(usage)] : ['button', '12', String(button)]);
  return { device: udid, key: `KEYCODE_${name}`, code };
}
