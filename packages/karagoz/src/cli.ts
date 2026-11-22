#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { parseArgs, type ParseArgsOptionsConfig } from 'node:util';
import pkg from '../package.json' with { type: 'json' };
import { cancellation } from './cancellation.js';
import { check, commands, envelope } from './commands.js';
import { KaragozError } from './errors.js';
import { refresh, updateCheck } from './update.js';

// Set when a command succeeds: the update notice follows a result, never an error or the MCP server.
let notify = false;

try {
  // One strict parse over the options of every command, so --version and parseArgs' own errors (a missing value)
  // stay the same for all of them. Which options a command takes is checked after the lookup.
  const options: ParseArgsOptionsConfig = { version: { type: 'boolean' } };
  for (const command of Object.values(commands)) Object.assign(options, command.options);
  const { values, positionals } = parseArgs({ options, allowPositionals: true });
  if (process.env.KARAGOZ_UPDATE_REFRESH === '1') {
    // The detached child started below: it only refreshes the cache.
    await refresh();
  } else if (values.version) {
    process.stdout.write(`${pkg.version}\n`);
    notify = true;
  } else {
    const [name, ...rest] = positionals;
    if (!name) {
      throw new KaragozError(
        'NO_COMMAND',
        `no command given. Commands: ${[...Object.keys(commands), 'mcp'].join(', ')}`,
      );
    }
    // mcp is not in the shared table: mcp.ts imports the table, and tools/list would offer mcp (K31).
    if (name === 'mcp') {
      check(name, { options: {}, args: [] }, values, rest);
      // Once serve() resolves, stdout belongs to the SDK's JSON-RPC stream.
      await (await import('./mcp.js')).serve();
    } else {
      // hasOwn: a plain object also answers 'constructor', 'toString' and the rest of Object.prototype.
      const command = Object.hasOwn(commands, name) ? commands[name] : undefined;
      if (!command) throw new KaragozError('UNKNOWN_COMMAND', `unknown command '${name}'`);
      const given = check(name, command, values, rest);
      // Ctrl-C reaches only the terminal's process group, not the iPhone runner's detached start: the abort kills it,
      // then the process exits as the signal would have (K41).
      const controller = new AbortController();
      for (const [signal, code] of [
        ['SIGINT', 130],
        ['SIGTERM', 143],
      ] as const) {
        process.once(signal, () => {
          controller.abort();
          process.exit(code);
        });
      }
      // A person at a terminal gets text or indented JSON; a pipe, an agent's shell and the smokes get one line (K68).
      const tty = process.stdout.isTTY;
      const output = await cancellation.run(controller.signal, async () =>
        tty && command.text
          ? command.text(given, rest)
          : JSON.stringify(await command.run(given, rest), null, tty ? 2 : undefined),
      );
      process.stdout.write(`${output}\n`);
      notify = true;
    }
  }
} catch (err) {
  const error = envelope(err);
  process.stdout.write(`${JSON.stringify({ error })}\n`);
  process.stderr.write(`karagoz: ${error.message}\n`);
  process.exitCode = 1;
}

// Only a person at a terminal: a pipe, an agent's shell and the smokes see no new stderr text (K78).
if (notify && process.stdout.isTTY && process.stderr.isTTY) {
  const update = await updateCheck();
  if (update?.newer) {
    process.stderr.write(
      `karagoz: ${update.newer} is available, you have ${pkg.version}. To update: npm install -g ${pkg.name}\n`,
    );
  }
  // Detached and unreferenced, so the request never holds the exit (measured: under 10 ms, an awaited fetch 0.3-0.7 s).
  if (update?.due) {
    spawn(process.execPath, [process.argv[1] ?? ''], {
      detached: true,
      stdio: 'ignore',
      // Windows gives a detached child its own console window unless hidden.
      windowsHide: true,
      env: { ...process.env, KARAGOZ_UPDATE_REFRESH: '1' },
    }).unref();
  }
}
