// The fake usbmuxd for smoke 4.6, with the iPhone's lockdownd and log relay behind it: node usbmuxd.cjs <socket> <fake
// dir>. ListDevices lists the serials in $fake/usb; ReadPairRecord answers a record made of $fake/cert.pem and key.pem
// ($fake/no-record: none); Connect 62078 reaches lockdownd ($fake/session-error: StartSession's Error;
// $fake/no-service: StartService's), Connect 4242 the relay. The relay appends each request to $fake/requests and
// answers $fake/archive.tar framed as the phone frames it, written in odd slices; $fake/bad-status, $fake/hang (nothing),
// $fake/hang-mid (three chunks, then nothing) and $fake/cut (half the archive, then close) steer it.
const net = require("net"), tls = require("tls"), fs = require("fs");
const [, , path, fake] = process.argv;
const has = (name) => fs.existsSync(`${fake}/${name}`);
const read = (name) => fs.readFileSync(`${fake}/${name}`);
const xml = (body) => `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>${body}</dict></plist>\n`;
const str = (key, value) => `<key>${key}</key><string>${value}</string>`;
const int = (key, value) => `<key>${key}</key><integer>${value}</integer>`;
const tlsOptions = () => ({ isServer: true, key: read("key.pem"), cert: read("cert.pem") });

const usbmux = (body) => {
  const data = Buffer.from(xml(body));
  const head = Buffer.alloc(16);
  head.writeUInt32LE(16 + data.length, 0); head.writeUInt32LE(1, 4); head.writeUInt32LE(8, 8); head.writeUInt32LE(1, 12);
  return Buffer.concat([head, data]);
};
const result = (n) => usbmux(str("MessageType", "Result") + int("Number", n));

// Lockdown frames: a 4-byte big-endian length, then the plist. Calls back with each request's XML.
const frames = (socket, onFrame) => {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32BE(0)) {
      const n = buffer.readUInt32BE(0);
      const body = buffer.subarray(4, 4 + n).toString();
      buffer = buffer.subarray(4 + n);
      onFrame(body);
    }
  });
};
const reply = (socket, body) => {
  const data = Buffer.from(xml(body));
  const head = Buffer.alloc(4);
  head.writeUInt32BE(data.length, 0);
  socket.write(Buffer.concat([head, data]));
};

function lockdown(socket) {
  let secure = null;
  const answer = (request) => {
    const out = secure ?? socket;
    if (request.includes("<string>QueryType</string>")) return reply(out, str("Type", "com.apple.mobile.lockdown"));
    if (request.includes("<string>StartSession</string>")) {
      if (has("session-error")) return reply(out, str("Error", read("session-error").toString().trim()));
      reply(out, str("SessionID", "S1") + "<key>EnableSessionSSL</key><true/>");
      socket.removeAllListeners("data");
      secure = new tls.TLSSocket(socket, tlsOptions());
      secure.on("error", () => {});
      frames(secure, answer);
      return;
    }
    if (request.includes("<string>GetValue</string>")) {
      const clock = has("clock") ? read("clock").toString().trim() : String(Date.now() / 1000);
      return reply(out, `<key>Value</key><real>${clock}</real>`);
    }
    if (request.includes("<string>StartService</string>")) {
      if (has("no-service")) return reply(out, str("Error", "InvalidService"));
      return reply(out, int("Port", 4242) + "<key>EnableServiceSSL</key><true/>");
    }
    reply(out, str("Error", "UnknownRequest"));
  };
  frames(socket, answer);
}

function relay(socket) {
  const secure = new tls.TLSSocket(socket, tlsOptions());
  secure.on("error", () => {});
  frames(secure, (request) => {
    fs.appendFileSync(`${fake}/requests`, request.replace(/\n/g, "") + "\n");
    if (has("hang")) return;
    const status = Buffer.from(has("bad-status") ? "bplist00 Status Failed" : "bplist00 Status RequestSuccessful");
    const head = Buffer.alloc(5);
    head[0] = 1;
    head.writeUInt32BE(status.length, 1);
    const tar = read("archive.tar");
    const chunks = [Buffer.concat([head, status])];
    for (let at = 0; at < tar.length; at += 10240) {
      const data = tar.subarray(at, at + 10240);
      const frame = Buffer.alloc(5);
      frame[0] = 3;
      frame.writeUInt32LE(data.length, 1);
      chunks.push(frame, data);
    }
    let stream = Buffer.concat(chunks);
    if (has("cut")) stream = stream.subarray(0, Math.floor(stream.length / 2));
    if (has("hang-mid")) stream = stream.subarray(0, Buffer.concat(chunks.slice(0, 7)).length);
    for (let at = 0; at < stream.length; at += 7001) secure.write(stream.subarray(at, at + 7001));
    if (!has("hang-mid")) secure.end();
  });
}

net.createServer((socket) => {
  let buffer = Buffer.alloc(0);
  socket.on("error", () => {});
  const data = (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length < 16 || buffer.length < buffer.readUInt32LE(0)) return;
    socket.off("data", data);
    const request = buffer.subarray(16, buffer.readUInt32LE(0)).toString();
    if (request.includes("<string>ListDevices</string>")) {
      const entries = fs.readFileSync(fake + "/usb", "utf8").split(/\s+/).filter(Boolean);
      const list = entries.map((serial, i) =>
        `<dict>${int("DeviceID", i + 7)}<key>Properties</key><dict>${str("ConnectionType", "USB")}${int("DeviceID", i + 7)}${str("SerialNumber", serial)}</dict></dict>`);
      return socket.end(usbmux(`<key>DeviceList</key><array>${list.join("")}</array>`));
    }
    if (request.includes("<string>ReadPairRecord</string>")) {
      if (has("no-record")) return socket.end(result(2));
      const record = xml(str("HostID", "FAKE-HOST-ID-4242") + str("SystemBUID", "FAKE-SYSTEM-BUID-4242") +
        `<key>HostCertificate</key><data>${read("cert.pem").toString("base64")}</data>` +
        `<key>HostPrivateKey</key><data>${read("key.pem").toString("base64")}</data>`);
      return socket.end(usbmux(`<key>PairRecordData</key><data>\n${Buffer.from(record).toString("base64")}\n</data>`));
    }
    const swapped = Number(/<key>PortNumber<\/key><integer>(\d+)<\/integer>/.exec(request)[1]);
    const port = ((swapped & 0xff) << 8) | (swapped >> 8);
    fs.appendFileSync(fake + "/connects", `${port}\n`);
    socket.write(result(0));
    if (port === 62078) lockdown(socket);
    else if (port === 4242) relay(socket);
    else socket.destroy();
  };
  socket.on("data", data);
}).listen(path);
