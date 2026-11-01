# Karagöz

Device automation for mobile apps across four targets: Android emulator, Android device, iOS simulator, iOS device. CLI first, MCP server as a thin wrapper over the same core.

Every device command runs on all four targets (`install-runner` only on iPhones, `uninstall-runner` on iPhones and on simulators of a Mac whose CoreSimulator predates Xcode 27).

These rules are for anyone who changes this repository, person or agent. A decision number such as K5 points into the maintainers' design journal, which is not in the repository, so its reason is always written beside it.

## Before writing code

If `docs/local/` exists, read `docs/local/PROGRESS.md` and `docs/local/decisions.md` first. That is the working journal: where things stand, what the next single step is, and which decisions are already closed and why. It is untracked, so a fresh clone will not have it.

## How this project is built

One step at a time. A step is one command on one target, and it runs in this order:

1. **Research** the tools for that step: current versions, known breakage, alternatives.
2. **Sketch** the command surface: arguments, output shape, failure modes.
3. **Write** the shortest thing that works.
4. **Prove** it with one smoke script.
5. **Record** any decision or surprise in the journal.
6. **Document** the command on its page `docs/commands/<command>.md` in the same PR: usage, flags, one real output example, error codes, supported targets; a new command also gets a row in the README's command table. The journal is untracked and in Turkish, so `README.md` and `docs/` are the only public reference.

Research is never skipped. When an existing assumption conflicts with what the research turns up, the assumption changes.

## Hard boundaries

**Scope.** Primitive verbs only. Each command does one thing and exits. No assertions, no test runner, no recorded flows, no retry policy, no image diffing, no measurement reports. Those belong a layer above.

**Output contract.** The accessibility tree is the default return value, not the screenshot. Screenshots are written to disk and referenced by path; the image is only inlined when explicitly requested. Full resolution is always preserved, and every screenshot carries its scale metadata: pixel size, logical size, scale factor, safe area insets. Callers measure against that metadata, so it cannot be dropped.

**Errors.** JSON on stdout, human-readable logs on stderr, non-zero exit code on failure. The MCP layer passes the JSON through without reinterpreting it. The envelope is one line, `{"error":{"code":"<CODE>","message":"<text>"}}`, the exit code is 1, and the code comes from the closed `ErrorCode` set in `packages/karagoz/src/errors.ts`.

**Dependencies.** Standard library first: `node:util` `parseArgs` over a CLI framework, `node:child_process` over a process wrapper, global `fetch` over an HTTP client. When a dependency is genuinely needed, prefer one with no transitive dependencies, import it through subpaths, and judge the cost by what lands in the bundle rather than by the size of `node_modules`. No native addons. External tools (`adb`, and Xcode's `simctl`, `devicectl`, `xcodebuild` and `swiftc`) are detected at runtime and reported with a clear installation message when missing; they are never bundled.

**Device data.** Nothing read from a real phone that could identify it or its owner reaches a tracked file, a commit message, a PR, an issue, or any other public text. This holds for every phone, whoever owns it. That means serial numbers (also inside mDNS names such as `adb-<serial>-<id>`), IMEI, MAC and IP addresses, the user-set device name, accounts, phone numbers, and everything read off the screen: screenshots, `ui-tree` output, logs, and installed packages. A README example taken from a phone replaces each such value (`XXXXXXXXXXX`); screen content from a phone never appears in one. Model, brand, and Android version are product facts and may appear. Real values stay in the untracked `docs/local/`.

**Licensing.** MIT. Dependencies must be MIT, ISC, BSD, Apache-2.0 or BlueOak. No copyleft, and no source-available licenses with commercial use restrictions.

**MCP imports.** Only these two, from `@modelcontextprotocol/server` v2:

```
@modelcontextprotocol/server
@modelcontextprotocol/server/stdio
```

The v1 subpaths do not exist in v2, and v2's root does not bundle the HTTP transports. `packages/karagoz/smoke/M-mcp.sh` checks that no HTTP transport or bearer-auth code reaches `dist/` (K14: the server speaks stdio only).

## Code layout

Paths below are relative to `packages/karagoz/src/`.

- **Front ends:** `cli.ts` and `mcp.ts`. They own stdout, stderr and process state (`.claude/rules/source.md`), and both call `commands.ts`; neither imports a driver. The CLI and the MCP server return the same JSON for the same call (K1: MCP wraps the CLI's core).
- **Command table:** `commands.ts`. Each entry declares its flags and its `run` calls one function from a feature file; `check()` validates arguments and `envelope()` builds the error envelope from `## Hard boundaries`. It imports no driver and never branches on platform.
- **Feature files:** `screenshot.ts`, `ui-tree.ts`, `input.ts`, `app.ts`, `logs.ts`, `runner.ts`, one per feature, in this order: checks that do not depend on the platform, so `INVALID_ARGS` comes before any device call; `resolveTarget()` from `devices.ts`; exactly one branch between Android, iPhone (`kind === 'physical'`) and iOS simulator; then the work every platform shares, such as writing the PNG. A feature file never runs an external tool and never parses a tool's output. `screenshot.ts` is the example.
- **Targets:** `devices.ts` lists every platform and resolves `--device`. It is the only top-level file that calls several drivers of one platform.
- **Shared modules:** `errors.ts`, `cancellation.ts`, `png.ts`, `tool.ts` (runs an external tool and sorts its failure), `keys.ts` (key names), `xml.ts` (XML entities), `element.ts` (the element search behind `--text` and `--id`). They import nothing from `src/` but each other. Code or a table that two platforms need moves into a module like these (`png.ts` reads the PNG size for both); one platform's driver never hosts it for the other.
- **Android driver:** `drivers/android/`. One transport, `adb.ts` (finds adb, runs it, maps its failures to error codes), and one file per feature named after its feature file. Emulator and phone share it: they differ in a few branches, not in transport (K10).
- **iOS driver:** `drivers/ios/`, both Apple targets. Transports are files: `simctl.ts` for the simulator; `devicectl.ts`, `usbmux.ts`, `lockdown.ts`, `runner.ts` (talks to the running runner) and `runner-build.ts` (builds, installs and removes it) for the iPhone; `xcode.ts` (developer dir, caches, signing teams) for both. A feature file holds the simulator function `<verb>` and the iPhone function `<verb>Phone` side by side (`capture` and `capturePhone` in `drivers/ios/screenshot.ts`), because they share helpers such as `panelScale`. Swift lives in `drivers/ios/ax-helper.swift` (simulator helper) and `packages/ios-runner/` (iPhone runner).
- **Imports:** a driver imports shared modules and files of its own platform only. Android never imports iOS, iOS never imports Android, and no driver imports a feature file, `devices.ts`, `commands.ts` or a front end. `no-restricted-imports` in `packages/karagoz/.oxlintrc.json` enforces this and the front-end rule; a new shared module goes into its allow list.
- **No driver interface,** registry or map of drivers, though there are three backends. The branch is one or two lines per function, and the call shapes differ (an iPhone call goes through the runner, an Android key takes a key code), so an interface would add a type per feature that no caller needs. Import each driver function under an alias instead (`capture as captureAndroid` in `screenshot.ts`).
- **New external tool:** its finding, running and failure mapping go into a transport file of its platform, next to the others. A tool only one feature calls may live in that feature's driver file (`log` in `drivers/ios/logs.ts`).

## Conventions

- Code, comments, commit messages and public documentation are in English.
- Commits follow Conventional Commits, sized to the change: an imperative subject of 72 characters or fewer, lowercase after the colon, and a short body wrapped at 72 whenever the change carries behavior or a decision. No file lists, no story of how it was found, no pointer into the untracked journal.
- No AI attribution in commits or pull requests: no "Generated with" lines, no session links, no `Co-Authored-By:` trailer naming an AI tool. GitHub turns those trailers into contributor credits.
- One branch per step, `feat/<step>-<topic>` off `main` (`feat/4.7-ios-device-closure`), landing through one PR. A one-line fix or a typo goes straight to `main`.
- Before calling a change done, run `npm run typecheck` and `npm run lint` from the repository root; both must exit 0. `npm run format` fixes what the format check reports.
- Merge gate: on the branch head, `npm run typecheck`, `npm run lint` and every `packages/karagoz/smoke/*.sh` with an emulator running; a booted simulator also runs the simulator smokes' real parts. Phone parts SKIP, so the gate never needs a phone, and a review never stands in for the run. After a passing gate, rerun it only when `src/`, `package.json`, the lockfile or a smoke that runs without a phone changed, or `main` moved.
- README and `docs/`: the README introduces karagoz and gets a reader started. Besides what karagoz is, how to install and register it and a quick start, it may hold a demo, example requests, an FAQ and a short how-it-works, and it sums up each area in a line that links to its `docs/` page. The detail is written once, on that page. Before adding a sentence, example or note to the README, ask whether a reader would understand karagoz less or start wrong without it; for `docs/`, whether a caller would do something wrong without it; for both, whether a sentence already there would be wrong. If none of these holds, it stays out; editing an existing line beats adding one. Which device, OS version or Mac a command was tested on is a test record and is added to neither.
- Study other tools' source to learn how something works, then write karagoz's own; copy no code verbatim or nearly so. Tracked text (comments, README, smoke scripts, commits, PRs) names or links another package or repository only when karagoz calls it or depends on it. Copied code brings license and authorship questions, and a name reads as dependence or advertising.
- The CLI and the MCP server live in `packages/karagoz/`, their smoke scripts in `packages/karagoz/smoke/`, the iPhone runner's Xcode project in `packages/ios-runner/`. npm scripts run from the repository root.

## Rule files

| File | Read before changing | Holds |
|---|---|---|
| `.claude/rules/source.md` | `packages/karagoz/src/**/*.ts` | process calls and timeouts, stdout ownership, PATH lookup, user-supplied keys |
| `.claude/rules/typescript.md` | `packages/karagoz/src/**/*.ts` | where outside data is narrowed, unions, error codes, catches, suppression comments |
| `.claude/rules/simplicity.md` | `packages/karagoz/src/**/*.ts` | when structure is earned, constants, `ponytail:` shortcuts, comments |
| `.claude/rules/smoke.md` | `packages/karagoz/smoke/**/*.sh` | the pass condition, traps, envelope checks, fake tools |

Claude Code loads each file by itself when a matching file is read or edited. Any other agent opens the file for the path it is about to change before changing it.
