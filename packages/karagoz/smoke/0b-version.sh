#!/bin/sh
# Step 0b: the built CLI prints the package version, and a bad flag fails with JSON on stdout.
set -e
cd "$(dirname "$0")/.."
npm run --silent build

expected=$(node -p 'require("./package.json").version')
got=$(node dist/cli.js --version)
[ "$got" = "$expected" ] || { echo "FAIL: --version printed '$got', expected '$expected'"; exit 1; }

if out=$(node dist/cli.js --nope 2>/dev/null); then echo "FAIL: unknown flag exited 0"; exit 1; fi
echo "$out" | node -e 'process.exit(JSON.parse(require("fs").readFileSync(0, "utf8")).error.code ? 0 : 1)' \
  || { echo "FAIL: error output is not the JSON envelope: $out"; exit 1; }

echo "ok: karagoz $got"
