import { KaragozError } from '../../errors.js';
import { cancellation } from '../../cancellation.js';
import { prune } from '../../tree.js';
import { ENTITIES } from '../../xml.js';
import { adb } from './adb.js';

// uiautomator's own idle failure arrives after 11.3-12.2 s (measured), and a client killed at 10 s leaves the device
// process holding the one UiAutomation slot for ~2 s more (K19 note).
const DUMP_TIMEOUT_MS = 20_000;

const IDLE = 'ERROR: could not get idle state.';
const NULL_ROOT = 'ERROR: null root node returned by UiTestAutomationBridge.';
const END = '</hierarchy>';

// Output order is the K24 field order, since JSON.stringify keeps insertion order. Fields are the dump's attribute
// names in camelCase; index, drawing-order and NAF are dropped.
const TEXTS = ['text', 'content-desc', 'resource-id', 'hint'];
const FLAGS = [
  'checkable',
  'checked',
  'clickable',
  'long-clickable',
  'focusable',
  'focused',
  'scrollable',
  'selected',
  'password',
];

// KXmlSerializer's grammar only (K13 note): elements, attributes in " or ' quotes, self-closing tags and whitespace
// between tags. Anything else fails the match and throws.
const TOKEN = /\s+|<(\/?)([\w-]+)((?:\s+[\w-]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>/y;
const ATTR = /([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;

type Element = { name: string; attrs: Map<string, string>; children: Element[] };
export type UiNode = { [field: string]: string | boolean | number[] | UiNode[] };

const camel = (name: string) => name.replace(/-(\w)/g, (_: string, letter: string) => letter.toUpperCase());

// An emoji arrives as &#128512;. The trailing `|&` catches a bare & that starts no entity.
function decode(value: string): string {
  return value.replace(
    /&(?:#x([0-9a-fA-F]+)|#(\d+)|(\w+));|&/g,
    (whole: string, hex: string | undefined, dec: string | undefined, name: string | undefined) => {
      if (hex !== undefined) return String.fromCodePoint(parseInt(hex, 16));
      if (dec !== undefined) return String.fromCodePoint(Number(dec));
      const named = name === undefined ? undefined : ENTITIES.get(name);
      if (named === undefined) throw new Error(`unknown entity '${whole}'`);
      return named;
    },
  );
}

function attributes(text: string): Map<string, string> {
  const attrs = new Map<string, string>();
  for (const match of text.matchAll(ATTR)) attrs.set(match[1] ?? '', decode(match[2] ?? match[3] ?? ''));
  return attrs;
}

function parse(xml: string): Element {
  const open: Element[] = [];
  let root: Element | undefined;
  TOKEN.lastIndex = 0;
  while (TOKEN.lastIndex < xml.length) {
    const at = TOKEN.lastIndex;
    const match = TOKEN.exec(xml);
    if (!match) throw new Error(`unexpected content at offset ${at}`);
    const [, close, name, attrs, selfClose] = match;
    if (name === undefined) continue;
    const parent = open.at(-1);
    if (close) {
      if (attrs || selfClose || parent?.name !== name) throw new Error(`unexpected </${name}> at offset ${at}`);
      open.pop();
      continue;
    }
    if (!parent && root) throw new Error(`content after the root element at offset ${at}`);
    const element: Element = { name, attrs: attributes(attrs ?? ''), children: [] };
    if (parent) parent.children.push(element);
    else root = element;
    if (!selfClose) open.push(element);
  }
  if (!root || open.length) throw new Error(`<${open.at(-1)?.name ?? 'hierarchy'}> is not closed`);
  return root;
}

// package appears on the root and wherever it differs from the parent's.
function toNode(element: Element, parentPackage: string): UiNode {
  if (element.name !== 'node') throw new Error(`unexpected <${element.name}>`);
  const attr = (name: string) => element.attrs.get(name) ?? '';
  const cls = element.attrs.get('class');
  const box = /^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$/.exec(attr('bounds'));
  if (cls === undefined || !box) throw new Error('a <node> without class or bounds');
  const node: UiNode = { class: cls };
  const pkg = attr('package');
  if (pkg && pkg !== parentPackage) node.package = pkg;
  for (const name of TEXTS) if (attr(name)) node[camel(name)] = attr(name);
  for (const name of FLAGS) if (attr(name) === 'true') node[camel(name)] = true;
  if (attr('enabled') === 'false') node.enabled = false;
  node.bounds = box.slice(1).map(Number);
  const children = element.children.map((child) => toNode(child, pkg));
  if (children.length) node.children = children;
  return node;
}

const emptyWebView = (element: Element): boolean =>
  (element.attrs.get('class') === 'android.webkit.WebView' && !element.children.length) ||
  element.children.some(emptyWebView);

function tree(xml: string) {
  const top = parse(xml);
  const rotation = top.attrs.get('rotation') ?? '';
  const [root, ...rest] = top.children;
  if (top.name !== 'hierarchy' || !/^[0-3]$/.test(rotation) || !root || rest.length) {
    throw new Error('expected <hierarchy rotation="0-3"> around exactly one <node>');
  }
  return { rotation: Number(rotation) * 90, root: toNode(root, ''), emptyWebView: emptyWebView(root) };
}

// exec-out exits 0 on every uiautomator failure, so the text is the only signal (K24).
async function failure(id: string, out: string): Promise<KaragozError> {
  if (out.includes(IDLE)) {
    return new KaragozError(
      'CAPTURE_FAILED',
      `the screen did not go idle within uiautomator's 10 s wait (an animation or live content kept changing it); uiautomator: ${IDLE}`,
    );
  }
  if (out.includes(NULL_ROOT)) {
    return new KaragozError(
      'CAPTURE_FAILED',
      `no focused window to read (is the screen off, is an app still starting, or is the app in a work profile or Secure Folder, which adb cannot read?); uiautomator: ${NULL_ROOT}`,
    );
  }
  try {
    if ((await adb(['-s', id, 'shell', 'dumpsys', 'accessibility'])).includes('Ui Automation[')) {
      return new KaragozError(
        'AUTOMATION_BUSY',
        'another UiAutomation client holds the device (Appium, Maestro, uiautomator events, or a second karagoz call); only one can be connected at a time',
      );
    }
  } catch {
    // The slot check only refines the failure. When it cannot run, the dump's own text below still reports it.
  }
  const text = out.trim();
  if (text === 'Killed') {
    return new KaragozError(
      'CAPTURE_FAILED',
      `uiautomator was killed while reading this screen; the cause is in adb -s ${id} logcat -b crash`,
    );
  }
  return new KaragozError('CAPTURE_FAILED', text.slice(0, 300) || 'uiautomator returned no data');
}

// The tree is cut from the first <hierarchy to the last </hierarchy>: some vendors print a stack trace before the XML,
// and uiautomator prints "UI hierchary dumped to: /dev/tty" right after it (K24).
async function read(id: string) {
  const out = await adb(['-s', id, 'exec-out', 'uiautomator', 'dump', '/dev/tty'], DUMP_TIMEOUT_MS);
  const start = out.indexOf('<hierarchy');
  const end = out.lastIndexOf(END);
  if (start === -1 || end < start) throw await failure(id, out);
  try {
    return tree(out.slice(start, end + END.length));
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    throw new KaragozError('CAPTURE_FAILED', `cannot parse uiautomator output: ${err.message}`);
  }
}

// Each serial's last read. One UiAutomation client per device (K24) and the server runs calls in parallel, so reads of
// one serial wait in arrival order; another process still gets AUTOMATION_BUSY. One emulator attached twice
// (adb connect) has two serials and two queues (K31, K21).
const turns = new Map<string, Promise<void>>();

function readInTurn(id: string) {
  const signal = cancellation.getStore();
  const turn = (turns.get(id) ?? Promise.resolve()).then(() => {
    signal?.throwIfAborted();
    return read(id);
  });
  const tail = turn.then(
    () => undefined,
    () => undefined,
  );
  turns.set(id, tail);
  void tail.then(() => {
    if (turns.get(id) === tail) turns.delete(id);
  });
  return turn;
}

// One tree of a resolved serial; tap reads it too (K26).
export async function readTree(id: string): Promise<{ rotation: number; root: UiNode }> {
  let result = await readInTurn(id);
  // Chromium builds a WebView's tree only after the first request, so a fresh WebView reads empty once (5 of 5
  // measured). One more read, never more (K24).
  if (result.emptyWebView) {
    try {
      result = await readInTurn(id);
    } catch (err) {
      if (!(err instanceof KaragozError)) throw err;
      // The first read was valid; the extra one may only improve it, never turn it into an error.
    }
  }
  return { rotation: result.rotation, root: result.root };
}

// What keeps a node in the compact tree besides text, contentDesc or hint (K54).
const ACTIONS = ['clickable', 'longClickable', 'scrollable', 'checkable', 'password'];
const EDITABLE = /(EditText|AutoCompleteTextView)$/;
const ID = ':id/';

const nodesOf = (node: UiNode): UiNode[] =>
  Array.isArray(node.children) ? node.children.filter((child): child is UiNode => typeof child === 'object') : [];
const boundsOf = (node: UiNode): number[] =>
  Array.isArray(node.bounds) ? node.bounds.filter((value): value is number => typeof value === 'number') : [];

function shortened(field: string, value: string): string {
  if (field === 'class') return value.slice(value.lastIndexOf('.') + 1);
  if (field === 'resourceId' && value.includes(ID)) return value.slice(value.indexOf(ID) + ID.length);
  return value;
}

// The compact tree (K54). package is compared against the nearest kept ancestor, so each node's own package, given or
// inherited, is known before the pass drops its parents.
export function compact(root: UiNode): UiNode {
  const owner = new Map<UiNode, string>();
  const own = (node: UiNode, inherited: string) => {
    const pkg = typeof node.package === 'string' ? node.package : inherited;
    owner.set(node, pkg);
    for (const child of nodesOf(node)) own(child, pkg);
  };
  own(root, '');
  return prune(root, {
    bounds: boundsOf,
    children: nodesOf,
    keep: (node) =>
      Boolean(node.text || node.contentDesc || node.hint) ||
      ACTIONS.some((flag) => node[flag] === true) ||
      (typeof node.class === 'string' && EDITABLE.test(node.class)),
    build: (node, children, kept) => {
      const out: UiNode = {};
      for (const [field, value] of Object.entries(node)) {
        if (field === 'package' || field === 'children' || (field === 'contentDesc' && value === node.text)) continue;
        out[field] = typeof value === 'string' ? shortened(field, value) : value;
        const pkg = owner.get(node) ?? '';
        if (field === 'class' && pkg && pkg !== (kept ? owner.get(kept) : '')) out.package = pkg;
      }
      if (children.length) out.children = children;
      return out;
    },
  });
}
