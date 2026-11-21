import { install, launch, openUrl, terminate, uninstall } from './app.js';
import { doctor } from './doctor.js';
import { doubleTap, key, swipe, tap, text, type Target } from './input.js';
import { logs } from './logs.js';
import { installRunnerOn, uninstallRunnerFrom } from './runner.js';
import { screenshot } from './screenshot.js';
import { devicesText, doctorText } from './terminal.js';
import { uiTree } from './ui-tree.js';
import { listAll } from './devices.js';
import { KaragozError, type ErrorCode } from './errors.js';

// A command receives its options as strings, a boolean option as 'true' or 'false'. args names the positional
// arguments a command takes, in order; run gets exactly that many, or none when argsOptional is set.
export type Command = {
  options: Record<string, { type: 'string' } | { type: 'boolean' }>;
  args: readonly string[];
  // tap, long-press and double-tap can name their target with --text or --id instead of <x> <y>.
  argsOptional?: true;
  run: (values: Record<string, string | undefined>, args: string[]) => Promise<unknown>;
  // What the CLI prints instead of the JSON when stdout is a terminal (K68).
  text?: (values: Record<string, string | undefined>, args: string[]) => Promise<string>;
};

// Screen pixels, decimals allowed: a bounds center can be a half, and input reads floats (K25). A minus sign never gets
// here, parseArgs reads -5 as an option.
function decimal(label: string, value = ''): number {
  if (!/^\d+(\.\d+)?$/.test(value)) {
    throw new KaragozError('INVALID_ARGS', `${label} must be a non-negative number (got '${value}')`);
  }
  return Number(value);
}

// Nine digits at most: the input drivers add the value to their timeout (adb's TIMEOUT_MS, the iOS helper's
// RUN_TIMEOUT_MS), and an execFile timeout above 2^31-1 ms overflows Node's timer, which then fires after 1 ms.
function integer(label: string, value = ''): number {
  if (!/^\d{1,9}$/.test(value)) {
    throw new KaragozError('INVALID_ARGS', `${label} must be a whole number of milliseconds (got '${value}')`);
  }
  return Number(value);
}

// logcat reads an all-digit -t value as a line count, so a whole second gets .0, and it wraps seconds above
// 2^32-1 to another date without an error (K29).
function seconds(label: string, value = ''): string {
  if (!/^\d{1,10}(\.\d{1,9})?$/.test(value) || parseInt(value, 10) > 4294967295) {
    throw new KaragozError('INVALID_ARGS', `${label} must be Unix time in seconds (got '${value}')`);
  }
  return value.includes('.') ? value : `${value}.0`;
}

// From 1: logs.ts keeps records.slice(-lines), and slice(-0) keeps everything.
function count(label: string, value = ''): number {
  if (!/^[1-9]\d{0,8}$/.test(value)) {
    throw new KaragozError('INVALID_ARGS', `${label} must be a whole number from 1 to 999999999 (got '${value}')`);
  }
  return Number(value);
}

// The long press every target accepts: AOSP waits 400 ms, Flutter and iOS 500, Samsung's setting up to 1000; its
// 1500 setting needs --duration (K55).
const LONG_PRESS_MS = 1000;

// Exactly one of <x> <y>, --text or --id, checked before any device call.
function target(
  name: string,
  { text: label, id: resourceId, timeout }: Record<string, string | undefined>,
  [x, y]: string[],
): Target {
  if ([x, label, resourceId].filter((form) => form !== undefined).length !== 1) {
    throw new KaragozError('INVALID_ARGS', `'${name}' takes <x> <y>, --text or --id`);
  }
  const parsed: Target =
    label !== undefined
      ? { kind: 'text', label }
      : resourceId !== undefined
        ? { kind: 'id', id: resourceId }
        : { kind: 'point', x: decimal('<x>', x), y: decimal('<y>', y) };
  if (parsed.kind === 'point' && timeout !== undefined) {
    throw new KaragozError('INVALID_ARGS', '--timeout needs --text or --id');
  }
  return parsed;
}

function wait(timeout: string | undefined): number {
  return timeout === undefined ? 0 : integer('--timeout', timeout);
}

export const commands: Record<string, Command> = {
  devices: { options: {}, args: [], run: () => listAll(), text: async () => devicesText(await listAll()) },
  screenshot: {
    options: { device: { type: 'string' }, out: { type: 'string' } },
    args: [],
    run: ({ device, out }) => screenshot(device, out),
  },
  'ui-tree': {
    options: { device: { type: 'string' }, detail: { type: 'string' } },
    args: [],
    run: ({ device, detail }) => uiTree(device, detail),
  },
  key: {
    options: { device: { type: 'string' }, tree: { type: 'boolean' } },
    args: ['key'],
    run: ({ device, tree }, [value = '']) => key(device, value, tree === 'true'),
  },
  tap: {
    options: {
      device: { type: 'string' },
      text: { type: 'string' },
      id: { type: 'string' },
      timeout: { type: 'string' },
      tree: { type: 'boolean' },
    },
    args: ['x', 'y'],
    argsOptional: true,
    run: (values, args) =>
      tap(values.device, target('tap', values, args), undefined, wait(values.timeout), values.tree === 'true'),
  },
  'long-press': {
    options: {
      device: { type: 'string' },
      duration: { type: 'string' },
      text: { type: 'string' },
      id: { type: 'string' },
      timeout: { type: 'string' },
      tree: { type: 'boolean' },
    },
    args: ['x', 'y'],
    argsOptional: true,
    run: (values, args) =>
      tap(
        values.device,
        target('long-press', values, args),
        values.duration === undefined ? LONG_PRESS_MS : integer('--duration', values.duration),
        wait(values.timeout),
        values.tree === 'true',
      ),
  },
  'double-tap': {
    options: {
      device: { type: 'string' },
      text: { type: 'string' },
      id: { type: 'string' },
      timeout: { type: 'string' },
      tree: { type: 'boolean' },
    },
    args: ['x', 'y'],
    argsOptional: true,
    run: (values, args) =>
      doubleTap(values.device, target('double-tap', values, args), wait(values.timeout), values.tree === 'true'),
  },
  swipe: {
    options: { device: { type: 'string' }, duration: { type: 'string' }, tree: { type: 'boolean' } },
    args: ['x1', 'y1', 'x2', 'y2'],
    run: ({ device, duration, tree }, [x1, y1, x2, y2]) =>
      swipe(
        device,
        decimal('<x1>', x1),
        decimal('<y1>', y1),
        decimal('<x2>', x2),
        decimal('<y2>', y2),
        duration === undefined ? undefined : integer('--duration', duration),
        tree === 'true',
      ),
  },
  text: {
    options: { device: { type: 'string' }, tree: { type: 'boolean' } },
    args: ['text'],
    // A text that starts with - goes after --, where parseArgs stops reading options: karagoz text -- -5.
    run: ({ device, tree }, [value]) => {
      if (!value) throw new KaragozError('INVALID_ARGS', "'text' needs <text>");
      return text(device, value, tree === 'true');
    },
  },
  install: {
    options: { device: { type: 'string' } },
    args: ['apk'],
    run: ({ device }, [apk = '']) => install(device, apk),
  },
  launch: {
    options: { device: { type: 'string' } },
    args: ['package'],
    run: ({ device }, [name = '']) => launch(device, name),
  },
  'open-url': {
    options: { app: { type: 'string' }, device: { type: 'string' } },
    args: ['url'],
    run: ({ app, device }, [url = '']) => openUrl(device, url, app),
  },
  terminate: {
    options: { device: { type: 'string' } },
    args: ['package'],
    run: ({ device }, [name = '']) => terminate(device, name),
  },
  uninstall: {
    options: { device: { type: 'string' } },
    args: ['package'],
    run: ({ device }, [name = '']) => uninstall(device, name),
  },
  logs: {
    options: {
      device: { type: 'string' },
      package: { type: 'string' },
      since: { type: 'string' },
      lines: { type: 'string' },
    },
    args: [],
    run: ({ device, package: name, since, lines }) =>
      logs(
        device,
        name,
        since === undefined ? undefined : seconds('--since', since),
        lines === undefined ? undefined : count('--lines', lines),
      ),
  },
  doctor: { options: {}, args: [], run: () => doctor(), text: async () => doctorText(await doctor()) },
  'install-runner': {
    options: { device: { type: 'string' }, team: { type: 'string' } },
    args: [],
    run: ({ device, team }) => installRunnerOn(device, team),
  },
  'uninstall-runner': {
    options: { device: { type: 'string' } },
    args: [],
    run: ({ device }) => uninstallRunnerFrom(device),
  },
};

// The positional and option checks every caller runs before command.run, in the CLI's order and with its messages.
export function check(
  name: string,
  command: Pick<Command, 'options' | 'args' | 'argsOptional'>,
  values: Record<string, unknown>,
  rest: string[],
): Record<string, string | undefined> {
  if (rest.length > command.args.length) {
    throw new KaragozError('INVALID_ARGS', `unexpected argument '${rest[command.args.length]}'`);
  }
  if (rest.length < command.args.length && !(command.argsOptional && !rest.length)) {
    throw new KaragozError('INVALID_ARGS', `'${name}' needs ${command.args.map((arg) => `<${arg}>`).join(' ')}`);
  }
  const given: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(values)) {
    const option = Object.hasOwn(command.options, key) ? command.options[key] : undefined;
    if (!option) throw new KaragozError('INVALID_ARGS', `'${name}' does not take the option '--${key}'`);
    // The CLI's parseArgs gives a flag as true; the MCP server sends a JSON boolean as 'true' or 'false'.
    if (option.type === 'boolean') {
      if (value !== true && value !== 'true' && value !== 'false') {
        throw new KaragozError('INVALID_ARGS', `option '--${key}' is true or false (got '${String(value)}')`);
      }
      given[key] = String(value);
      continue;
    }
    // parseArgs rejects a missing value but accepts an empty one (--out=).
    if (typeof value !== 'string' || !value) {
      throw new KaragozError('INVALID_ARGS', `option '--${key}' needs a value`);
    }
    given[key] = value;
  }
  return given;
}

// The K5 error envelope for anything a command throws.
export function envelope(err: unknown): { code: ErrorCode; message: string; reason: string | undefined } {
  const message = err instanceof Error ? err.message : String(err);
  const raw = err instanceof Error && 'code' in err ? err.code : undefined;
  const code =
    err instanceof KaragozError
      ? err.code
      : typeof raw === 'string' && raw.startsWith('ERR_PARSE_ARGS')
        ? 'INVALID_ARGS'
        : 'INTERNAL';
  // JSON.stringify drops an undefined reason, so every other envelope stays as it was.
  const reason = err instanceof KaragozError ? err.reason : undefined;
  return { code, message, reason };
}
