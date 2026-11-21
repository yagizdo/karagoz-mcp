import { setTimeout as sleep } from 'node:timers/promises';
import { cancellation } from './cancellation.js';
import { resolveTarget } from './devices.js';
import {
  compact as compactAndroid,
  readAfterAction as readAndroidAfterAction,
  readTree as readAndroidTree,
} from './drivers/android/ui-tree.js';
import { compact as compactIos, readPhoneTree, readTree as readIosTree } from './drivers/ios/ui-tree.js';
import { KaragozError } from './errors.js';

export type Resolved = Awaited<ReturnType<typeof resolveTarget>>;

async function read(target: Resolved, detail: 'compact' | 'full') {
  if (target.platform === 'android') {
    const { rotation, root } = await readAndroidTree(target.id);
    return { rotation, root: detail === 'full' ? root : compactAndroid(root) };
  }
  const { rotation, root } = await (target.kind === 'physical' ? readPhoneTree(target.id) : readIosTree(target.id));
  return { rotation, root: detail === 'full' ? root : compactIos(root) };
}

export async function uiTree(device: string | undefined, detail = 'compact') {
  if (detail !== 'compact' && detail !== 'full') {
    throw new KaragozError('INVALID_ARGS', `detail must be compact or full (got '${detail}')`);
  }
  const target = await resolveTarget(device);
  return { device: target.id, ...(await read(target, detail)) };
}

// A dump started during a window transition finds no focused window: right after a tap that opened a Settings page,
// 3 of 4 reads failed at 0 ms, 1 of 4 at 300 ms, 2 of 6 at 1000 ms (K73).
const SETTLE_ANDROID_MS = 1000;
// iOS gives a read no idle signal to wait for, so the tree is read until two reads in a row match: a Settings push
// read new at 0.55 s and unchanged from 1.05 s (K73). The ceiling is checked between reads: one that starts just
// before it ends after it.
const SETTLE_FIRST_MS = 300;
const SETTLE_EVERY_MS = 200;
const SETTLE_MAX_MS = 3000;

// The compact tree once the screen has settled after an action, the last read when it never does.
export async function settledTree(target: Resolved) {
  const signal = cancellation.getStore();
  if (target.platform === 'android') {
    await sleep(SETTLE_ANDROID_MS, undefined, signal && { signal });
    const { rotation, root } = await readAndroidAfterAction(target.id);
    return { rotation, root: compactAndroid(root) };
  }
  const start = performance.now();
  await sleep(SETTLE_FIRST_MS, undefined, signal && { signal });
  let last = await read(target, 'compact');
  while (performance.now() - start < SETTLE_MAX_MS) {
    await sleep(SETTLE_EVERY_MS, undefined, signal && { signal });
    const next = await read(target, 'compact');
    if (JSON.stringify(next) === JSON.stringify(last)) return next;
    last = next;
  }
  return last;
}
