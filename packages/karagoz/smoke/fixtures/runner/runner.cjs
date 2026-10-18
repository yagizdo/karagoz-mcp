// The fake runner for smokes 4.3 and 4.4: node runner.cjs <fake dir> <xctestrun>. Like the real one it takes
// KARAGOZ_TOKEN from the .xctestrun's EnvironmentVariables, refuses a request without a valid MAC (401, unsigned) and
// signs every other answer (K42). $fake/runner-mode steers it: old, stranger, squatter and mute change /health; hang,
// close, private and snapshot change /tree; /health answers signed protocol 2 in every other mode.
const http = require("http"), fs = require("fs"), crypto = require("crypto");
const [, , fake, xctestrun] = process.argv;
const env = /<key>EnvironmentVariables<\/key>\s*<dict>([\s\S]*?)<\/dict>/.exec(fs.readFileSync(xctestrun, "utf8"))?.[1] ?? "";
const token = /<key>KARAGOZ_TOKEN<\/key>\s*<string>([0-9a-f]{64})<\/string>/.exec(env)?.[1];
if (!token) {
  console.error("KARAGOZ_TOKEN is missing or malformed");
  process.exit(1);
}
const key = Buffer.from(token, "hex");
const mac = (k, prefix, body) => crypto.createHmac("sha256", k).update(prefix).update(body).digest("hex");
const mode = () => { try { return fs.readFileSync(fake + "/runner-mode", "utf8").trim(); } catch { return "ok"; } };
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    const body = Buffer.concat(chunks);
    const nonce = req.headers["x-karagoz-nonce"] ?? "";
    const m = mode();
    // signer null sends the answer unsigned.
    const answer = (status, json, signer = key) => {
      const out = Buffer.from(JSON.stringify(json));
      const headers = { "Content-Type": "application/json", "Content-Length": out.length };
      if (signer) headers["X-Karagoz-Mac"] = mac(signer, `karagoz-res\n${nonce}\n${status}\n`, out);
      res.writeHead(status, headers);
      res.end(out);
    };
    if (req.url === "/health") {
      if (m === "mute") return;
      if (m === "old") return answer(200, { protocol: 1 }, null);
      if (m === "stranger") return answer(200, { protocol: 2 }, null);
      if (m === "squatter") return answer(200, { protocol: 2 }, crypto.randomBytes(32));
    }
    if (req.headers["x-karagoz-mac"] !== mac(key, `karagoz-req\n${nonce}\n${req.method} ${req.url}\n`, body)) {
      fs.appendFileSync(fake + "/refused", `${req.method} ${req.url}\n`);
      return answer(401, { error: "unauthorized", kind: "auth" }, null);
    }
    if (req.url === "/health") return answer(200, { protocol: 2 });
    fs.appendFileSync(fake + "/trees", "1\n");
    if (m === "hang") return;
    if (m === "close") return req.socket.destroy();
    if (m === "private" || m === "snapshot") {
      return answer(500, { error: m === "private" ? "XCTest has no accessibilityInterface" : "Error kAXErrorIllegalArgument getting snapshot", kind: m });
    }
    answer(200, JSON.parse(fs.readFileSync(fake + "/tree.json", "utf8")));
  });
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(fake + "/runner-port", String(server.address().port)));
