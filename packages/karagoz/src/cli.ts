#!/usr/bin/env node
import { parseArgs, type ParseArgsOptionsConfig } from 'node:util';
import pkg from '../package.json' with { type: 'json' };
import { check, commands, envelope } from './commands.js';
import { KaragozError } from './errors.js';

try {
  // One strict parse over the options of every command, so --version and parseArgs' own errors (a missing value)
  // stay the same for all of them. Which options a command takes is checked after the lookup.
  const options: ParseArgsOptionsConfig = { version: { type: 'boolean' } };
  for (const command of Object.values(commands)) Object.assign(options, command.options);
  const { values, positionals } = parseArgs({ options, allowPositionals: true });
  if (values.version) {
    process.stdout.write(`${pkg.version}\n`);
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
      process.stdout.write(`${JSON.stringify(await command.run(given, rest))}\n`);
    }
  }
} catch (err) {
  const error = envelope(err);
  process.stdout.write(`${JSON.stringify({ error })}\n`);
  process.stderr.write(`karagoz: ${error.message}\n`);
  process.exitCode = 1;
}
