import { packageTarget } from './app.js';
import { resolveTarget } from './devices.js';
import { logs as androidLogs } from './drivers/android/logs.js';
import { logs as iosLogs } from './drivers/ios/logs.js';

// At 100, 46.5% of measured windows passed the ~10k tokens where Codex cuts a result and Claude Code warns; at 30,
// 0.2% (K29).
const LINES = 30;

export async function logs(
  device: string | undefined,
  pkg: string | undefined,
  since: string | undefined,
  lines = LINES,
) {
  const { id, platform } = pkg === undefined ? await resolveTarget(device) : await packageTarget(device, pkg);
  return platform === 'ios' ? iosLogs(id, pkg, since, lines) : androidLogs(id, pkg, since, lines);
}
