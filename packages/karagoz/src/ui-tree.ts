import { resolveTarget } from './devices.js';
import { readTree as readAndroidTree } from './drivers/android/ui-tree.js';
import { readTree as readIosTree } from './drivers/ios/ui-tree.js';

export async function uiTree(device: string | undefined) {
  const { id, platform } = await resolveTarget(device);
  const { rotation, root } = await (platform === 'ios' ? readIosTree(id) : readAndroidTree(id));
  return { device: id, rotation, root };
}
