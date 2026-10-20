import { resolveTarget } from './devices.js';
import { readTree as readAndroidTree } from './drivers/android/ui-tree.js';
import { readPhoneTree, readTree as readIosTree } from './drivers/ios/ui-tree.js';

export async function uiTree(device: string | undefined) {
  const target = await resolveTarget(device);
  const { rotation, root } = await (target.platform === 'android'
    ? readAndroidTree(target.id)
    : target.kind === 'physical'
      ? readPhoneTree(target.id)
      : readIosTree(target.id));
  return { device: target.id, rotation, root };
}
