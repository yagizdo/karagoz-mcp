// The fake usbmuxd for smokes 4.3 and 4.4: node usbmuxd.cjs <socket> <fake dir>. It lists the phones in $fake/usb
// (serial[:connection type]) and forwards Connect to the fake runner's port, or answers 3 (refused) when nothing listens
// and 2 (no such device) when $fake/gone exists.
const net = require("net"), fs = require("fs");
const [, , path, fake] = process.argv;
const frame = (body) => {
  const xml = Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>${body}</dict></plist>\n`);
  const head = Buffer.alloc(16);
  head.writeUInt32LE(16 + xml.length, 0); head.writeUInt32LE(1, 4); head.writeUInt32LE(8, 8); head.writeUInt32LE(1, 12);
  return Buffer.concat([head, xml]);
};
const result = (n) => frame(`<key>MessageType</key><string>Result</string><key>Number</key><integer>${n}</integer>`);
net.createServer((socket) => {
  let buffer = Buffer.alloc(0);
  socket.on("error", () => {});
  const data = (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length < 16 || buffer.length < buffer.readUInt32LE(0)) return;
    socket.off("data", data);
    const xml = buffer.subarray(16, buffer.readUInt32LE(0)).toString();
    if (xml.includes("<string>ListDevices</string>")) {
      const entries = fs.readFileSync(fake + "/usb", "utf8").split(/\s+/).filter(Boolean);
      const list = entries.map((entry, i) => {
        const [serial, type = "USB"] = entry.split(":");
        return `<dict><key>DeviceID</key><integer>${i + 7}</integer><key>MessageType</key><string>Attached</string><key>Properties</key><dict><key>ConnectionType</key><string>${type}</string><key>DeviceID</key><integer>${i + 7}</integer><key>SerialNumber</key><string>${serial}</string></dict></dict>`;
      });
      return socket.end(frame(`<key>DeviceList</key><array>${list.join("")}</array>`));
    }
    const swapped = Number(/<key>PortNumber<\/key><integer>(\d+)<\/integer>/.exec(xml)[1]);
    fs.appendFileSync(fake + "/connects", `${((swapped & 0xff) << 8) | (swapped >> 8)}\n`);
    if (fs.existsSync(fake + "/gone")) return socket.end(result(2));
    let port = 0;
    try { port = Number(fs.readFileSync(fake + "/runner-port", "utf8")); } catch {}
    if (!port) return socket.end(result(3));
    const runner = net.connect(port, "127.0.0.1");
    runner.on("error", () => socket.end(result(3)));
    runner.on("connect", () => { socket.write(result(0)); socket.pipe(runner); runner.pipe(socket); });
  };
  socket.on("data", data);
}).listen(path);
