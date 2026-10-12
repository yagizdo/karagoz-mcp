import { execFile } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { access, constants, lstat, mkdir, readFile, readlink, rename, rm } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { cancellation } from '../../cancellation.js';
import { KaragozError } from '../../errors.js';
import { rotation } from './devicectl.js';
import { isRecord } from './devices.js';
import { panelScale } from './screenshot.js';
import { developerDir } from './simctl.js';

const run = promisify(execFile);

// 2.8 s measured warm; a cold module cache on a slow Mac can take far longer (K34).
const COMPILE_TIMEOUT_MS = 120_000;
// simctl's timeout: the first call after login starts CoreSimulatorService (K32). A read takes ~0.1 s.
const RUN_TIMEOUT_MS = 30_000;
// Node's 1 MiB default would cut a long list's tree.
const MAX_BUFFER = 32 * 1024 * 1024;
// Pinned so a toolchain that changes its default language mode cannot break the build.
const FLAGS = ['-O', '-suppress-warnings', '-swift-version', '5'];
const XCODE_SELECT = '/var/db/xcode_select_link';
// The build copies the source next to the bundle's chunks, all flat in dist/.
const SOURCE = fileURLToPath(new URL('ax-helper.swift', import.meta.url));
const CACHE_HINT = 'delete ~/Library/Caches/karagoz';

export type IosNode = {
  role: string;
  label?: string;
  identifier?: string;
  value?: string;
  focused?: true;
  selected?: true;
  enabled?: false;
  bounds: number[];
  children?: IosNode[];
};

let source: Promise<string> | undefined;

async function xcode(): Promise<string> {
  const dev = developerDir();
  if (dev) return dev;
  try {
    return await readlink(XCODE_SELECT);
  } catch {
    // Any readlink failure means no Xcode is selected; the message says how to pick one.
    throw new KaragozError(
      'HELPER_FAILED',
      `no Xcode selected: set DEVELOPER_DIR or run xcode-select -s <Xcode.app> (${XCODE_SELECT} is missing)`,
    );
  }
}

// The cache sits in the user's home, but a directory or binary someone else owns there is refused, as screenshot
// refuses a shared temp directory (src/screenshot.ts).
const owned = (info: { uid: number }) => !process.getuid || info.uid === process.getuid();

// The binary for this source, Xcode and architecture, compiled on first use (K34). The key is computed on every call,
// so an Xcode update or a new karagoz compiles again within the same MCP server.
async function helper(dev: string): Promise<string> {
  source ??= readFile(SOURCE, 'utf8');
  const text = await source.catch(() => {
    throw new KaragozError('HELPER_FAILED', `cannot read ${SOURCE}; reinstall karagoz`);
  });
  // A missing version.plist leaves the build out of the key; the developer dir is still in it.
  const plist = await readFile(join(dev, '..', 'version.plist'), 'utf8').catch(() => '');
  const build = /<key>ProductBuildVersion<\/key>\s*<string>([^<]*)<\/string>/.exec(plist)?.[1] ?? '';
  const key = createHash('sha256')
    .update([text, dev, build, process.arch, FLAGS.join(' ')].join('\0'))
    .digest('hex')
    .slice(0, 16);
  const root = join(homedir(), 'Library', 'Caches', 'karagoz');
  const dir = join(root, key);
  const bin = join(dir, 'ax');
  try {
    await mkdir(dir, { recursive: true, mode: 0o700 });
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    throw new KaragozError('HELPER_FAILED', err.message);
  }
  for (const path of [root, dir]) {
    const info = await lstat(path);
    if (!info.isDirectory() || !owned(info)) {
      throw new KaragozError('HELPER_FAILED', `${path} is not a directory owned by the current user; ${CACHE_HINT}`);
    }
  }
  const existing = await lstat(bin).catch(() => undefined);
  if (existing) {
    if (!existing.isFile() || !owned(existing)) {
      throw new KaragozError('HELPER_FAILED', `${bin} is not a file owned by the current user; ${CACHE_HINT}`);
    }
    return bin;
  }

  const compiler = join(dev, 'Toolchains', 'XcodeDefault.xctoolchain', 'usr', 'bin', 'swiftc');
  try {
    await access(compiler, constants.X_OK);
  } catch {
    // Not there or not runnable: either way this developer dir cannot compile the helper.
    throw new KaragozError(
      'HELPER_FAILED',
      `swiftc not found at ${compiler}; install Xcode, the Command Line Tools are not enough`,
    );
  }
  const sdk = join(dev, 'Platforms', 'MacOSX.platform', 'Developer', 'SDKs', 'MacOSX.sdk');
  // A unique name and a rename: two first calls never run a half-written binary, and the slower one just replaces it.
  const tmp = join(dir, `ax.${process.pid}.${randomUUID()}.tmp`);
  const signal = cancellation.getStore();
  signal?.throwIfAborted();
  try {
    await run(compiler, [...FLAGS, '-sdk', sdk, SOURCE, '-o', tmp], {
      timeout: COMPILE_TIMEOUT_MS,
      ...(signal && { signal }),
    });
    await rename(tmp, bin);
  } catch (err) {
    // The SDK sends no response for a cancelled call, so the abort passes through (K31).
    if (signal?.aborted) throw err;
    if (!(err instanceof Error)) throw err;
    if ('killed' in err && err.killed) {
      throw new KaragozError('HELPER_FAILED', `swiftc did not finish within ${COMPILE_TIMEOUT_MS / 1000} s`);
    }
    const stderr = 'stderr' in err && typeof err.stderr === 'string' ? err.stderr.trim() : '';
    throw new KaragozError('HELPER_FAILED', (stderr || err.message).slice(0, 300));
  } finally {
    await rm(tmp, { force: true });
  }
  return bin;
}

// Exit codes and stderr per the contract at the top of ax-helper.swift.
async function read(bin: string, dev: string, udid: string): Promise<string> {
  const signal = cancellation.getStore();
  signal?.throwIfAborted();
  try {
    return (await run(bin, [dev, udid], { timeout: RUN_TIMEOUT_MS, maxBuffer: MAX_BUFFER, ...(signal && { signal }) }))
      .stdout;
  } catch (err) {
    if (signal?.aborted) throw err;
    if (!(err instanceof Error)) throw err;
    const stderr = 'stderr' in err && typeof err.stderr === 'string' ? err.stderr.trim().slice(0, 300) : '';
    const code = 'code' in err ? err.code : undefined;
    if ('killed' in err && err.killed) {
      throw new KaragozError('CAPTURE_FAILED', `the simulator did not answer within ${RUN_TIMEOUT_MS / 1000} s`);
    }
    if (typeof code === 'string' && code.startsWith('ERR_CHILD_PROCESS_STDIO_MAXBUFFER')) {
      throw new KaragozError('CAPTURE_FAILED', `the tree is larger than ${MAX_BUFFER / 1024 / 1024} MiB`);
    }
    if (code === 2) {
      throw new KaragozError(
        'HELPER_FAILED',
        `${stderr}; this Xcode changed a private interface karagoz uses; update karagoz`,
      );
    }
    if (code === 3) throw new KaragozError('CAPTURE_FAILED', stderr || 'the helper could not read this screen');
    if ('signal' in err && typeof err.signal === 'string') {
      throw new KaragozError('HELPER_FAILED', `the helper crashed (${err.signal})`);
    }
    if (code === 'EACCES' || code === 'ENOENT') {
      throw new KaragozError('HELPER_FAILED', `cannot run ${bin} (${code}); ${CACHE_HINT}`);
    }
    throw new KaragozError('HELPER_FAILED', stderr || err.message.slice(0, 300));
  }
}

const text = (value: unknown) => (typeof value === 'string' && value !== '' ? value : undefined);
const round = (value: number) => Math.round(value * 100) / 100;

// One helper node to K24's skeleton with iOS names; frames are points, bounds are screenshot pixels (K34).
function node(raw: unknown, scale: number): IosNode {
  if (!isRecord(raw) || typeof raw.role !== 'string') throw new Error('a node has no role');
  const frame = Array.isArray(raw.frame)
    ? raw.frame.filter((n: unknown): n is number => typeof n === 'number' && Number.isFinite(n))
    : [];
  if (frame.length !== 4) throw new Error('a node has no frame');
  const [x = 0, y = 0, width = 0, height = 0] = frame;
  if (raw.children !== undefined && !Array.isArray(raw.children)) throw new Error('children is not a list');
  const children = Array.isArray(raw.children) ? raw.children.map((child: unknown) => node(child, scale)) : [];
  const label = text(raw.label);
  const identifier = text(raw.identifier);
  const value = text(raw.value);
  return {
    role: (text(raw.subrole) ?? raw.role).replace(/^AX/, ''),
    ...(label && { label }),
    ...(identifier && { identifier }),
    ...(value && { value }),
    ...(raw.focused === true && { focused: true }),
    ...(raw.selected === true && { selected: true }),
    ...(raw.enabled === false && { enabled: false }),
    bounds: [x, y, x + width, y + height].map((v) => round(v * scale)),
    ...(children.length > 0 && { children }),
  };
}

function parse(stdout: string): IosNode {
  try {
    const parsed: unknown = JSON.parse(stdout);
    const screen = isRecord(parsed) ? parsed.screen : undefined;
    if (!isRecord(screen)) throw new Error('no screen');
    const { width, height, scale } = screen;
    if (typeof width !== 'number' || typeof height !== 'number' || typeof scale !== 'number' || !(scale > 0)) {
      throw new Error('no screen size or scale');
    }
    return node(isRecord(parsed) ? parsed.root : undefined, panelScale(width, height, scale));
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    throw new KaragozError('CAPTURE_FAILED', `cannot parse the helper's output: ${err.message}`);
  }
}

// The frontmost app of a booted simulator. The compile runs first, so HELPER_FAILED wins over a read failure.
export async function readTree(udid: string): Promise<{ rotation: number | null; root: IosNode }> {
  const dev = await xcode();
  const bin = await helper(dev);
  const [stdout, rotated] = await Promise.all([read(bin, dev, udid), rotation(udid)]);
  return { rotation: rotated, root: parse(stdout) };
}
