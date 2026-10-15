import { androidTarget } from './devices.js';
import { checkPackage } from './drivers/android/app.js';
import { logs as androidLogs } from './drivers/android/logs.js';

// At 100, 46.5% of measured windows passed the ~10k tokens where Codex cuts a result and Claude Code warns; at 30,
// 0.2% (K29).
const LINES = 30;

export async function logs(
  device: string | undefined,
  pkg: string | undefined,
  since: string | undefined,
  lines = LINES,
) {
  if (pkg !== undefined) checkPackage(pkg);
  return androidLogs(await androidTarget(device, 'logs'), pkg, since, lines);
}
