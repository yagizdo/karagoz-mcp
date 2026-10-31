#!/bin/sh
# Step C: `npm run mcpb` packs the Claude Desktop extension karagoz.mcpb. It holds only dist/, package.json,
# manifest.json and the license files; manifest.json carries package.json's version; the server it starts the way a
# host does (the mcpb library's own config builder, no user settings, cwd /, a short PATH) gets an empty ANDROID_HOME,
# which doctor reports as unset, and lists the 18 tools.
# Precondition: none, no device. The pack rebuilds dist/ and copies the gitignored README.md and LICENSE into the
# package folder, like npm pack; the extension is unpacked into a temporary folder.
set -e
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'set +e; rm -rf "$tmp"' EXIT

npm run --silent mcpb > "$tmp/pack.log" 2>&1 || { cat "$tmp/pack.log"; echo "FAIL: npm run mcpb exited non-zero"; exit 1; }
unzip -q karagoz.mcpb -d "$tmp/ext"

node --input-type=module -e '
import fs from "node:fs";
import { spawn } from "node:child_process";
import { getMcpConfigForManifest } from "@anthropic-ai/mcpb";
const ext = process.argv[1];
const fail = (message) => { console.log(`FAIL: ${message}`); process.exit(1); };

const files = fs.readdirSync(ext, { recursive: true }).filter((p) => fs.statSync(`${ext}/${p}`).isFile());
const fixed = ["package.json", "manifest.json", "LICENSE", "THIRD_PARTY_NOTICES.txt", "dist/cli.js", "dist/ax-helper.swift", "dist/text-helper.jar"];
const extra = files.filter((p) => !fixed.includes(p) && !/^dist\/(chunk|mcp)-[A-Z0-9]+\.js$/.test(p) && !p.startsWith("dist/ios-runner/"));
if (extra.length) fail(`the extension also holds ${extra.join(", ")}`);
for (const p of fixed) if (!files.includes(p)) fail(`the extension lacks ${p}`);

const manifest = JSON.parse(fs.readFileSync(`${ext}/manifest.json`, "utf8"));
const { version } = JSON.parse(fs.readFileSync("package.json", "utf8"));
if (manifest.version !== version) fail(`manifest.json version ${manifest.version}, package.json ${version}`);

const config = await getMcpConfigForManifest({ manifest, extensionPath: ext, systemDirs: {}, userConfig: {}, pathSeparator: "/" });
if (config?.env?.ANDROID_HOME !== "") fail(`ANDROID_HOME with no user settings: ${JSON.stringify(config?.env)}`);
const command = config.command === "node" ? process.execPath : config.command;
const server = spawn(command, config.args, { cwd: "/", env: { PATH: "/usr/bin:/bin", HOME: process.env.HOME, ...config.env } });
const replies = new Map();
let buffer = "";
server.stdout.on("data", (chunk) => {
  buffer += chunk;
  for (let at; (at = buffer.indexOf("\n")) >= 0; buffer = buffer.slice(at + 1)) {
    const message = JSON.parse(buffer.slice(0, at));
    replies.get(message.id)?.(message);
  }
});
let next = 0;
const request = (method, params) => new Promise((resolve) => {
  const id = ++next;
  replies.set(id, resolve);
  server.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
});
const timer = setTimeout(() => fail("the server did not answer within 60 s"), 60_000);
await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "smoke", version: "0" } });
server.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
const { result } = await request("tools/list", {});
if (result?.tools?.length !== 18) fail(`tools/list: ${result?.tools?.length} tools`);
const doctor = JSON.parse((await request("tools/call", { name: "doctor", arguments: {} })).result.content[0].text);
const first = JSON.stringify(doctor.adb.candidates[0]);
if (first !== JSON.stringify({ source: "ANDROID_HOME", status: "unset" })) fail(`doctor ANDROID_HOME: ${first}`);
clearTimeout(timer);
server.stdin.end();
const code = await new Promise((resolve) => server.on("exit", resolve));
if (code !== 0) fail(`the server exited ${code}`);
console.log(`ok: ${files.length} files, manifest ${manifest.version}, 18 tools, ANDROID_HOME unset`);
' "$tmp/ext"
