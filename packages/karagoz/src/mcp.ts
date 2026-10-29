import { readFile } from 'node:fs/promises';
import { ProtocolError, ProtocolErrorCode, Server, type CallToolResult, type Tool } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import pkg from '../package.json' with { type: 'json' };
import { check, commands, envelope } from './commands.js';
import { cancellation } from './cancellation.js';
import { KaragozError } from './errors.js';

const INSTRUCTIONS =
  'karagoz drives Android emulators and phones, and iOS simulators and iPhones on macOS. To see the screen, call ui_tree first: node bounds are the pixels tap and swipe take; take a screenshot only when you need the image. Pass device only when more than one device is connected. Each result is one JSON object; on failure, branch on error.code. If adb or Xcode is missing, old or broken, call doctor.';

const device = { type: 'string', description: 'Id or name.' };

const TOOLS: Tool[] = [
  {
    name: 'devices',
    title: 'List devices',
    description: 'List Android devices and emulators, running iOS simulators, and iPhones connected to this Mac.',
    inputSchema: { type: 'object', properties: {} },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: 'screenshot',
    title: 'Take a screenshot',
    description:
      'Save a full-resolution PNG of the screen and return its path with size, scale and safe area. Use ui_tree to read the screen; inline only to look at the image.',
    inputSchema: {
      type: 'object',
      properties: {
        device,
        out: { type: 'string', description: 'Absolute PNG path, ending in .png. Default: a new temp file.' },
        inline: {
          type: 'boolean',
          description: 'Also return the image. Take coordinates from ui_tree, not from the image.',
        },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'ui_tree',
    title: 'Read the UI tree',
    description:
      "Return the focused window's accessibility tree as JSON. Node bounds [left, top, right, bottom] are the physical pixels tap and swipe take. On an iPhone it needs karagoz's runner: install it once with install_runner.",
    inputSchema: { type: 'object', properties: { device } },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: 'tap',
    title: 'Tap',
    description:
      'Tap x, y in physical pixels, or the center of the node whose text or contentDesc (iOS: label or value) equals text, or whose resource id (iOS: identifier) matches id. duration makes it a long press. An iPhone needs install_runner once.',
    inputSchema: {
      type: 'object',
      properties: {
        x: { type: 'number' },
        y: { type: 'number' },
        text: { type: 'string', description: 'Exact text or contentDesc (iOS: label or value), case-sensitive.' },
        id: { type: 'string', description: 'Resource id, full or the part after :id/ (iOS: identifier).' },
        duration: { type: 'integer', description: 'Hold time in ms.' },
        timeout: {
          type: 'integer',
          description:
            'With text or id: ms to keep reading the tree until the node appears; the call can run up to 6 s longer.',
        },
        device,
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'swipe',
    title: 'Swipe',
    description: 'Swipe from x1, y1 to x2, y2 in physical pixels. An iPhone needs install_runner once.',
    inputSchema: {
      type: 'object',
      properties: {
        x1: { type: 'number' },
        y1: { type: 'number' },
        x2: { type: 'number' },
        y2: { type: 'number' },
        duration: { type: 'integer', description: 'ms from start to end. Default 300.' },
        device,
      },
      required: ['x1', 'y1', 'x2', 'y2'],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'text',
    title: 'Type text',
    description:
      'Type into the focused field. Any text; on Android, text beyond ASCII is pasted through the clipboard and the old clip put back. An iPhone needs install_runner once.',
    inputSchema: { type: 'object', properties: { text: { type: 'string' }, device }, required: ['text'] },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'key',
    title: 'Press a key',
    description: 'Press one key.',
    inputSchema: {
      type: 'object',
      properties: {
        key: {
          type: 'string',
          description:
            'KeyEvent name (HOME, BACK, KEYCODE_7) or code 1-340; "7" is code 7 (KEYCODE_0), not the digit. iOS takes HOME, POWER, VOLUME_UP/DOWN and keyboard keys; an iPhone only keys that type a character, and needs install_runner once.',
        },
        device,
      },
      required: ['key'],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'install',
    title: 'Install an app',
    description:
      'Install an .apk, or a .app or .ipa on an iOS simulator or iPhone, or replace the installed version of the same app. An iPhone takes only a build signed for it; karagoz does not re-sign. Times out after 30 s plus 1 s per MB.',
    inputSchema: {
      type: 'object',
      properties: { apk: { type: 'string', description: 'Absolute path to the .apk, .app or .ipa.' }, device },
      required: ['apk'],
    },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  },
  {
    name: 'launch',
    title: 'Launch an app',
    description: 'Start an app as its launcher icon does. On iOS it returns before the app is in front.',
    inputSchema: { type: 'object', properties: { package: { type: 'string' }, device }, required: ['package'] },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'terminate',
    title: 'Stop an app',
    description: 'Force-stop every process of an app.',
    inputSchema: { type: 'object', properties: { package: { type: 'string' }, device }, required: ['package'] },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  {
    name: 'uninstall',
    title: 'Uninstall an app',
    description: 'Remove an app.',
    inputSchema: { type: 'object', properties: { package: { type: 'string' }, device }, required: ['package'] },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  },
  {
    name: 'logs',
    title: 'Read device logs',
    description:
      'Read the newest device log records, oldest first. On iOS without since: the last minute, or the last hour with package. An iPhone read takes about 10 s.',
    inputSchema: {
      type: 'object',
      properties: {
        package: { type: 'string', description: "Only this app's records." },
        since: {
          type: 'number',
          description: "Unix seconds on the device clock; only later records. Pass a record's time to continue.",
        },
        lines: { type: 'integer', description: 'Number of newest records. Default 30.' },
        device,
      },
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: 'doctor',
    title: 'Check adb and Xcode',
    description:
      'Report which adb and Xcode tools karagoz uses, their versions, and how to fix one that is missing, old or broken.',
    inputSchema: { type: 'object', properties: {} },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: 'install_runner',
    title: "Install karagoz's iPhone runner",
    description:
      "Build karagoz's runner with your Apple team and install it on a paired iPhone over USB; ui_tree, tap, swipe, text and key need it there.",
    inputSchema: {
      type: 'object',
      properties: {
        device,
        team: { type: 'string', description: 'Apple team ID; needed only when Xcode lists several.' },
      },
    },
    // The build registers the iPhone and an App ID with Apple's developer service.
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
  },
  {
    name: 'uninstall_runner',
    title: "Remove karagoz's iPhone runner",
    description: "Remove karagoz's runner and its provisioning profile from an iPhone.",
    inputSchema: { type: 'object', properties: { device } },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  },
];

// Tool name to command name. A Map: the name is client input (ui_tree is the CLI's ui-tree).
const COMMANDS = new Map(TOOLS.map(({ name }) => [name, name.replace('_', '-')]));

// A JSON argument as the CLI would get it: 12.5 is '12.5'. An object keeps its JSON, which every command's checks refuse.
function plain(value: unknown): string {
  return typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean'
    ? String(value)
    : JSON.stringify(value);
}

export async function serve(): Promise<void> {
  // The low-level server, not McpServer, which pulls zod's full API (+450 KB minified) (K14). Its @deprecated tag is
  // expected.
  const server = new Server(
    { name: 'karagoz', version: pkg.version },
    { capabilities: { tools: {} }, instructions: INSTRUCTIONS },
  );
  server.setRequestHandler('tools/list', () => ({ tools: TOOLS }));
  server.setRequestHandler('tools/call', async (request, ctx) => {
    const { name } = request.params;
    const key = COMMANDS.get(name);
    const command = key === undefined ? undefined : commands[key];
    if (key === undefined || !command) {
      throw new ProtocolError(ProtocolErrorCode.InvalidParams, `Unknown tool: ${name}`);
    }
    // Every failure past the lookup is a result with isError, never a throw: the SDK would send a thrown error as
    // -32603 with a bare message (K31).
    try {
      let inline = false;
      const given = new Map<string, string>();
      // null counts as not given, as a missing argument does.
      for (const [arg, value] of Object.entries(request.params.arguments ?? {})) {
        if (value === null) continue;
        if (key === 'screenshot' && arg === 'inline') {
          if (typeof value !== 'boolean') {
            throw new KaragozError('INVALID_ARGS', `inline must be true or false (got '${plain(value)}')`);
          }
          inline = value;
        } else {
          given.set(arg, plain(value));
        }
      }
      // The command's own checks see what the CLI would: positionals in order, every other argument as an option.
      const rest = command.args.flatMap((arg) => given.get(arg) ?? []);
      const values = Object.fromEntries([...given].filter(([arg]) => !command.args.includes(arg)));
      const checked = check(key, command, values, rest);
      const result = await cancellation.run(ctx.mcpReq.signal, () => command.run(checked, rest));
      const content: CallToolResult['content'] = [{ type: 'text', text: JSON.stringify(result) }];
      if (
        inline &&
        typeof result === 'object' &&
        result !== null &&
        'path' in result &&
        typeof result.path === 'string'
      ) {
        content.push({ type: 'image', mimeType: 'image/png', data: (await readFile(result.path)).toString('base64') });
      }
      return { content };
    } catch (err) {
      // The SDK drops the response of a cancelled call, so nothing is logged for it either.
      if (ctx.mcpReq.signal.aborted) throw err;
      const error = envelope(err);
      process.stderr.write(`karagoz: ${error.message}\n`);
      return { content: [{ type: 'text', text: JSON.stringify({ error }) }], isError: true };
    }
  });
  await server.connect(new StdioServerTransport());
  // close() aborts every call's signal synchronously, which kills its adb child; without a handler the signal kills
  // the process and leaves adb running (K31). stdin close needs nothing: the SDK aborts and the process exits.
  for (const [signal, code] of [
    ['SIGINT', 130],
    ['SIGTERM', 143],
  ] as const) {
    process.once(signal, () => {
      void server.close();
      process.exit(code);
    });
  }
}
