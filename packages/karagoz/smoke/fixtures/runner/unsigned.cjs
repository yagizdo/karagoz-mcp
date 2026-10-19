// node unsigned.cjs <udid>: one GET /health without a signature to karagoz's runner on a USB iPhone, through the real
// usbmuxd; prints the answer's status line, or "refused" when nothing listens. Smoke 4.4's real part expects a 401.
const net = require("net");
const udid = process.argv[2].toUpperCase();
const message = (fields) => {
  const entries = Object.entries({ ProgName: "karagoz-smoke", ...fields })
    .map(([k, v]) => (typeof v === "number" ? `<key>${k}</key><integer>${v}</integer>` : `<key>${k}</key><string>${v}</string>`));
  const body = Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>${entries.join("")}</dict></plist>\n`);
  const head = Buffer.alloc(16);
  head.writeUInt32LE(16 + body.length, 0); head.writeUInt32LE(1, 4); head.writeUInt32LE(8, 8); head.writeUInt32LE(1, 12);
  return Buffer.concat([head, body]);
};
// One usbmuxd exchange: resolves with the open socket and the reply's XML.
const ask = (fields) => new Promise((resolve, reject) => {
  const socket = net.createConnection("/var/run/usbmuxd");
  let buffer = Buffer.alloc(0);
  socket.on("error", reject);
  const data = (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length < 16 || buffer.length < buffer.readUInt32LE(0)) return;
    socket.off("data", data);
    resolve({ socket, xml: buffer.subarray(16, buffer.readUInt32LE(0)).toString() });
  };
  socket.on("data", data);
  socket.write(message(fields));
});
(async () => {
  const { socket: list, xml } = await ask({ MessageType: "ListDevices" });
  list.destroy();
  const pairs = [...xml.matchAll(/<key>DeviceID<\/key>\s*<integer>(\d+)<\/integer>[\s\S]*?<key>SerialNumber<\/key>\s*<string>([^<]+)</g)];
  const id = pairs.find(([, , serial]) => serial.toUpperCase() === udid)?.[1];
  if (id === undefined) return console.log("not on USB");
  const { socket, xml: reply } = await ask({ MessageType: "Connect", DeviceID: Number(id), PortNumber: ((27753 & 0xff) << 8) | (27753 >> 8) });
  if (/<key>Number<\/key>\s*<integer>(\d+)/.exec(reply)?.[1] !== "0") { socket.destroy(); return console.log("refused"); }
  let answer = "";
  socket.on("data", (chunk) => (answer += chunk));
  socket.on("close", () => console.log(answer.split("\r\n")[0]));
  socket.write("GET /health HTTP/1.0\r\nContent-Length: 0\r\n\r\n");
})();
