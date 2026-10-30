import { resolveTarget } from './devices.js';
import { installRunner, uninstallRunner, uninstallSimulatorRunner } from './drivers/ios/runner-build.js';

export async function installRunnerOn(device: string | undefined, team: string | undefined) {
  const { id } = await resolveTarget(device, 'iphone-only');
  return installRunner(id, team);
}

export async function uninstallRunnerFrom(device: string | undefined) {
  const resolved = await resolveTarget(device, 'runner');
  return resolved.platform === 'ios' && resolved.kind === 'simulator'
    ? uninstallSimulatorRunner(resolved.id)
    : uninstallRunner(resolved.id);
}
