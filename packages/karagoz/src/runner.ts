import { resolveTarget } from './devices.js';
import { installRunner, uninstallRunner } from './drivers/ios/runner.js';

export async function installRunnerOn(device: string | undefined, team: string | undefined) {
  const { id } = await resolveTarget(device, 'iphone-only');
  return installRunner(id, team);
}

export async function uninstallRunnerFrom(device: string | undefined) {
  const { id } = await resolveTarget(device, 'iphone-only');
  return uninstallRunner(id);
}
