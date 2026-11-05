import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { KaragozError } from '../../errors.js';
import { pngSize } from '../../png.js';
import { captureScreen, displayOf, rotation } from './devicectl.js';
import { screenshot as runnerScreenshot } from './runner.js';
import { simctl } from './simctl.js';

// ponytail: the 12 mini and 13 mini render 375 pt wide and downsample to a 1080x2340 panel; UIKit gives apps
// nativeScale 2.88, simctl's SIMULATOR_MAINSCREEN_SCALE says 3 (Apple forum reply, not measured here, K33). No other
// iPhone or iPad has this panel. The limit lifts when a runtime source of the scale is found.
const MINI = { width: 1080, height: 2340, scale: 1080 / 375 };

// Either orientation: Xcode 27's image follows the interface, so a landscape mini is 2340x1080 (K34).
export function panelScale(width: number, height: number, reported: number): number {
  const mini = (width === MINI.width && height === MINI.height) || (width === MINI.height && height === MINI.width);
  return mini ? MINI.scale : reported;
}

// Neither tool writes the image to stdout: Xcode 27's simctl writes "-" to a file named "-" in the working directory
// (measured), devicectl refuses "-" (K40). The private directory keeps a failed capture's 0-byte file away from --out
// (K33).
async function shoot(write: (file: string) => Promise<unknown>): Promise<Buffer> {
  const dir = await mkdtemp(join(tmpdir(), 'karagoz-'));
  const file = join(dir, 'shot.png');
  try {
    await write(file);
    // An unreadable file is no image, which capture()'s CAPTURE_FAILED check reports.
    return await readFile(file).catch(() => Buffer.alloc(0));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

// On Xcode 27 the image follows the interface orientation, which devicectl reports; on Xcode 26.2 it was the panel in
// portrait and nothing reported the orientation. The safe area cannot be read from outside the simulator on either, so
// it is null rather than a guess (K6 3.2 note, K33, K34).
export async function capture(udid: string) {
  const [png, scaleText, rotated] = await Promise.all([
    // A path works on Xcode 27 and is the form simctl's help shows on 26, not yet run there. --mask=ignored keeps the
    // square framebuffer; simctl's help states no default (K33).
    shoot((file) => simctl(['io', udid, 'screenshot', '--mask=ignored', file])),
    simctl(['getenv', udid, 'SIMULATOR_MAINSCREEN_SCALE']),
    rotation(udid),
  ]);
  const pixels = pngSize(png);
  if (!pixels) {
    throw new KaragozError(
      'CAPTURE_FAILED',
      png.toString('utf8').trim().slice(0, 300) || 'simctl returned no image data',
    );
  }
  const reported = Number(scaleText.trim());
  if (!Number.isFinite(reported) || reported <= 0) {
    throw new KaragozError(
      'CAPTURE_FAILED',
      `cannot read scale from 'simctl getenv' (got '${scaleText.trim().slice(0, 100)}')`,
    );
  }
  return { png, pixels, scale: panelScale(pixels.width, pixels.height, reported), safeArea: null, rotation: rotated };
}

// A paired iPhone. The PNG is devicectl's own bytes, 16 bits per channel Display P3 on the measured phone, and follows
// the interface orientation; the safe area has no source outside the app (K40). The capture's failure is reported before
// the displays read's. A devicectl without the verb (Xcode 26 and older) hands the capture to karagoz's runner: its PNG
// is XCUITest's, turned by the runner to follow the interface, and its scale and rotation replace the displays read.
export async function capturePhone(udid: string) {
  const [shot, shown] = await Promise.allSettled([shoot((file) => captureScreen(udid, file)), displayOf(udid)]);
  let png: Buffer, scale: number, turned: number | null, source: string;
  if (shot.status === 'fulfilled') {
    if (shown.status === 'rejected') throw shown.reason;
    png = shot.value;
    ({ scale, rotation: turned } = shown.value);
    source = 'devicectl';
  } else if (shot.reason instanceof KaragozError && shot.reason.code === 'NOT_SUPPORTED') {
    ({ png, scale, rotation: turned } = await fromRunner(udid));
    source = "karagoz's runner";
  } else {
    throw shot.reason;
  }
  const pixels = pngSize(png);
  if (!pixels) throw new KaragozError('CAPTURE_FAILED', `${source} returned no image data`);
  // iPhone and iPad panels are portrait in their native orientation, so a quarter turn means a landscape PNG; the two
  // calls disagree when the screen turned between them, the runner's image and orientation when it turned mid-read.
  const landscape = pixels.width > pixels.height;
  if (turned !== null && (turned === 90 || turned === 270) !== landscape) {
    throw new KaragozError(
      'CAPTURE_FAILED',
      `the screen rotated during the capture (rotation ${turned}, screenshot ${pixels.width}x${pixels.height})`,
    );
  }
  return { png, pixels, scale: panelScale(pixels.width, pixels.height, scale), safeArea: null, rotation: turned };
}

// No automatic install (0.1.0): without the runner the caller gets both ways out.
async function fromRunner(udid: string) {
  try {
    return await runnerScreenshot(udid);
  } catch (err) {
    if (err instanceof KaragozError && err.code === 'RUNNER_NOT_INSTALLED') {
      throw new KaragozError(
        'RUNNER_NOT_INSTALLED',
        `${err.message} Or install Xcode 27 and open it once: its devicectl takes the screenshot without the runner.`,
      );
    }
    throw err;
  }
}
