import { resolveTarget } from './devices.js';
import { compact as compactAndroid, readTree as readAndroidTree } from './drivers/android/ui-tree.js';
import { compact as compactIos, readPhoneTree, readTree as readIosTree } from './drivers/ios/ui-tree.js';
import { KaragozError } from './errors.js';

export async function uiTree(device: string | undefined, detail = 'compact') {
  if (detail !== 'compact' && detail !== 'full') {
    throw new KaragozError('INVALID_ARGS', `detail must be compact or full (got '${detail}')`);
  }
  const target = await resolveTarget(device);
  if (target.platform === 'android') {
    const { rotation, root } = await readAndroidTree(target.id);
    return { device: target.id, rotation, root: detail === 'full' ? root : compactAndroid(root) };
  }
  const { rotation, root } = await (target.kind === 'physical' ? readPhoneTree(target.id) : readIosTree(target.id));
  return { device: target.id, rotation, root: detail === 'full' ? root : compactIos(root) };
}
