# Karagöz

Device automation for mobile apps across four targets: Android emulator, Android device, iOS simulator, iOS device. CLI first, MCP server as a thin wrapper over the same core.

Early development. The design is settled, most of the code is not written yet.

## Before writing code

If `docs/local/` exists, read `docs/local/PROGRESS.md` and `docs/local/decisions.md` first. That is the working journal: where things stand, what the next single step is, and which decisions are already closed and why. It is untracked, so a fresh clone will not have it.

## How this project is built

One step at a time. A step is one command on one target, and it runs in this order:

1. **Research** the tools for that step: current versions, known breakage, alternatives.
2. **Sketch** the command surface: arguments, output shape, failure modes.
3. **Write** the shortest thing that works.
4. **Prove** it with one smoke script.
5. **Record** any decision or surprise in the journal.
6. **Document** the command in `README.md` in the same PR: usage, flags, one real output example, error codes, supported targets. The journal is untracked and in Turkish, so the README is the only public reference.

Research is never skipped. When an existing assumption conflicts with what the research turns up, the assumption changes.

## Hard boundaries

**Scope.** Primitive verbs only. Each command does one thing and exits. No assertions, no test runner, no recorded flows, no retry policy, no image diffing, no measurement reports. Those belong a layer above.

**Output contract.** The accessibility tree is the default return value, not the screenshot. Screenshots are written to disk and referenced by path; the image is only inlined when explicitly requested. Full resolution is always preserved, and every screenshot carries its scale metadata: pixel size, logical size, scale factor, safe area insets. Callers measure against that metadata, so it cannot be dropped.

**Errors.** JSON on stdout, human-readable logs on stderr, non-zero exit code on failure. The MCP layer passes the JSON through without reinterpreting it.

**Dependencies.** Standard library first — `node:util` `parseArgs` over a CLI framework, `node:child_process` over a process wrapper, global `fetch` over an HTTP client. When a dependency is genuinely needed, prefer one with no transitive dependencies, import it through subpaths, and judge the cost by what lands in the bundle rather than by the size of `node_modules`. No native addons. External tools (`adb`, `xcrun`, and the iOS tunnel) are detected at runtime and reported with a clear installation message when missing; they are never bundled.

**Device data.** Nothing read from a real phone that could identify it or its owner reaches a tracked file, a commit message, a PR, an issue, or any other public text. This holds for every phone, whoever owns it. That means serial numbers (also inside mDNS names such as `adb-<serial>-<id>`), IMEI, MAC and IP addresses, the user-set device name, accounts, phone numbers, and everything read off the screen: screenshots, `ui-tree` output, logs, and installed packages. A README example taken from a phone replaces each such value (`XXXXXXXXXXX`); screen content from a phone never appears in one. Model, brand, and Android version are product facts and may appear. Real values stay in the untracked `docs/local/`.

**Licensing.** MIT. Dependencies must be MIT, ISC, BSD, Apache-2.0 or BlueOak. No copyleft, and no source-available licenses with commercial use restrictions.

**MCP imports.** Only these two, from `@modelcontextprotocol/server` v2:

```
@modelcontextprotocol/server
@modelcontextprotocol/server/stdio
```

The v1 subpaths do not exist in v2, and v2's root does not bundle the HTTP transports. `packages/karagoz/smoke/M-mcp.sh` checks that no HTTP transport or bearer-auth code reaches `dist/` (K14).

## Conventions

Code, comments, commit messages and public documentation are in English. Commit messages follow Conventional Commits.

The CLI and MCP server live in `packages/karagoz/`, with their smoke scripts in `packages/karagoz/smoke/`; npm scripts run from the repository root. Before calling a change done, run `npm run typecheck` and `npm run lint`; both must exit 0. `npm run format` fixes what the format check reports.
