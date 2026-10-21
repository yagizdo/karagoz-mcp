import { doctor as adbDoctor } from './drivers/android/doctor.js';
import { doctor as xcodeDoctor } from './drivers/ios/doctor.js';
import { IS_MAC } from './devices.js';

export async function doctor() {
  const [adb, xcode] = await Promise.all([adbDoctor(), IS_MAC ? xcodeDoctor() : undefined]);
  return { ...adb, ...xcode };
}
