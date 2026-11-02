import { styleText } from 'node:util';
import { hint, NO_DEVICE, type listAll } from './devices.js';
import type { doctor } from './doctor.js';

// What a person at a terminal sees from doctor and devices instead of the JSON line (K68). styleText drops the colors
// when stdout is not a terminal or NO_COLOR is set.
// ponytail: Node 22 before 22.8 ignores NO_COLOR here (styleText checks the stream from 22.8); lift with the engine floor.

type Report = Awaited<ReturnType<typeof doctor>>;
type Listing = Awaited<ReturnType<typeof listAll>>;

// The marks: ✓ ready, ! works with something still to do, ✗ absent or broken.
type Mark = 'ok' | 'warn' | 'error';
type Note = [Mark, string];

function sign(mark: Mark) {
  if (mark === 'ok') return styleText('green', '✓');
  return mark === 'warn' ? styleText('yellow', '!') : styleText('red', '✗');
}

const words = (...parts: (string | undefined)[]) => parts.filter((part) => part).join(' ');
const broken = (status: string) => status === 'missing' || status === 'failed';
const worst = (notes: Note[]): Mark =>
  notes.some(([mark]) => mark === 'error') ? 'error' : notes.length ? 'warn' : 'ok';

type Section = { mark: Mark; title: string; notes: Note[] };

export function doctorText({ adb, xcode }: Report) {
  const adbMark: Mark = adb.status === 'ok' ? 'ok' : adb.status === 'outdated' ? 'warn' : 'error';
  const adbNotes: Note[] = [];
  if (adb.message) adbNotes.push([adbMark, adb.message]);
  // A broken adb the lookup passed over still deserves a look.
  for (const candidate of adb.candidates) {
    if (candidate.source !== adb.source && (candidate.status === 'failed' || candidate.status === 'outdated')) {
      adbNotes.push(['warn', `${words(candidate.source, candidate.path)}: ${candidate.message ?? candidate.status}`]);
    }
  }
  if (adb.install) adbNotes.push([adbMark, adb.install]);
  const sections: Section[] = [
    {
      mark: adbMark,
      title: adb.status === 'missing' ? 'adb not found' : words('adb', adb.version, adb.source && `from ${adb.source}`),
      notes: adbNotes,
    },
  ];
  if (xcode) {
    const { simctl, swiftc, devicectl, helper, signing, iosRunner, xcodebuild, usbmuxd, tar, log } = xcode;
    sections.push({
      mark: xcode.status === 'ok' ? 'ok' : xcode.status === 'outdated' ? 'warn' : 'error',
      title:
        xcode.status === 'missing'
          ? 'Xcode not found'
          : words('Xcode', xcode.version, xcode.build && `(${xcode.build})`, xcode.path),
      notes:
        xcode.status === 'outdated' && xcode.message
          ? [['warn', xcode.message]]
          : Object.entries({ simctl, swiftc, devicectl, helper }).flatMap(([name, { status, message }]): Note[] =>
              broken(status) ? [['error', `${name}: ${message ?? status}`]] : [],
            ),
    });
    // signing and the rest are outside xcode.status: a Mac without iPhones needs none of them (K30 4.7). A missing
    // team or runner is a setup step still to do, not a fault.
    const notes = Object.entries({ signing, runner: iosRunner, xcodebuild, usbmuxd, tar, log }).flatMap(
      ([name, { status, message }]): Note[] => {
        if (status === 'not built')
          return [['warn', `${name} not built: karagoz install-runner builds it for a connected iPhone`]];
        if (name === 'signing' && status === 'missing') return [['warn', message ?? 'no signing team']];
        return broken(status) ? [['error', `${name}: ${message ?? status}`]] : [];
      },
    );
    sections.push({ mark: worst(notes), title: 'iPhone', notes });
  }
  const issues = sections.filter(({ mark }) => mark !== 'ok').length;
  return [
    ...sections.flatMap(({ mark, title, notes }) => [
      `[${sign(mark)}] ${title}`,
      ...notes.map(([note, text]) => `    ${sign(note)} ${text}`),
    ]),
    '',
    issues
      ? `${sign('warn')} Doctor found issues in ${issues} ${issues === 1 ? 'category' : 'categories'}.`
      : `${styleText('green', '•')} No issues found!`,
  ].join('\n');
}

export function devicesText(listing: Listing) {
  const { devices } = listing;
  const rows = devices.map((device) => [
    device.name ?? '(no name)',
    device.id,
    device.kind,
    device.platform === 'android'
      ? words('Android', device.os ?? undefined, device.api === null ? undefined : `(API ${device.api})`)
      : words('iOS', device.os ?? undefined),
    words(device.state, 'runner' in device && device.runner ? `runner ${device.runner}` : undefined),
  ]);
  const widths = [0, 1, 2, 3].map((column) => Math.max(...rows.map((row) => row[column]?.length ?? 0)));
  const lines = devices.length ? [`Found ${devices.length} device${devices.length === 1 ? '' : 's'}:`] : [NO_DEVICE];
  devices.forEach((device, i) => {
    const [name = '', id = '', kind = '', os = '', state = ''] = rows[i] ?? [];
    const waiting = hint(device);
    const cells = [name, id, kind, os].map((cell, column) => cell.padEnd(widths[column] ?? 0));
    lines.push(`  ${cells.join(' • ')} • ${styleText(waiting === undefined ? 'green' : 'yellow', state)}`);
    if (waiting) lines.push(`      ${sign('warn')} ${waiting}`);
    if ('runner' in device && device.runner === 'not installed') {
      lines.push(
        `      ${sign('warn')} karagoz install-runner --device ${device.id} installs the runner iPhone commands need.`,
      );
    }
  });
  if ('errors' in listing) {
    for (const { platform, code, message } of listing.errors)
      lines.push(`${sign('error')} ${platform}: ${code}: ${message}`);
  }
  lines.push('');
  if (devices.length > 1) lines.push(styleText('dim', 'Pick one with --device <id or name>, or set KARAGOZ_DEVICE.'));
  lines.push(styleText('dim', 'Missing a device? Run karagoz doctor.'));
  return lines.join('\n');
}
