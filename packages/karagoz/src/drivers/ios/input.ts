import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { runTool } from '../../tool.js';
import { displayOf, rotation } from './devicectl.js';
import { input } from './runner.js';
import { panelScale } from './screenshot.js';
import { simctl } from './simctl.js';
import { helper, readPhoneTree, readTree, RUN_TIMEOUT_MS, type IosNode } from './ui-tree.js';
import { CACHE_HINT, xcode } from './xcode.js';

// Android's swipe default, so both platforms state the same duration (K25, K35).
const SWIPE_MS = 300;

// Characters per second for typeText: 300 characters came out exact 3 of 3 times at 60 (6.0 s a call) and at 120
// (3.5 s) (K35).
const TYPE_SPEED = 120;

// The XCUI session turns app accessibility off when it ends, whatever it was, and apps opened after that give an empty
// tree until the simulator restarts. text writes back a 1 it read before (user decision, K35 3.4 build).
const APP_AX = ['com.apple.Accessibility', 'ApplicationAccessibilityEnabled'];

// Invisible direction marks, Unicode's Bidi_Control set, ignored on both sides as on Android (K26). A copy of the
// Android driver's, so this driver imports nothing from it.
const BIDI = /\p{Bidi_Control}/gu;

type Selector = { kind: 'text'; label: string } | { kind: 'id'; id: string };

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

// An iPhone's runner presses the hardware buttons, and types the keys that make a character through its text path, with
// XCTest's own characters for delete and escape (K42).
const PHONE_BUTTONS = new Map([
  ['HOME', 'home'],
  ['POWER', 'lock'],
  ['VOLUME_UP', 'volumeUp'],
  ['VOLUME_DOWN', 'volumeDown'],
]);
// ponytail: keys that type no character (arrows, F-keys, page and line keys, forward delete, modifiers) have no iPhone
// route: XCTest's typeKey goes through the hardware-keyboard path and was never shown to work on a phone (K42).
const PHONE_CHARACTERS = new Map<string, string>([
  ...Array.from('ABCDEFGHIJKLMNOPQRSTUVWXYZ', (name): [string, string] => [name, name.toLowerCase()]),
  ...Array.from('0123456789', (name): [string, string] => [name, name]),
  ['SPACE', ' '],
  ['ENTER', '\n'],
  ['TAB', '\t'],
  ['DEL', '\u007f'],
  ['ESCAPE', '\u001b'],
  ['MINUS', '-'],
  ['EQUALS', '='],
  ['LEFT_BRACKET', '['],
  ['RIGHT_BRACKET', ']'],
  ['BACKSLASH', '\\'],
  ['SEMICOLON', ';'],
  ['APOSTROPHE', "'"],
  ['GRAVE', '`'],
  ['COMMA', ','],
  ['PERIOD', '.'],
  ['SLASH', '/'],
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

// K35's table: x, y in the interface orientation to the unrotated portrait panel width x height, all in one unit. A
// null rotation (Xcode 26, or devicectl failing) counts as portrait.
function portrait(turn: number | null, width: number, height: number, x: number, y: number): [number, number] {
  return turn === 90
    ? [width - y, x]
    : turn === 180
      ? [width - x, height - y]
      : turn === 270
        ? [y, height - x]
        : [x, y];
}

// x, y are the tree's pixels in the interface orientation; dtuhidd takes 0-1 ratios of the unrotated portrait panel.
async function panel(udid: string, rotated?: number | null) {
  const [turn, width, height] = await Promise.all([
    rotated === undefined ? rotation(udid) : rotated,
    panelSide(udid, 'WIDTH'),
    panelSide(udid, 'HEIGHT'),
  ]);
  return (x: number, y: number) => {
    const [px, py] = portrait(turn, width, height, x, y);
    return [px / width, py / height].map((ratio) => String(Math.round(ratio * 1e6) / 1e6));
  };
}

type Display = Awaited<ReturnType<typeof displayOf>>;

// UIInterfaceOrientation's raw values for a rotation: K34's rotation turns the way Android's does, so 90 is UIKit's
// landscape right (K42).
const ORIENTATION = new Map([
  [0, 1],
  [90, 4],
  [180, 2],
  [270, 3],
]);

// An iPhone's runner takes the portrait panel's points and the interface orientation: the tree's pixels divided by the
// scale the tree used (the mini rule), turned by K35's table over the panel in points (K42).
function points({ scale, rotation: turn, panel: native }: Display) {
  const s = native ? panelScale(native.width, native.height, scale) : scale;
  if (!native && turn !== null && turn !== 0) {
    throw new KaragozError('CAPTURE_FAILED', "cannot read the panel size from 'devicectl device info displays'");
  }
  const [width, height] = [(native?.width ?? 0) / s, (native?.height ?? 0) / s];
  const round = (value: number) => Math.round(value * 1000) / 1000;
  return {
    orientation: ORIENTATION.get(turn ?? 0) ?? 1,
    at: (x: number, y: number) => {
      const [px, py] = portrait(turn, width, height, x / s, y / s);
      return { x: round(px), y: round(py) };
    },
  };
}

// display comes from a tree read the caller already made; a plain tap reads it itself.
export async function tapPhone(udid: string, x: number, y: number, duration: number | undefined, display?: Display) {
  const { at, orientation } = points(display ?? (await displayOf(udid)));
  await input(udid, '/tap', { ...at(x, y), ...(duration !== undefined && { duration }), orientation }, duration ?? 0);
  return duration === undefined ? { device: udid, x, y } : { device: udid, x, y, duration };
}

export async function swipePhone(udid: string, x1: number, y1: number, x2: number, y2: number, duration = SWIPE_MS) {
  const { at, orientation } = points(await displayOf(udid));
  const [from, to] = [at(x1, y1), at(x2, y2)];
  await input(udid, '/swipe', { x1: from.x, y1: from.y, x2: to.x, y2: to.y, duration, orientation }, duration);
  return { device: udid, x1, y1, x2, y2, duration };
}

// One helper run per command; exit codes and stderr per the contract at the top of ax-helper.swift. The compile runs
// first, so HELPER_FAILED for a missing Xcode wins over the simulator's answer.
async function send(command: string, udid: string, args: string[], extraMs = 0): Promise<void> {
  const dev = await xcode();
  const bin = await helper(dev);
  const timeout = RUN_TIMEOUT_MS + extraMs;
  const result = await runTool(bin, [dev, udid, ...args], { timeout });
  if (result.ok) return;
  const { failure } = result;
  const { code } = failure;
  const stderr = failure.stderr.slice(0, 300);
  if (failure.kind === 'timeout') {
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
  if (code === 6)
    throw new KaragozError('AUTOMATION_BUSY', stderr || 'another test holds automation on this simulator');
  if (code === 5) {
    throw new KaragozError(
      'DEVICE_NOT_READY',
      `the simulator's input service did not answer within 4 s; it may still be starting after boot (${stderr})`,
    );
  }
  if (typeof code === 'number')
    throw new KaragozError('HELPER_FAILED', stderr || `the helper exited with code ${code}`);
  if (failure.signal) throw new KaragozError('HELPER_FAILED', `the helper crashed (${failure.signal})`);
  if (code === 'EACCES' || code === 'ENOENT') {
    throw new KaragozError('HELPER_FAILED', `cannot run ${bin} (${code}); ${CACHE_HINT}`);
  }
  throw new KaragozError('HELPER_FAILED', stderr || failure.message.slice(0, 300));
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

// --text is the whole label or value, case-sensitive; --id the whole identifier, iOS has no :id/ prefix (K34, K35).
function matches(node: IosNode, selector: Selector): boolean {
  if (selector.kind === 'id') return node.identifier === selector.id;
  const label = selector.label.replaceAll(BIDI, '');
  return [node.label, node.value].some((value) => value !== undefined && value.replaceAll(BIDI, '') === label);
}

// A node with no area has nothing to tap; a matching parent and its matching child both count (K26).
function collect(node: IosNode, selector: Selector, found: IosNode[]): IosNode[] {
  const [l = 0, t = 0, r = 0, b = 0] = node.bounds;
  if (r > l && b > t && matches(node, selector)) found.push(node);
  for (const child of node.children ?? []) collect(child, selector, found);
  return found;
}

const inside = (node: IosNode, target: IosNode): boolean =>
  node === target || (node.children ?? []).some((child) => inside(child, target));

// The software keyboard is in an iPhone's tree (K41): a center it covers would land on a key, unless the target is one
// of its own keys (K26's rule, K42).
function underKeyboard(node: IosNode, target: IosNode, x: number, y: number): boolean {
  if (node.role === 'Keyboard') {
    const [l = 0, t = 0, r = 0, b = 0] = node.bounds;
    return x >= l && x < r && y >= t && y < b && !inside(node, target);
  }
  return (node.children ?? []).some((child) => underKeyboard(child, target, x, y));
}

// Only "no match" reads again; a failed read or an ambiguous match ends it. --timeout waits for the element to appear
// and never repeats the tap (K26, K11 note).
// ponytail: the keyboard-cover check runs on an iPhone only: this simulator never showed a software keyboard (its
// hardware keyboard state), so where its keys sit was never measured (K35).
export async function tapElement(
  udid: string,
  selector: Selector,
  duration: number | undefined,
  timeout: number,
  kind: 'simulator' | 'physical',
) {
  const what = selector.kind === 'text' ? `label or value '${selector.label}'` : `identifier '${selector.id}'`;
  const start = performance.now();
  for (let reads = 1; ; reads++) {
    // Without it a cancelled wait keeps reading for its whole timeout (K31).
    cancellation.getStore()?.throwIfAborted();
    const read = kind === 'physical' ? await readPhoneTree(udid) : { ...(await readTree(udid)), display: undefined };
    const { rotation: rotated, root } = read;
    const found = collect(root, selector, []);
    if (found.length > 1) {
      const shown = found.slice(0, 5).map((node) => `${node.role} [${node.bounds.join(',')}]`);
      const more = found.length > shown.length ? `, and ${found.length - shown.length} more` : '';
      throw new KaragozError(
        'ELEMENT_AMBIGUOUS',
        `${found.length} nodes match ${what}: ${shown.join(', ')}${more}; tap one by its coordinates`,
      );
    }
    const [match] = found;
    if (match) {
      const [l = 0, t = 0, r = 0, b = 0] = match.bounds;
      const [x, y] = [(l + r) / 2, (t + b) / 2];
      if (read.display && underKeyboard(root, match, x, y)) {
        throw new KaragozError(
          'ELEMENT_COVERED',
          `the software keyboard covers the center of the node with ${what} at (${x}, ${y}); hide the keyboard first, then tap again`,
        );
      }
      const element = { ...match };
      delete element.children;
      const tapped = read.display
        ? await tapPhone(udid, x, y, duration, read.display)
        : await tap(udid, x, y, duration, rotated);
      return { ...tapped, element };
    }
    const elapsed = performance.now() - start;
    if (elapsed >= timeout) {
      throw new KaragozError(
        'ELEMENT_NOT_FOUND',
        `no node with ${what} in the frontmost app (${reads} read${reads === 1 ? '' : 's'} in ${(elapsed / 1000).toFixed(1)} s)`,
      );
    }
  }
}

async function appAccessibility(udid: string): Promise<boolean> {
  try {
    return (await simctl(['spawn', udid, 'defaults', 'read', ...APP_AX])).trim() === '1';
  } catch (err) {
    // A missing key fails the read and means off: there is nothing to write back.
    if (!(err instanceof KaragozError)) throw err;
    return false;
  }
}

// Outside the call's cancellation: a cancelled text must still leave app accessibility as it found it (K31).
const restore = (udid: string) =>
  cancellation.exit(() => simctl(['spawn', udid, 'defaults', 'write', ...APP_AX, '-bool', 'true']));

// Each simulator's last text. testmanagerd turns app accessibility off when a session ends and the server runs calls
// in parallel, so a text that read the setting during another's write-back would leave it off: texts of one simulator
// wait in arrival order (K35). Another process typing at the same time still races.
const turns = new Map<string, Promise<void>>();

// Any Unicode types on iOS but control characters other than newline and tab (K35); where names the target.
function typable(value: string, where: string) {
  const control = new Set(Array.from(value).filter((char) => /\p{Cc}/u.test(char) && char !== '\n' && char !== '\t'));
  if (control.size) {
    const named = Array.from(
      control,
      (char) => `'U+${(char.codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, '0')}'`,
    );
    throw new KaragozError(
      'TEXT_UNSUPPORTED',
      `cannot type ${named.join(', ')} on ${where}: control characters other than newline and tab; nothing was typed`,
    );
  }
}

// Typed into whatever has focus; with none, nothing is typed and the call still succeeds, as on Android (K35).
export async function text(udid: string, value: string) {
  typable(value, 'an iOS simulator');
  const signal = cancellation.getStore();
  const turn = (turns.get(udid) ?? Promise.resolve()).then(() => {
    signal?.throwIfAborted();
    return typeText(udid, value);
  });
  const tail = turn.then(
    () => undefined,
    () => undefined,
  );
  turns.set(udid, tail);
  void tail.then(() => {
    if (turns.get(udid) === tail) turns.delete(udid);
  });
  return turn;
}

async function typeText(udid: string, value: string) {
  const wasOn = await appAccessibility(udid);
  const typing = Math.ceil(Array.from(value).length / TYPE_SPEED) * 1000;
  try {
    await send('text', udid, ['type', String(TYPE_SPEED), value], typing);
  } catch (err) {
    // The typing error says what went wrong; a failed write-back on top of it would only hide it.
    if (wasOn) await restore(udid).catch(() => undefined);
    throw err;
  }
  if (wasOn) await restore(udid);
  return { device: udid, text: value };
}

// The runner types into whatever has focus; with none, nothing is typed and the call still succeeds (K35, K42).
// ponytail: no length check here; the runner refuses a request over 1 MiB, and the error does not say that was why.
// Check the length here when a caller sends that much.
export async function textPhone(udid: string, value: string) {
  typable(value, 'an iPhone');
  const typing = Math.ceil((Array.from(value).length / TYPE_SPEED) * 1000);
  await input(udid, '/text', { text: value, speed: TYPE_SPEED }, typing);
  return { device: udid, text: value };
}

// The name check runs before the runner starts: a key an iPhone lacks is wrong for this target and stays wrong (K42).
export async function keyPhone(udid: string, name: string, code: number) {
  const button = PHONE_BUTTONS.get(name);
  const character = PHONE_CHARACTERS.get(name);
  if (button === undefined && character === undefined) {
    const hint = name === 'BACK' ? "; tap the app's back button or swipe from the left edge" : '';
    throw new KaragozError(
      'INVALID_ARGS',
      `'${name}' has no iPhone key; an iPhone takes HOME, POWER, VOLUME_UP, VOLUME_DOWN and keys that type a character (letters, digits, SPACE, ENTER, TAB, DEL, ESCAPE, punctuation)${hint}`,
    );
  }
  await (button === undefined
    ? input(udid, '/text', { text: character, speed: TYPE_SPEED }, 0)
    : input(udid, '/button', { button }, 0));
  return { device: udid, key: `KEYCODE_${name}`, code };
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
