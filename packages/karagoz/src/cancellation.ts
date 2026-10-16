import { AsyncLocalStorage } from 'node:async_hooks';

// The MCP server runs each call inside cancellation.run(signal, ...) (K31), the CLI its one command, aborted on SIGINT
// and SIGTERM (K41). Every external process karagoz starts gets this signal.
export const cancellation = new AsyncLocalStorage<AbortSignal>();
