import { KaragozError } from '../../errors.js';
import { pngSize } from '../../png.js';
import { adb, adbBytes } from './adb.js';

// The Android counterpart of iOS safeAreaInsets: systemBars() | displayCutout() (K23). The IME and the gesture
// areas are left out, as iOS leaves out the keyboard.
const SAFE_AREA_TYPES = new Set(['statusBars', 'navigationBars', 'captionBar', 'displayCutout']);
// Android 11 to 13 print ITYPE_* names where Android 14 prints the public types (K23 2.2b).
const LEGACY_TYPES = new Map([
  ['ITYPE_STATUS_BAR', 'statusBars'],
  ['ITYPE_CLIMATE_BAR', 'statusBars'],
  ['ITYPE_NAVIGATION_BAR', 'navigationBars'],
  ['ITYPE_EXTRA_NAVIGATION_BAR', 'navigationBars'],
  ['ITYPE_LOCAL_NAVIGATION_BAR_1', 'navigationBars'],
  ['ITYPE_LOCAL_NAVIGATION_BAR_2', 'navigationBars'],
  ['ITYPE_CAPTION_BAR', 'captionBar'],
  ['ITYPE_LEFT_DISPLAY_CUTOUT', 'displayCutout'],
  ['ITYPE_TOP_DISPLAY_CUTOUT', 'displayCutout'],
  ['ITYPE_RIGHT_DISPLAY_CUTOUT', 'displayCutout'],
  ['ITYPE_BOTTOM_DISPLAY_CUTOUT', 'displayCutout'],
]);

const DUMP = "'dumpsys window displays'";

// Four numbers from consecutive capture groups, starting at group `at`.
function rect(match: RegExpMatchArray, at: number) {
  return { l: Number(match[at]), t: Number(match[at + 1]), r: Number(match[at + 2]), b: Number(match[at + 3]) };
}

function unreadable(value: string, command: string, missing: string) {
  return new KaragozError('CAPTURE_FAILED', `cannot read ${value} from ${command} (no ${missing})`);
}

// The override density is what apps lay out with (measured: a 24 dp status bar at both 420 and 560 dpi).
function parseDensity(text: string): number {
  const physical = /Physical density: (\d+)/.exec(text);
  if (!physical) throw unreadable('density', "'wm density'", 'Physical density: line');
  return Number((/Override density: (\d+)/.exec(text) ?? physical)[1]);
}

// Android 10: its TYPE_* sources are not what apps get (the gesture bar reads 48 dp against 16 dp, and there is no
// cutout source); its DisplayFrames block matches the app (K23 2.2b).
function parseDisplayFrames(section: string, width: number, height: number) {
  const frames = /^\s*DisplayFrames w=\d+ h=\d+ r=([0-3])\b/m.exec(section);
  if (!frames) throw unreadable('rotation', DUMP, 'DisplayFrames r= value');
  const dockLine = /^\s*mDock=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/m.exec(section);
  if (!dockLine) throw unreadable('safe area', DUMP, 'mDock= line');
  const cutoutLine =
    /mDisplayCutout=WmDisplayCutout\{DisplayCutout\{insets=Rect\((-?\d+), (-?\d+) - (-?\d+), (-?\d+)\)/.exec(section);
  if (!cutoutLine) throw unreadable('safe area', DUMP, 'mDisplayCutout= insets');
  const dock = rect(dockLine, 1);
  const cutout = rect(cutoutLine, 1);
  const safeArea = {
    top: Math.max(dock.t, cutout.t),
    right: Math.max(width - dock.r, cutout.r),
    bottom: Math.max(height - dock.b, cutout.b),
    left: Math.max(dock.l, cutout.l),
  };
  return { rotation: Number(frames[1]) * 90, safeArea };
}

// Display 0 of `dumpsys window displays`, text format verified on Android 10 to 14 and 16 (K23). No `$` anchors:
// `shell` writes text mode on Windows, so lines may end in \r.
function parseDisplay(text: string) {
  const start = /Display: mDisplayId=0(?!\d)/.exec(text);
  if (!start) throw unreadable('display 0', DUMP, 'Display: mDisplayId=0 section');
  const after = text.slice(start.index + start[0].length);
  const next = after.indexOf('Display: mDisplayId=');
  const section = next === -1 ? after : after.slice(0, next);

  const cur = /\bcur=(\d+)x(\d+)/.exec(section);
  if (!cur) throw unreadable('display size', DUMP, 'cur= value');
  const width = Number(cur[1]);
  const height = Number(cur[2]);
  if (/^\s*InsetsSource type=TYPE_/m.test(section)) {
    return { width, height, ...parseDisplayFrames(section, width, height) };
  }
  const rotation = /^\s*mRotation=([0-3])\b/m.exec(section);
  if (!rotation) throw unreadable('rotation', DUMP, 'mRotation= line');
  const controller = section.indexOf('WindowInsetsStateController');
  if (controller === -1) throw unreadable('safe area', DUMP, 'WindowInsetsStateController section');
  const insets = section.slice(controller);
  const frameLine = /mDisplayFrame=Rect\((-?\d+), (-?\d+) - (-?\d+), (-?\d+)\)/.exec(insets);
  // Android 11 prints no mDisplayFrame=; its display frame is the logical size at 0,0, which is cur=.
  const frame = frameLine ? rect(frameLine, 1) : { l: 0, t: 0, r: width, b: height };

  // Only lines that start with `InsetsSource `: the same sources come again as `mSource=InsetsSource` under
  // InsetsSourceProviders and as `InsetsSourceControl:` under the control map (measured).
  const sources = [
    ...insets.matchAll(
      /^\s*InsetsSource (?:\S+ )?type=(\w+) frame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\] visible=(true|false)/gm,
    ),
  ];
  if (!sources.length) throw unreadable('safe area', DUMP, 'InsetsSource line');

  // Each source's edge comes from its geometry against the display frame, not from sideHint (K23).
  const safeArea = { top: 0, right: 0, bottom: 0, left: 0 };
  for (const source of sources) {
    const { l, t, r, b } = rect(source, 2);
    const type = source[1] ?? '';
    if (!SAFE_AREA_TYPES.has(LEGACY_TYPES.get(type) ?? type) || source[6] !== 'true' || r <= l || b <= t) continue;
    const fullWidth = l === frame.l && r === frame.r;
    const fullHeight = t === frame.t && b === frame.b;
    if (fullWidth && t === frame.t) safeArea.top = Math.max(safeArea.top, b - frame.t);
    else if (fullWidth && b === frame.b) safeArea.bottom = Math.max(safeArea.bottom, frame.b - t);
    else if (fullHeight && l === frame.l) safeArea.left = Math.max(safeArea.left, r - frame.l);
    else if (fullHeight && r === frame.r) safeArea.right = Math.max(safeArea.right, frame.r - l);
  }
  return { width, height, rotation: Number(rotation[1]) * 90, safeArea };
}

export async function capture(id: string) {
  // The metadata calls take ~65 ms each against a ~700 ms capture (measured), so in parallel they add nothing.
  const [png, density, dump] = await Promise.all([
    adbBytes(['-s', id, 'exec-out', 'screencap', '-p']),
    adb(['-s', id, 'shell', 'wm', 'density']),
    adb(['-s', id, 'shell', 'dumpsys', 'window', 'displays']),
  ]);
  // exec-out exits 0 when screencap fails and merges its stderr into stdout (adb source), so the bytes are the
  // only failure signal: a whole PNG or screencap's own text.
  // ponytail: with several displays screencap prints its warning lines ahead of the PNG, and this check fails on
  // purpose, since which display it picks "is not guaranteed to be consistent across captures"; the metadata is
  // read from display 0 as well. The limit lifts when a multi-display device comes into scope and -d is added.
  const pixels = pngSize(png);
  if (!pixels) {
    throw new KaragozError('CAPTURE_FAILED', png.toString('utf8').trim().slice(0, 300) || 'screencap returned no data');
  }
  const scale = parseDensity(density) / 160;
  const display = parseDisplay(dump);
  // The metadata and the capture run at the same time: a rotation between them would pair a landscape PNG with
  // portrait insets.
  if (display.width !== pixels.width || display.height !== pixels.height) {
    throw new KaragozError(
      'CAPTURE_FAILED',
      `display is ${display.width}x${display.height} but the screenshot is ${pixels.width}x${pixels.height}; the screen rotated or resized during capture`,
    );
  }
  return { png, pixels, scale, safeArea: display.safeArea, rotation: display.rotation };
}
