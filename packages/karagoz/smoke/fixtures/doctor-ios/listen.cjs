// A Unix socket that only counts connections: smoke 3.7 checks doctor never connects to usbmuxd (K30 4.7).
// Usage: node listen.cjs <socket> <count file>
const { appendFileSync } = require('node:fs');
const { createServer } = require('node:net');

const [socket, count] = process.argv.slice(2);
const server = createServer((connection) => {
  appendFileSync(count, 'connect\n');
  connection.destroy();
}).listen(socket);
process.on('SIGTERM', () => server.close(() => process.exit(0)));
