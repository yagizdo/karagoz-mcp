import { KaragozError } from '../../errors.js';
import { cancellation } from '../../cancellation.js';
import { adb, TIMEOUT_MS } from './adb.js';
import { readTree, type UiNode } from './ui-tree.js';

// KeyEvent.java at android17-release (frameworks/base 94b4c163b7dfe5ce3607f7bb8456f9573f7de57d): the 341 KEYCODE_ names
// without the prefix, index = code, 0-340 with no gap.
// ponytail: one table, android17's. A device older than it does not know the newest codes and injects KEYCODE_UNKNOWN
// for them with exit 0 (this emulator, Android 16 QPR2, ends at 337, F24). Per-API tables if a caller needs them.
const KEYS =
  'UNKNOWN SOFT_LEFT SOFT_RIGHT HOME BACK CALL ENDCALL 0 1 2 3 4 5 6 7 8 9 STAR POUND DPAD_UP DPAD_DOWN DPAD_LEFT DPAD_RIGHT DPAD_CENTER VOLUME_UP VOLUME_DOWN POWER CAMERA CLEAR A B C D E F G H I J K L M N O P Q R S T U V W X Y Z COMMA PERIOD ALT_LEFT ALT_RIGHT SHIFT_LEFT SHIFT_RIGHT TAB SPACE SYM EXPLORER ENVELOPE ENTER DEL GRAVE MINUS EQUALS LEFT_BRACKET RIGHT_BRACKET BACKSLASH SEMICOLON APOSTROPHE SLASH AT NUM HEADSETHOOK FOCUS PLUS MENU NOTIFICATION SEARCH MEDIA_PLAY_PAUSE MEDIA_STOP MEDIA_NEXT MEDIA_PREVIOUS MEDIA_REWIND MEDIA_FAST_FORWARD MUTE PAGE_UP PAGE_DOWN PICTSYMBOLS SWITCH_CHARSET BUTTON_A BUTTON_B BUTTON_C BUTTON_X BUTTON_Y BUTTON_Z BUTTON_L1 BUTTON_R1 BUTTON_L2 BUTTON_R2 BUTTON_THUMBL BUTTON_THUMBR BUTTON_START BUTTON_SELECT BUTTON_MODE ESCAPE FORWARD_DEL CTRL_LEFT CTRL_RIGHT CAPS_LOCK SCROLL_LOCK META_LEFT META_RIGHT FUNCTION SYSRQ BREAK MOVE_HOME MOVE_END INSERT FORWARD MEDIA_PLAY MEDIA_PAUSE MEDIA_CLOSE MEDIA_EJECT MEDIA_RECORD F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 NUM_LOCK NUMPAD_0 NUMPAD_1 NUMPAD_2 NUMPAD_3 NUMPAD_4 NUMPAD_5 NUMPAD_6 NUMPAD_7 NUMPAD_8 NUMPAD_9 NUMPAD_DIVIDE NUMPAD_MULTIPLY NUMPAD_SUBTRACT NUMPAD_ADD NUMPAD_DOT NUMPAD_COMMA NUMPAD_ENTER NUMPAD_EQUALS NUMPAD_LEFT_PAREN NUMPAD_RIGHT_PAREN VOLUME_MUTE INFO CHANNEL_UP CHANNEL_DOWN ZOOM_IN ZOOM_OUT TV WINDOW GUIDE DVR BOOKMARK CAPTIONS SETTINGS TV_POWER TV_INPUT STB_POWER STB_INPUT AVR_POWER AVR_INPUT PROG_RED PROG_GREEN PROG_YELLOW PROG_BLUE APP_SWITCH BUTTON_1 BUTTON_2 BUTTON_3 BUTTON_4 BUTTON_5 BUTTON_6 BUTTON_7 BUTTON_8 BUTTON_9 BUTTON_10 BUTTON_11 BUTTON_12 BUTTON_13 BUTTON_14 BUTTON_15 BUTTON_16 LANGUAGE_SWITCH MANNER_MODE 3D_MODE CONTACTS CALENDAR MUSIC CALCULATOR ZENKAKU_HANKAKU EISU MUHENKAN HENKAN KATAKANA_HIRAGANA YEN RO KANA ASSIST BRIGHTNESS_DOWN BRIGHTNESS_UP MEDIA_AUDIO_TRACK SLEEP WAKEUP PAIRING MEDIA_TOP_MENU 11 12 LAST_CHANNEL TV_DATA_SERVICE VOICE_ASSIST TV_RADIO_SERVICE TV_TELETEXT TV_NUMBER_ENTRY TV_TERRESTRIAL_ANALOG TV_TERRESTRIAL_DIGITAL TV_SATELLITE TV_SATELLITE_BS TV_SATELLITE_CS TV_SATELLITE_SERVICE TV_NETWORK TV_ANTENNA_CABLE TV_INPUT_HDMI_1 TV_INPUT_HDMI_2 TV_INPUT_HDMI_3 TV_INPUT_HDMI_4 TV_INPUT_COMPOSITE_1 TV_INPUT_COMPOSITE_2 TV_INPUT_COMPONENT_1 TV_INPUT_COMPONENT_2 TV_INPUT_VGA_1 TV_AUDIO_DESCRIPTION TV_AUDIO_DESCRIPTION_MIX_UP TV_AUDIO_DESCRIPTION_MIX_DOWN TV_ZOOM_MODE TV_CONTENTS_MENU TV_MEDIA_CONTEXT_MENU TV_TIMER_PROGRAMMING HELP NAVIGATE_PREVIOUS NAVIGATE_NEXT NAVIGATE_IN NAVIGATE_OUT STEM_PRIMARY STEM_1 STEM_2 STEM_3 DPAD_UP_LEFT DPAD_DOWN_LEFT DPAD_UP_RIGHT DPAD_DOWN_RIGHT MEDIA_SKIP_FORWARD MEDIA_SKIP_BACKWARD MEDIA_STEP_FORWARD MEDIA_STEP_BACKWARD SOFT_SLEEP CUT COPY PASTE SYSTEM_NAVIGATION_UP SYSTEM_NAVIGATION_DOWN SYSTEM_NAVIGATION_LEFT SYSTEM_NAVIGATION_RIGHT ALL_APPS REFRESH THUMBS_UP THUMBS_DOWN PROFILE_SWITCH VIDEO_APP_1 VIDEO_APP_2 VIDEO_APP_3 VIDEO_APP_4 VIDEO_APP_5 VIDEO_APP_6 VIDEO_APP_7 VIDEO_APP_8 FEATURED_APP_1 FEATURED_APP_2 FEATURED_APP_3 FEATURED_APP_4 DEMO_APP_1 DEMO_APP_2 DEMO_APP_3 DEMO_APP_4 KEYBOARD_BACKLIGHT_DOWN KEYBOARD_BACKLIGHT_UP KEYBOARD_BACKLIGHT_TOGGLE STYLUS_BUTTON_PRIMARY STYLUS_BUTTON_SECONDARY STYLUS_BUTTON_TERTIARY STYLUS_BUTTON_TAIL RECENT_APPS MACRO_1 MACRO_2 MACRO_3 MACRO_4 EMOJI_PICKER SCREENSHOT DICTATE NEW CLOSE DO_NOT_DISTURB PRINT LOCK FULLSCREEN F13 F14 F15 F16 F17 F18 F19 F20 F21 F22 F23 F24 ACCESSIBILITY CONTEXTUAL_SEARCH CONTEXTUAL_INSERT'.split(
    ' ',
  );

// Android's own swipe default, passed so the output states it (K25).
const SWIPE_MS = 300;

// What Virtual.kcm types without a dead key (K25); any other character fails the whole call.
const TYPABLE = /^[\x20-\x7e\n\tçÇß]$/;

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

// shell, not exec-out: exec-out drops the exit status, and input's 255 is the only failure it reports (K25).
async function send(id: string, args: string[], timeout?: number): Promise<void> {
  try {
    await adb(['-s', id, 'shell', 'input', ...args.map(quote)], timeout);
  } catch (err) {
    if (
      err instanceof KaragozError &&
      err.code === 'ADB_FAILED' &&
      err.message.includes('SecurityException') &&
      err.message.includes('INJECT_EVENTS permission')
    )
      throw new KaragozError('INPUT_BLOCKED', BLOCKED);
    throw err;
  }
}

// Digits are always a code, as in Android's keyCodeFromString: 7 is KEYCODE_0, the 7 key is KEYCODE_7. 0 is refused:
// it is KEYCODE_UNKNOWN, which input sends for any name it does not know.
export function keyCode(value: string): { name: string; code: number } {
  const code = /^\d+$/.test(value) ? Number(value) : KEYS.indexOf(value.toUpperCase().replace(/^KEYCODE_/, ''));
  const name = code >= 1 ? KEYS[code] : undefined;
  if (name === undefined) {
    throw new KaragozError(
      'INVALID_ARGS',
      `unknown key '${value}'; use a KeyEvent name such as HOME, BACK or ENTER, or a code from 1 to ${KEYS.length - 1}`,
    );
  }
  return { name, code };
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

export function typable(value: string): void {
  // for…of walks code points: an emoji is one U+ value, not two surrogates.
  const unsupported = new Set<string>();
  for (const char of value) if (!TYPABLE.test(char)) unsupported.add(char);
  if (unsupported.size) {
    const named = Array.from(
      unsupported,
      (char) => `'${char}' (U+${(char.codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, '0')})`,
    );
    throw new KaragozError(
      'TEXT_UNSUPPORTED',
      `cannot type ${named.join(', ')}: Android's input text types only printable ASCII, newline, tab, ç, Ç and ß; nothing was typed`,
    );
  }
}

export async function text(id: string, value: string) {
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
