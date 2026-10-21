import { createHash, randomUUID } from 'node:crypto';
import { access, constants, readFile, rename, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { runTool } from '../../tool.js';
import { displayOf, rotation } from './devicectl.js';
import { isRecord } from './record.js';
import { tree } from './runner.js';
import { panelScale } from './screenshot.js';
import { simctl } from './simctl.js';
import { buildVersion, CACHE_HINT, CACHE_ROOT, ownedDir, owns, xcode } from './xcode.js';

// 2.8 s measured warm; a cold module cache on a slow Mac can take far longer (K34).
const COMPILE_TIMEOUT_MS = 120_000;
// simctl's timeout: the first call after login starts CoreSimulatorService (K32). A read takes ~0.1 s.
export const RUN_TIMEOUT_MS = 30_000;
// Node's 1 MiB default would cut a long list's tree.
const MAX_BUFFER = 32 * 1024 * 1024;
// Pinned so a toolchain that changes its default language mode cannot break the build.
const FLAGS = ['-O', '-suppress-warnings', '-swift-version', '5'];
// The build copies the source next to the bundle's chunks, all flat in dist/.
const SOURCE = fileURLToPath(new URL('ax-helper.swift', import.meta.url));

export type IosNode = {
  role: string;
  label?: string;
  identifier?: string;
  value?: string;
  focused?: true;
  selected?: true;
  enabled?: false;
  bounds: number[];
  children?: IosNode[];
};

let source: Promise<string> | undefined;

export function swiftc(dev: string): { bin: string; missing: string } {
  const bin = join(dev, 'Toolchains', 'XcodeDefault.xctoolchain', 'usr', 'bin', 'swiftc');
  return {
    bin,
    missing: `swiftc not found at ${bin}; install or select an Xcode (xcode-select -s <Xcode.app> or DEVELOPER_DIR), the Command Line Tools are not enough`,
  };
}

// Where the helper for this source, Xcode and architecture lives. The key is computed on every call, so an Xcode
// update or a new karagoz compiles again within the same MCP server.
export async function helperPath(dev: string): Promise<{ root: string; dir: string; bin: string }> {
  source ??= readFile(SOURCE, 'utf8');
  const text = await source.catch(() => {
    throw new KaragozError('HELPER_FAILED', `cannot read ${SOURCE}; reinstall karagoz`);
  });
  // A missing version.plist leaves the build out of the key; the developer dir is still in it.
  const build = await buildVersion(dev);
  const key = createHash('sha256')
    .update([text, dev, build, process.arch, FLAGS.join(' ')].join('\0'))
    .digest('hex')
    .slice(0, 16);
  const dir = join(CACHE_ROOT, key);
  return { root: CACHE_ROOT, dir, bin: join(dir, 'ax') };
}

// The helper binary, compiled on first use (K34).
export async function helper(dev: string): Promise<string> {
  const { root, dir, bin } = await helperPath(dev);
  await ownedDir(root);
  await ownedDir(dir);
  if (await owns(bin, 'file')) return bin;

  const compiler = swiftc(dev);
  try {
    await access(compiler.bin, constants.X_OK);
  } catch {
    // Not there or not runnable: either way this developer dir cannot compile the helper.
    throw new KaragozError('HELPER_FAILED', compiler.missing);
  }
  const sdk = join(dev, 'Platforms', 'MacOSX.platform', 'Developer', 'SDKs', 'MacOSX.sdk');
  // A unique name and a rename: two first calls never run a half-written binary, and the slower one just replaces it.
  const tmp = join(dir, `ax.${process.pid}.${randomUUID()}.tmp`);
  try {
    const result = await runTool(compiler.bin, [...FLAGS, '-sdk', sdk, SOURCE, '-o', tmp], {
      timeout: COMPILE_TIMEOUT_MS,
    });
    if (!result.ok) {
      const { failure } = result;
      if (failure.kind === 'timeout') {
        throw new KaragozError('HELPER_FAILED', `swiftc did not finish within ${COMPILE_TIMEOUT_MS / 1000} s`);
      }
      throw new KaragozError('HELPER_FAILED', (failure.stderr || failure.message).slice(0, 300));
    }
    await rename(tmp, bin).catch((err: unknown) => {
      // The SDK sends no response for a cancelled call, so the abort passes through (K31).
      if (cancellation.getStore()?.aborted || !(err instanceof Error)) throw err;
      throw new KaragozError('HELPER_FAILED', err.message.slice(0, 300));
    });
  } finally {
    await rm(tmp, { force: true });
  }
  return bin;
}

// Exit codes and stderr per the contract at the top of ax-helper.swift.
async function read(bin: string, dev: string, udid: string): Promise<string> {
  const result = await runTool(bin, [dev, udid], { timeout: RUN_TIMEOUT_MS, maxBuffer: MAX_BUFFER });
  if (result.ok) return result.stdout.toString('utf8');
  const { failure } = result;
  const { code } = failure;
  const stderr = failure.stderr.slice(0, 300);
  if (failure.kind === 'timeout') {
    throw new KaragozError('CAPTURE_FAILED', `the simulator did not answer within ${RUN_TIMEOUT_MS / 1000} s`);
  }
  if (typeof code === 'string' && code.startsWith('ERR_CHILD_PROCESS_STDIO_MAXBUFFER')) {
    throw new KaragozError('CAPTURE_FAILED', `the tree is larger than ${MAX_BUFFER / 1024 / 1024} MiB`);
  }
  if (code === 2) {
    throw new KaragozError(
      'HELPER_FAILED',
      `${stderr}; this Xcode changed a private interface karagoz uses; update karagoz`,
    );
  }
  if (code === 3) throw new KaragozError('CAPTURE_FAILED', stderr || 'the helper could not read this screen');
  if (failure.signal) throw new KaragozError('HELPER_FAILED', `the helper crashed (${failure.signal})`);
  if (code === 'EACCES' || code === 'ENOENT') {
    throw new KaragozError('HELPER_FAILED', `cannot run ${bin} (${code}); ${CACHE_HINT}`);
  }
  throw new KaragozError('HELPER_FAILED', stderr || failure.message.slice(0, 300));
}

const text = (value: unknown) => (typeof value === 'string' && value !== '' ? value : undefined);
const round = (value: number) => Math.round(value * 100) / 100;

// One helper node to K24's skeleton with iOS names; frames are points, bounds are screenshot pixels (K34).
function node(raw: unknown, scale: number): IosNode {
  if (!isRecord(raw) || typeof raw.role !== 'string') throw new Error('a node has no role');
  const frame = Array.isArray(raw.frame)
    ? raw.frame.filter((n: unknown): n is number => typeof n === 'number' && Number.isFinite(n))
    : [];
  if (frame.length !== 4) throw new Error('a node has no frame');
  const [x = 0, y = 0, width = 0, height = 0] = frame;
  if (raw.children !== undefined && !Array.isArray(raw.children)) throw new Error('children is not a list');
  const children = Array.isArray(raw.children) ? raw.children.map((child: unknown) => node(child, scale)) : [];
  const label = text(raw.label);
  const identifier = text(raw.identifier);
  const value = text(raw.value);
  return {
    role: (text(raw.subrole) ?? raw.role).replace(/^AX/, ''),
    ...(label && { label }),
    ...(identifier && { identifier }),
    ...(value && { value }),
    ...(raw.focused === true && { focused: true }),
    ...(raw.selected === true && { selected: true }),
    ...(raw.enabled === false && { enabled: false }),
    bounds: [x, y, x + width, y + height].map((v) => round(v * scale)),
    ...(children.length > 0 && { children }),
  };
}

function parse(stdout: string): IosNode {
  try {
    const parsed: unknown = JSON.parse(stdout);
    const screen = isRecord(parsed) ? parsed.screen : undefined;
    if (!isRecord(screen)) throw new Error('no screen');
    const { width, height, scale } = screen;
    if (typeof width !== 'number' || typeof height !== 'number' || typeof scale !== 'number' || !(scale > 0)) {
      throw new Error('no screen size or scale');
    }
    return node(isRecord(parsed) ? parsed.root : undefined, panelScale(width, height, scale));
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    throw new KaragozError('CAPTURE_FAILED', `cannot parse the helper's output: ${err.message}`);
  }
}

// An XCUI session (text's, or an Xcode UI test's) turns app accessibility off when it ends, whatever it was, and apps
// opened after that give an empty tree until the simulator restarts (K35 3.4 build).
const APP_AX = ['com.apple.Accessibility', 'ApplicationAccessibilityEnabled'];

export async function appAccessibility(udid: string): Promise<boolean> {
  try {
    return (await simctl(['spawn', udid, 'defaults', 'read', ...APP_AX])).trim() === '1';
  } catch (err) {
    // A missing key fails the read and means off: there is nothing to write back.
    if (!(err instanceof KaragozError)) throw err;
    return false;
  }
}

// Outside the call's cancellation: a cancelled call must still leave app accessibility on (K31).
export const restoreAppAccessibility = (udid: string) =>
  cancellation.exit(() => simctl(['spawn', udid, 'defaults', 'write', ...APP_AX, '-bool', 'true']));

// The frontmost app of a booted simulator. The compile runs first, so HELPER_FAILED wins over a read failure.
export async function readTree(udid: string): Promise<{ rotation: number | null; root: IosNode }> {
  const dev = await xcode();
  const bin = await helper(dev);
  const [stdout, rotated] = await Promise.all([read(bin, dev, udid), rotation(udid)]);
  const root = parse(stdout);
  // The simulator's bridge turns the setting on at the first read after boot; with it off, karagoz does the same, and
  // only an app started afterwards reads in full (K47).
  if (!root.children && root.bounds.every((value) => value === 0) && !(await appAccessibility(udid))) {
    await restoreAppAccessibility(udid);
    throw new KaragozError(
      'CAPTURE_FAILED',
      "the app in front opened while the simulator's app accessibility was off (a UI test turns it off when it ends); karagoz turned it back on: restart the app (terminate, then launch) and read again",
    );
  }
  return { rotation: rotated, root };
}

// XCUIElement.ElementType raw values (Xcode 27.1's XCUIElementTypes.h) by name. XCTest's `other` is the simulator's
// Group, its `toggle` the simulator's Switch (K34, K41).
const TYPES =
  'Any Group Application Group Window Sheet Drawer Alert Dialog Button RadioButton RadioGroup CheckBox DisclosureTriangle PopUpButton ComboBox MenuButton ToolbarButton Popover Keyboard Key NavigationBar TabBar TabGroup Toolbar StatusBar Table TableRow TableColumn Outline OutlineRow Browser CollectionView Slider PageIndicator ProgressIndicator ActivityIndicator SegmentedControl Picker PickerWheel Switch Switch Link Image Icon SearchField ScrollView ScrollBar StaticText TextField SecureTextField DatePicker TextView Menu MenuItem MenuBar MenuBarItem Map WebView IncrementArrow DecrementArrow Timeline RatingIndicator ValueIndicator SplitGroup Splitter RelevanceIndicator ColorWell HelpTag Matte DockItem Ruler RulerMarker Grid LevelIndicator Cell LayoutArea LayoutItem Handle Stepper Tab TouchBar StatusItem'.split(
    ' ',
  );
const STATIC_TEXT = 48;
// searchField, textField, secureTextField, textView: an empty one shows its placeholder as its value (K34).
const TEXT_ENTRY = new Set([45, 49, 50, 52]);

// One runner node to K24's skeleton with iOS names; frames are points, bounds are screenshot pixels (K34, K41).
function phoneNode(raw: unknown, scale: number): IosNode {
  if (!isRecord(raw) || typeof raw.type !== 'number') throw new Error('a node has no type');
  const frame = Array.isArray(raw.frame)
    ? raw.frame.filter((n: unknown): n is number => typeof n === 'number' && Number.isFinite(n))
    : [];
  if (frame.length !== 4) throw new Error('a node has no frame');
  const [x = 0, y = 0, width = 0, height = 0] = frame;
  if (raw.children !== undefined && !Array.isArray(raw.children)) throw new Error('children is not a list');
  const children = Array.isArray(raw.children) ? raw.children.map((child: unknown) => phoneNode(child, scale)) : [];
  const type = raw.type;
  const role =
    raw.heading === true && (type === STATIC_TEXT || type === 1) ? 'Heading' : (TYPES[type] ?? `Element${type}`);
  const label = text(raw.label);
  const identifier = text(raw.identifier);
  const value = text(raw.value) ?? (TEXT_ENTRY.has(type) ? text(raw.placeholder) : undefined);
  return {
    role,
    ...(label && { label }),
    ...(identifier && { identifier }),
    ...(value && { value }),
    ...(raw.focused === true && { focused: true }),
    ...(raw.selected === true && { selected: true }),
    ...(raw.enabled === false && { enabled: false }),
    bounds: [x, y, x + width, y + height].map((v) => round(v * scale)),
    ...(children.length > 0 && { children }),
  };
}

// A quarter turn of a subtree's bounds from the portrait panel (width x height pixels) into the screen's landscape.
function turned(node: IosNode, rotation: 90 | 270, width: number, height: number): IosNode {
  const [l = 0, t = 0, r = 0, b = 0] = node.bounds;
  const children = node.children?.map((child) => turned(child, rotation, width, height));
  return {
    ...node,
    bounds: rotation === 270 ? [height - b, l, height - t, r] : [t, width - r, b, width - l],
    ...(children && { children }),
  };
}

// In landscape XCTest reports the software keyboard in the portrait panel's coordinates while the app around it is
// turned (measured at rotation 270, K41); a keyboard outside the screen is turned into it.
// ponytail: rotation 90 turns the other way by symmetry, not measured; measure when a phone is held that way.
function keyboardsTurned(node: IosNode, rotation: number | null, panel: { width: number; height: number }): IosNode {
  if (rotation !== 90 && rotation !== 270) return node;
  const [, , right = 0, bottom = 0] = node.bounds;
  if (node.role === 'Keyboard' && (bottom > panel.width || right > panel.height)) {
    return turned(node, rotation, panel.width, panel.height);
  }
  const children = node.children?.map((child) => keyboardsTurned(child, rotation, panel));
  return children ? { ...node, children } : node;
}

// What is on a paired iPhone's screen, from karagoz's runner; scale and rotation from the display screenshot reads,
// which an element tap reuses. The runner's failure is reported first: it is the one a caller can act on (install-runner).
export async function readPhoneTree(
  udid: string,
): Promise<{ rotation: number | null; root: IosNode; display: Awaited<ReturnType<typeof displayOf>> }> {
  const [raw, shown] = await Promise.allSettled([tree(udid), displayOf(udid)]);
  if (raw.status === 'rejected') throw raw.reason;
  if (shown.status === 'rejected') throw shown.reason;
  const { scale, rotation, panel } = shown.value;
  try {
    const root = phoneNode(raw.value, panel ? panelScale(panel.width, panel.height, scale) : scale);
    return { rotation, root: panel ? keyboardsTurned(root, rotation, panel) : root, display: shown.value };
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    throw new KaragozError('CAPTURE_FAILED', `cannot parse the runner's tree: ${err.message}`);
  }
}
