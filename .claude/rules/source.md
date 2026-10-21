---
paths:
  - "packages/karagoz/src/**/*.ts"
---

# Source

Paths are relative to `packages/karagoz/src/`. Where a file goes and what it may import is in `AGENTS.md`, `## Code layout`.

- Look up a user-supplied key (command names, key names, device aliases, MCP tool names) with `Object.hasOwn(obj, key)` or a `Map`, never a bare `obj[key]` on a plain object. A plain object also answers `Object.prototype` members: `karagoz constructor` ran `Object()` and exited 0. The `hasOwn` line in `cli.ts` is the pattern.
- Never spawn a tool by bare name on Windows. libuv searches the current directory before PATH, so an `.exe` in the directory the user runs karagoz from wins. Walk the absolute PATH entries, as `onPath()` in `drivers/android/adb.ts` does; POSIX keeps the bare name.
- Run an Xcode tool from its absolute path, never through `xcrun` or a `/usr/bin` shim. The shim can open an install dialog or run `xcodebuild -runFirstLaunch`, which hangs without a terminal (K32). `binary()` in `drivers/ios/simctl.ts` is the pattern; `/usr/bin/plutil` in `drivers/ios/xcode.ts` is a system tool, not a shim. With `DEVELOPER_DIR` set, `binary()` and `devicectlPath()` in `drivers/ios/devicectl.ts` run that Xcode's own `usr/bin` shim on purpose (K32: setting it selects that Xcode, and the smokes pass fake tools through it); its orphaned `xcodebuild` on a version mismatch stays open until v1.
- Only `cli.ts` and `mcp.ts` write to stdout or stderr or set process state, and `mcp.ts` writes stdout only through the SDK's stdio transport. The MCP server speaks JSON-RPC on stdout, so one stray write corrupts the stream. Drivers, feature files and `commands.ts` return values or throw `KaragozError`. The one write elsewhere is adb's own stderr, passed through unchanged by `adbBytes()` in `drivers/android/adb.ts` (K5: a tool's own stderr reaches the caller as it was).
- Every external process call has a timeout: adb, simctl, devicectl, xcodebuild, swiftc, plutil, log. adb blocks forever when something holds its server port and never answers (K19), and without the timeout an MCP call never returns. Name the value as a constant with its source (`TIMEOUT_MS` in `drivers/android/adb.ts`). The one exception is the iPhone runner's `xcodebuild test-without-building`, which outlives the call on purpose: its start budget bounds the call, a start nobody waits for is killed with its process group, and the runner's idle stop ends it afterwards (K41). `tar` in `drivers/ios/logs.ts` has none yet (`AGENTS.md`, `### Not yet in this layout`).
- A long call checks the cancellation signal from `cancellation.ts` before it starts and between reads (`tapElement()` in `drivers/ios/input.ts`), so a cancelled MCP call stops instead of running out its timeout (K31: the MCP client can cancel a call).
