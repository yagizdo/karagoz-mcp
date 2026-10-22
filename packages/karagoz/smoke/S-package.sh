#!/bin/sh
# Step S: the package is ready to publish. npm pack takes only what a user runs (dist/, README, LICENSE and the
# third-party notices), package.json and the repository's server.json carry the npm and MCP Registry fields and agree on
# name and version, and THIRD_PARTY_NOTICES.txt has one section per package in the bundle, at the bundled version.
# Precondition: none, no device. npm pack's prepack rebuilds dist/ and copies the gitignored README.md and LICENSE into
# the package folder; everything else goes to a temporary folder.
set -e
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'set +e; rm -rf "$tmp"' EXIT

# --dry-run still runs prepack, which builds; npm's script banners and esbuild's summary go to stderr.
npm pack --dry-run --json > "$tmp/pack.json" 2> "$tmp/pack.err" || {
  cat "$tmp/pack.err"
  echo "FAIL: npm pack --dry-run exited non-zero"
  exit 1
}
# The bundle's inputs: only the metafile is used, so the flags that change the output's form are left out.
../../node_modules/.bin/esbuild src/cli.ts --bundle --platform=node --format=esm --splitting --outdir="$tmp/bundle" \
  --metafile="$tmp/meta.json" --log-level=error

node -e '
const fs = require("fs");
const [packFile, metaFile] = process.argv.slice(1);
const fail = (message) => { console.log(`FAIL: ${message}`); process.exit(1); };
const read = (path) => JSON.parse(fs.readFileSync(path, "utf8"));

let pack;
try { [pack] = read(packFile); } catch { fail("npm pack --json printed no JSON on stdout"); }
const files = pack.files.map((file) => file.path);
const fixed = ["package.json", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.txt", "dist/cli.js", "dist/ax-helper.swift"];
const chunk = /^dist\/chunk-[A-Z0-9]+\.js$/;
const server = /^dist\/mcp-[A-Z0-9]+\.js$/;
const extra = files.filter((p) => !fixed.includes(p) && !chunk.test(p) && !server.test(p) && !p.startsWith("dist/ios-runner/"));
if (extra.length) fail(`the tarball would also hold ${extra.length} other files: ${extra.slice(0, 5).join(", ")}`);
for (const p of fixed) if (!files.includes(p)) fail(`the tarball lacks ${p}`);
if (files.filter((p) => chunk.test(p)).length !== 1 || files.filter((p) => server.test(p)).length !== 1) {
  fail(`expected one dist/chunk-*.js and one dist/mcp-*.js, got ${files.filter((p) => p.startsWith("dist/") && p.endsWith(".js")).join(", ")}`);
}
if (!files.some((p) => p.startsWith("dist/ios-runner/KaragozRunner.xcodeproj/"))) fail("the tarball lacks the runner project");

const pkg = read("package.json");
const want = {
  name: "karagoz-mcp",
  bin: { karagoz: "dist/cli.js" },
  mcpName: "io.github.yagizdo/karagoz-mcp",
  files: ["dist", "THIRD_PARTY_NOTICES.txt"],
  directory: "packages/karagoz",
};
const got = { name: pkg.name, bin: pkg.bin, mcpName: pkg.mcpName, files: pkg.files, directory: pkg.repository?.directory };
if (JSON.stringify(got) !== JSON.stringify(want)) fail(`package.json fields: ${JSON.stringify(got)}`);

const entry = read("../../server.json");
const [npm, ...others] = entry.packages ?? [];
if (entry.name !== pkg.mcpName) fail(`server.json name ${entry.name} is not mcpName ${pkg.mcpName}`);
if (entry.version !== pkg.version || npm?.version !== pkg.version) {
  fail(`server.json versions ${entry.version} and ${npm?.version}, package.json ${pkg.version}`);
}
if (others.length || npm.registryType !== "npm" || npm.identifier !== pkg.name || npm.transport?.type !== "stdio") {
  fail(`server.json packages: ${JSON.stringify(entry.packages)}`);
}
if (JSON.stringify(npm.packageArguments) !== JSON.stringify([{ type: "positional", value: "mcp" }])) {
  fail(`server.json packageArguments: ${JSON.stringify(npm.packageArguments)}`);
}
if (typeof entry.description !== "string" || !entry.description || entry.description.length > 100) {
  fail(`server.json description must be 1-100 characters: ${JSON.stringify(entry.description)}`);
}

// Installed packages the bundle imports, and those the MCP SDK bundled into its own files, named by the pnpm paths
// its build left in them.
const inputs = Object.keys(read(metaFile).inputs).filter((p) => p.includes("node_modules/"));
const bundled = new Set();
for (const name of new Set(inputs.map((p) => /node_modules\/((?:@[^/]+\/)?[^/]+)/.exec(p)[1]))) {
  bundled.add(`${name}@${read(`../../node_modules/${name}/package.json`).version}`);
}
for (const p of inputs.filter((p) => p.includes("/@modelcontextprotocol/"))) {
  for (const [, name, version] of fs.readFileSync(p, "utf8").matchAll(/node_modules\/\.pnpm\/([^@/]+)@(\d[^/_]*)/g)) {
    bundled.add(`${name}@${version}`);
  }
}
const notices = fs.readFileSync("THIRD_PARTY_NOTICES.txt", "utf8");
const listed = new Set([...notices.matchAll(/^(@?[^@\s]+@\d\S*) \([^)]+\)$/gm)].map(([, id]) => id));
const missing = [...bundled].filter((id) => !listed.has(id));
const stale = [...listed].filter((id) => !bundled.has(id));
if (missing.length || stale.length) {
  fail(`THIRD_PARTY_NOTICES.txt lacks ${missing.join(", ") || "nothing"} and lists ${stale.join(", ") || "nothing"} not bundled`);
}
console.log(`ok: ${files.length} files, ${pack.size} bytes packed, ${bundled.size} bundled packages noticed, server.json ${entry.version}`);
' "$tmp/pack.json" "$tmp/meta.json"
