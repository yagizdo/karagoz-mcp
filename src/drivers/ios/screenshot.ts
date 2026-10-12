import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { KaragozError } from '../../errors.js';
import { pngSize } from '../../png.js';
import { rotation } from './devicectl.js';
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

// Xcode 27's simctl writes "-" to a file named "-" in the working directory, not to stdout (measured); a path works on
// 27 and is the form simctl's help shows on 26, not yet run there. The private directory keeps a failed capture's 0-byte
// file away from --out (K33).
async function shoot(udid: string): Promise<Buffer> {
  const dir = await mkdtemp(join(tmpdir(), 'karagoz-'));
  const file = join(dir, 'shot.png');
  try {
    // --mask=ignored keeps the square framebuffer; simctl's help states no default (K33).
    await simctl(['io', udid, 'screenshot', '--mask=ignored', file]);
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
    shoot(udid),
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
