import { fileURLToPath } from 'node:url';
import { KaragozError } from '../../errors.js';
import { cancellation } from '../../cancellation.js';
import { adb, TIMEOUT_MS } from './adb.js';
import { readTree, type UiNode } from './ui-tree.js';

// Android's own swipe default, passed so the output states it (K25).
const SWIPE_MS = 300;

// What Virtual.kcm types without a dead key (K25); text with any other character is pasted by the helper.
const TYPABLE = /^[\x20-\x7e\n\tçÇß]*$/;

// The build copies the helper next to the bundle's chunks, all flat in dist/.
const HELPER = fileURLToPath(new URL('text-helper.jar', import.meta.url));
// One fixed name: a file a killed call leaves behind is overwritten and removed by the next paste.
const REMOTE = '/data/local/tmp/karagoz-text.jar';
// ART on Android 8 compiles the jar into oat/<arch>/ next to it (measured on API 26), so those files go too, and the
// folders when nothing else is in them.
const CLEANUP = `rm -f ${REMOTE} /data/local/tmp/oat/*/karagoz-text.*; rmdir /data/local/tmp/oat/* /data/local/tmp/oat 2>/dev/null`;
// As the iOS helper's 30 s; a paste took 0.5-5.4 s on an API 37 emulator, cold start included (measured).
const HELPER_TIMEOUT_MS = 30_000;
// Plus this per piece between newlines and tabs: the helper waits 200 ms after each paste (SETTLE_MS in
// TextHelper.java), and its keys take time on top, so 150 lines no longer run out the fixed 30 s.
const PIECE_MS = 1_000;

// Cold typing measured ~20-30 ms per character, so a chunk stays well inside adb's 10 s timeout (K25).
const CHUNK = 100;

// Invisible direction marks, Unicode's Bidi_Control set. One UI's Settings wraps Bluetooth and Wi-Fi Direct names in
// U+200E (Samsung Settings source), which nobody can type from the screen, so --text ignores them on both sides (K26).
const BIDI = /\p{Bidi_Control}/gu;

// Every input call fails this way when MIUI/HyperOS or vivo deny INJECT_EVENTS to shell (K25).
const BLOCKED =
  'the device does not let adb inject input (SecurityException: INJECT_EVENTS permission); on Xiaomi, Redmi and POCO turn on Developer options > USB debugging (Security settings), on vivo and iQOO turn on USB simulated click; retrying does not help';

// adb's own escape_arg rule (K25): mksh expands nothing inside single quotes.
const quote = (arg: string) => `'${arg.replaceAll("'", "'\\''")}'`;

const blocked = (err: unknown) =>
  err instanceof KaragozError &&
  err.code === 'ADB_FAILED' &&
  err.message.includes('SecurityException') &&
  err.message.includes('INJECT_EVENTS permission');

// shell, not exec-out: exec-out drops the exit status, and input's 255 is the only failure it reports (K25).
async function send(id: string, args: string[], timeout?: number): Promise<void> {
  try {
    await adb(['-s', id, 'shell', 'input', ...args.map(quote)], timeout);
  } catch (err) {
    if (blocked(err)) throw new KaragozError('INPUT_BLOCKED', BLOCKED);
    throw err;
  }
}

export async function key(id: string, { name, code }: { name: string; code: number }) {
  // The code, not the name: the device matches names case-sensitively.
  await send(id, ['keyevent', String(code)]);
  return { device: id, key: `KEYCODE_${name}`, code };
}

type Selector = { kind: 'text'; label: string } | { kind: 'id'; id: string };
export type Target = { kind: 'point'; x: number; y: number } | Selector;

// A long press is a swipe that stays in place: one call, so the UP cannot get lost. On API 36 a lost UP silently eats
// the next gesture (K25).
async function press(id: string, x: number, y: number, duration: number | undefined) {
  if (duration === undefined) {
    await send(id, ['tap', String(x), String(y)]);
    return { device: id, x, y };
  }
  await send(id, ['swipe', ...[x, y, x, y, duration].map(String)], TIMEOUT_MS + duration);
  return { device: id, x, y, duration };
}

// uiautomator reports [0,0,0,0] or inverted bounds at a screen edge (K24): nothing to tap there.
function area(node: UiNode): [number, number, number, number] | undefined {
  const box = node.bounds;
  if (!Array.isArray(box)) return undefined;
  const [l, t, r, b] = box;
  if (typeof l !== 'number' || typeof t !== 'number' || typeof r !== 'number' || typeof b !== 'number')
    return undefined;
  return r > l && b > t ? [l, t, r, b] : undefined;
}

// Whole string, case-sensitive, direction marks aside (K26). Compose puts a label in text and Flutter in contentDesc, so
// --text reads both.
function matches(node: UiNode, selector: Selector): boolean {
  if (selector.kind === 'text') {
    const label = selector.label.replaceAll(BIDI, '');
    return [node.text, node.contentDesc].some(
      (value) => typeof value === 'string' && value.replaceAll(BIDI, '') === label,
    );
  }
  const resourceId = node.resourceId;
  return typeof resourceId === 'string' && (resourceId === selector.id || resourceId.endsWith(`:id/${selector.id}`));
}

// A matching parent and its matching child both count, so the pair is ambiguous (K26).
function collect(node: UiNode, selector: Selector, found: { node: UiNode; box: [number, number, number, number] }[]) {
  const box = area(node);
  if (box && matches(node, selector)) found.push({ node, box });
  const children = node.children;
  if (Array.isArray(children))
    for (const child of children) if (typeof child === 'object') collect(child, selector, found);
  return found;
}

// Only the IME window's own block: the dump lists other windows after it, Settings among them with isVisible=true.
// A hidden keyboard still prints its last touchable region, so the region counts only with isVisible=true (K26).
// ponytail: only the keyboard is checked; bubbles, picture-in-picture and other overlays are not (K26).
async function keyboard(id: string) {
  const out = await adb(['-s', id, 'shell', 'dumpsys', 'window', '-a', 'InputMethod']);
  const block = /Window\{[^}\n]* InputMethod\}:\n([\s\S]*?)(?:\n[ \t]*\n|$)/.exec(out)?.[1] ?? '';
  if (!/^\s*isVisible=true$/m.test(block)) return [];
  const region = /touchable region=SkRegion\((.*)\)$/m.exec(block)?.[1] ?? '';
  return Array.from(region.matchAll(/\((-?\d+),(-?\d+),(-?\d+),(-?\d+)\)/g), ([, l, t, r, b]) => ({
    l: Number(l),
    t: Number(t),
    r: Number(r),
    b: Number(b),
  }));
}

// Only "no match" reads again; a failed read, an ambiguous match or a covered center ends it. --timeout waits for the
// element to appear and never repeats the tap (K26, K11 note).
async function locate(id: string, selector: Selector, timeout: number) {
  const what =
    selector.kind === 'text'
      ? `text or contentDesc '${selector.label}'`
      : `resourceId '${selector.id}' or ending in ':id/${selector.id}'`;
  const start = performance.now();
  for (let reads = 1; ; reads++) {
    // Without it a cancelled wait keeps reading for its whole timeout and blocks every other read on the device (K31).
    cancellation.getStore()?.throwIfAborted();
    const [{ root }, keys] = await Promise.all([readTree(id), keyboard(id)]);
    const found = collect(root, selector, []);
    if (found.length > 1) {
      const shown = found
        .slice(0, 5)
        .map(({ node, box }) => `${typeof node.class === 'string' ? node.class : ''} [${box.join(',')}]`);
      const more = found.length > shown.length ? `, and ${found.length - shown.length} more` : '';
      throw new KaragozError(
        'ELEMENT_AMBIGUOUS',
        `${found.length} nodes match ${what}: ${shown.join(', ')}${more}; tap one by its coordinates`,
      );
    }
    const [match] = found;
    if (match) {
      const [l, t, r, b] = match.box;
      const x = (l + r) / 2;
      const y = (t + b) / 2;
      if (keys.some((rect) => rect.l <= x && x < rect.r && rect.t <= y && y < rect.b)) {
        const name = selector.kind === 'text' ? selector.label : selector.id;
        throw new KaragozError(
          'ELEMENT_COVERED',
          `'${name}' at (${x}, ${y}) is under the on-screen keyboard; hide it with karagoz key BACK, or tap another point`,
        );
      }
      return { node: match.node, x, y };
    }
    const elapsed = performance.now() - start;
    if (elapsed >= timeout) {
      const where = typeof root.package === 'string' ? root.package : 'the focused window';
      throw new KaragozError(
        'ELEMENT_NOT_FOUND',
        `no node with ${what} in ${where} (${reads} read${reads === 1 ? '' : 's'} in ${(elapsed / 1000).toFixed(1)} s)`,
      );
    }
  }
}

export async function tap(id: string, target: Target, duration: number | undefined, timeout: number) {
  if (target.kind === 'point') return press(id, target.x, target.y, duration);
  const { node, x, y } = await locate(id, target, timeout);
  const element = { ...node };
  delete element.children;
  return { ...(await press(id, x, y, duration)), element };
}

export async function swipe(id: string, x1: number, y1: number, x2: number, y2: number, duration = SWIPE_MS) {
  await send(id, ['swipe', ...[x1, y1, x2, y2, duration].map(String)], TIMEOUT_MS + duration);
  return { device: id, x1, y1, x2, y2, duration };
}

// The helper's last stderr line says what happened to the clipboard (TextHelper.java); with none it never got that far.
const CLIP: Record<string, string> = {
  kept: 'the clipboard was not changed',
  restored: 'the previous clip was put back',
};

function helperFailed(stderr: string): KaragozError {
  const lines = stderr.split('\n').map((line) => line.trim());
  const clip = lines.find((line) => line.startsWith('clip: '))?.slice('clip: '.length);
  const error = lines.find((line) => line && !line.startsWith('clip: ')) ?? 'the text was pasted';
  const tail =
    clip === undefined
      ? ''
      : Object.hasOwn(CLIP, clip)
        ? `; ${CLIP[clip]}`
        : `; the previous clip could not be put back (${clip.replace(/^lost: /, '')})`;
  return new KaragozError('HELPER_FAILED', `the text helper failed on the device: ${error}${tail}`);
}

// One VM for save, paste and restore: each app_process start costs 1-2 s (measured). The text goes as base64, so the
// device shell sees no quoting.
async function paste(id: string, value: string) {
  await adb(['-s', id, 'push', HELPER, REMOTE]);
  const line = `CLASSPATH=${REMOTE} app_process / TextHelper ${Buffer.from(value).toString('base64')}`;
  try {
    const timeout = HELPER_TIMEOUT_MS + value.split(/[\n\t]/).length * PIECE_MS;
    await adb(['-s', id, 'shell', `${line}; s=$?; ${CLEANUP}; exit $s`], timeout);
  } catch (err) {
    if (blocked(err)) throw new KaragozError('INPUT_BLOCKED', BLOCKED);
    // Only the helper prints a clip: line; without one adb itself failed (a device gone), which stays ADB_FAILED.
    if (err instanceof KaragozError && err.code === 'ADB_FAILED' && /^clip: /m.test(err.message))
      throw helperFailed(err.message);
    throw err;
  }
  return { device: id, text: value };
}

export async function text(id: string, value: string) {
  if (!TYPABLE.test(value)) return paste(id, value);
  let typed = 0;
  // input turns every %s into a space within one call, so a part ends at each % followed by s.
  for (const part of value.split(/(?<=%)(?=s)/)) {
    for (let at = 0; at < part.length; at += CHUNK) {
      const slice = part.slice(at, at + CHUNK);
      cancellation.getStore()?.throwIfAborted();
      try {
        await send(id, ['text', slice]);
      } catch (err) {
        if (!(err instanceof KaragozError)) throw err;
        throw new KaragozError(
          err.code,
          `${err.message}; ${typed} of ${value.length} characters were typed before this`,
        );
      }
      typed += slice.length;
    }
  }
  return { device: id, text: value };
}
