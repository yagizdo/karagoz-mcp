import { AsyncLocalStorage } from 'node:async_hooks';

// The MCP server runs each call inside cancellation.run(signal, ...); the CLI never does, so the store is empty there
// and nothing changes (K31). Every external process karagoz starts gets this signal.
export const cancellation = new AsyncLocalStorage<AbortSignal>();
