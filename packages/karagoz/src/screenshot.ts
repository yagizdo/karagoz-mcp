import { lstat, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { resolveTarget } from './devices.js';
import { capture as captureAndroid } from './drivers/android/screenshot.js';
import { capture as captureIos, capturePhone } from './drivers/ios/screenshot.js';
import { KaragozError } from './errors.js';

export async function screenshot(device: string | undefined, out: string | undefined) {
  const target = out === undefined ? undefined : resolve(out);
  // A model picks this path over MCP; only a .png gets overwritten (K22).
  if (target !== undefined && !target.toLowerCase().endsWith('.png')) {
    throw new KaragozError('INVALID_ARGS', `'${target}' is not a .png file`);
  }
  // The first command that runs on an iPhone (K21 4.2 note).
  const picked = await resolveTarget(device, { iphone: true });
  const { id } = picked;
  const capture =
    picked.platform === 'android' ? captureAndroid : picked.kind === 'physical' ? capturePhone : captureIos;
  const { png, pixels, scale, safeArea, rotation } = await capture(id);
  // ':' is invalid in Windows file names, and `adb connect` serials contain it (127.0.0.1:5555).
  const safeId = id.replace(/[^A-Za-z0-9._-]/g, '_');
  const stamp = new Date().toISOString().replace(/[-:.]/g, '');
  const path = target ?? join(tmpdir(), 'karagoz', `${safeId}-${stamp}.png`);
  try {
    const dir = dirname(path);
    if (target === undefined) {
      // On Linux tmpdir() is the shared /tmp: another user could create karagoz/ first, or plant a symlink at the
      // predictable file name. The directory must be the caller's own, and the write refuses anything already at
      // the path. --out is left alone, the caller picked it.
      // ponytail: two captures of one device in the same millisecond collide, and the second gets WRITE_FAILED.
      await mkdir(dir, { recursive: true, mode: 0o700 });
      const info = await lstat(dir);
      if (!info.isDirectory() || (process.getuid && info.uid !== process.getuid())) {
        throw new Error(`${dir} is not a directory owned by the current user; pass --out`);
      }
      await writeFile(path, png, { flag: 'wx', mode: 0o600 });
    } else {
      await mkdir(dir, { recursive: true });
      await writeFile(path, png);
    }
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    throw new KaragozError('WRITE_FAILED', err.message);
  }
  return {
    path,
    device: id,
    pixels,
    // Not rounded: derived from pixels and scale, and a rounded copy would disagree with them.
    logical: { width: pixels.width / scale, height: pixels.height / scale },
    scale,
    safeArea,
    rotation,
  };
}
