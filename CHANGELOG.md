# Changelog

All notable changes to karagoz-mcp are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] - 2026-11-01

The commands and the MCP server are unchanged from 0.3.0. This release updates the README that ships with the package and shows on npm.

### Changed

- The README opens with a banner and a demo GIF of an agent driving the iOS simulator, and adds example requests, a How it works table and an FAQ ([`3494e34`](https://github.com/yagizdo/karagoz-mcp/commit/3494e34), [`d613a07`](https://github.com/yagizdo/karagoz-mcp/commit/d613a07), [`b5edafc`](https://github.com/yagizdo/karagoz-mcp/commit/b5edafc), [`7d487cb`](https://github.com/yagizdo/karagoz-mcp/commit/7d487cb))
- A Known limitations page lists the platform and MCP client limits that cross commands, such as the iPhone passcode prompt before UI automation and the 7-day signing of a free Apple ID ([`bd8d7c1`](https://github.com/yagizdo/karagoz-mcp/commit/bd8d7c1))
- A contributing guide covers what to put in an issue, the checks a pull request needs, and which device data never gets posted ([`7040d3e`](https://github.com/yagizdo/karagoz-mcp/commit/7040d3e))

## [0.3.0] - 2026-10-31

### Added

- `long-press` and the `long_press` MCP tool press and hold a point, or a node found by `--text` or `--id`. `--duration` defaults to 1000 ms. ([`1c6c5cb`](https://github.com/yagizdo/karagoz-mcp/commit/1c6c5cb), [`057bd97`](https://github.com/yagizdo/karagoz-mcp/commit/057bd97))
- `double-tap` and the `double_tap` MCP tool tap a point or a node twice, on all four targets. ([`cd2b002`](https://github.com/yagizdo/karagoz-mcp/commit/cd2b002), [`a4de0d7`](https://github.com/yagizdo/karagoz-mcp/commit/a4de0d7))
- `open-url` and the `open_url` MCP tool open a URL or deep link in the app the system picks, or with `--app` in the app you name (not on an iOS simulator). MCP clients see `open_url` as an open-world tool. ([`702c6c7`](https://github.com/yagizdo/karagoz-mcp/commit/702c6c7), [`67d4481`](https://github.com/yagizdo/karagoz-mcp/commit/67d4481))
- Claude Desktop extension: download `karagoz.mcpb` from this release and open it. Desktop runs it with its own Node.js. ([`bc93326`](https://github.com/yagizdo/karagoz-mcp/commit/bc93326))

### Changed

- **Breaking:** `tap --duration <ms>` is now `long-press --duration <ms>`, and the MCP `tap` tool's `duration` argument moved to the new `long_press` tool. `tap --duration` now fails with `INVALID_ARGS`. ([`1c6c5cb`](https://github.com/yagizdo/karagoz-mcp/commit/1c6c5cb), [`057bd97`](https://github.com/yagizdo/karagoz-mcp/commit/057bd97))
- **Breaking:** On an iPhone, run `install-runner` again after updating: the runner changed for `double-tap`. Until then, the calls that use the runner fail with `RUNNER_NOT_INSTALLED`. A simulator that uses the runner gets the new one by itself. ([`813ee74`](https://github.com/yagizdo/karagoz-mcp/commit/813ee74))
- Shorter client setups: Codex starts from `codex mcp add`, Cursor (3.15.12 or newer) from an install link. ([`bc93326`](https://github.com/yagizdo/karagoz-mcp/commit/bc93326))
- The `tap` docs now say that `tap`, `long-press` and `double-tap` match `--text` and `--id` on the full tree, not the compact one `ui-tree` returns by default. ([`d1463ec`](https://github.com/yagizdo/karagoz-mcp/commit/d1463ec))

## [0.2.0] - 2026-10-30

### Added

- `ui-tree --detail compact|full`, and `detail` on the `ui_tree` MCP tool. Any other value is `INVALID_ARGS` before a device call. ([`f520775`](https://github.com/yagizdo/karagoz-mcp/commit/f520775), [`287a761`](https://github.com/yagizdo/karagoz-mcp/commit/287a761))
- `text` on Android types any Unicode text, such as `ğ`, `ş`, `ı` or an emoji. ASCII text still goes through `input text`. Other text is pasted: karagoz copies a small helper of its own to `/data/local/tmp`, which puts the text on the clipboard, presses Ctrl+V and puts the previous clip back, and deletes the helper when the call ends. Android 12 and newer show a paste notice, and a keyboard with clipboard history keeps the pasted text. A helper failure is `HELPER_FAILED`, with what happened to the previous clip. Only control characters other than newline and tab are still `TEXT_UNSUPPORTED`. ([`c912e47`](https://github.com/yagizdo/karagoz-mcp/commit/c912e47), [`c5d04fc`](https://github.com/yagizdo/karagoz-mcp/commit/c5d04fc))

### Changed

- **Breaking:** `ui-tree` returns a compact tree by default. A node with no text, label or action is left out and its children take its place, and a node off screen is left out. On Android `class` keeps the part after the last dot (`Button`), `resourceId` the part after `:id/` (`save`), and a `contentDesc` equal to `text` is left out. On an iPhone the window and unlabeled group layers go, and the `Keyboard` node keeps its bounds without its `Key` children. `bounds` are unchanged, and `tap --id` takes either form of the id. Code that reads the old tree passes `--detail full`, which returns it exactly as before. On the measured Android screens a compact tree is about 800 to 2,300 tokens, a full one 2,900 to 5,400. ([`f520775`](https://github.com/yagizdo/karagoz-mcp/commit/f520775), [`871468c`](https://github.com/yagizdo/karagoz-mcp/commit/871468c))
- The README has a table of contents and an MCP setup snippet for each client: Claude Code, Claude Desktop, Cursor, VS Code and Codex. ([`8b38cf0`](https://github.com/yagizdo/karagoz-mcp/commit/8b38cf0), [`4ec8c7d`](https://github.com/yagizdo/karagoz-mcp/commit/4ec8c7d))
- The npm and MCP Registry descriptions say that karagoz starts no daemon of its own and installs nothing on an Android device by itself. ([`68b120d`](https://github.com/yagizdo/karagoz-mcp/commit/68b120d))

### Fixed

- `text` on an iOS simulator typed U+FFFD for an unpaired surrogate and still reported the text as typed. iOS now refuses it with `TEXT_UNSUPPORTED`, as Android does. Only MCP's JSON can carry one. ([`eeee85c`](https://github.com/yagizdo/karagoz-mcp/commit/eeee85c))

## [0.1.1] - 2026-10-27

karagoz-mcp 0.1.1 is the first release built and published from GitHub Actions, with npm provenance: the npm page links this version to the commit and the workflow run that built it. The commands, their output and the MCP tools are the same as in 0.1.0.

## [0.1.0] - 2026-10-27

karagoz-mcp 0.1.0 is the first release: a CLI and a stdio MCP server that drive Android emulators and phones, iOS simulators and iPhones with one set of commands (devices, screenshot, ui-tree, tap, swipe, text, key, install, launch, terminate, uninstall, logs, doctor, and install-runner and uninstall-runner for karagoz's iOS runner). Every command prints one line of JSON, and a failure carries a code from a closed set.

Install with `npm install -g karagoz-mcp`, or register the MCP server as `npx -y karagoz-mcp mcp`.

Needs Node 22 or newer, adb for Android, and Xcode on macOS for iOS. On a simulator, tap, swipe, text and key use the input service that comes with Xcode 27, and text also needs an iOS 27 simulator. On a Mac that never had Xcode 27, the four go through karagoz's runner instead: the first of them builds it and installs it on the simulator, which takes about half a minute. Windows and Linux have not been run.

As a 0.x release, the JSON output and the error codes may still change in a minor version.

[0.3.1]: https://github.com/yagizdo/karagoz-mcp/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/yagizdo/karagoz-mcp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/yagizdo/karagoz-mcp/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/yagizdo/karagoz-mcp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/yagizdo/karagoz-mcp/releases/tag/v0.1.0
