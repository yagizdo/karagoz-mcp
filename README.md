# Karagöz

Device automation for mobile apps. One tool for four targets: Android emulator, Android physical device, iOS simulator, iOS physical device. It is a CLI, and `karagoz mcp` serves the same commands to an AI agent as an [MCP server](#mcp-server).

Website: [karagozmcp.com](https://karagozmcp.com/?utm_source=github&utm_medium=readme)

## Why karagoz

`adb`, `simctl` and `devicectl` run the command; karagoz tells you what the command actually did.

- **What happened, as a code.** `am force-stop` on an app that is not installed says nothing, `simctl` and `devicectl` report success for uninstalling an app that is not there, and Android answers a missing package with the code it gives a package it will not remove. karagoz checks first and returns `APP_NOT_FOUND`. A refused install is `INSTALL_FAILED` with the platform's own code in `reason`, not text to parse.
- **One contract on four targets.** The same commands, flags, device selection, [output and error codes](#output-and-errors) on an Android emulator, an Android phone, an iOS simulator and an iPhone. The MCP server returns the CLI's JSON line unchanged.
- **The accessibility tree first.** To see the screen, read `ui-tree` before taking a screenshot. The tree is text a program can search, costs a few hundred to a few thousand tokens, and gives the bounds needed to tap. A screenshot is written to disk and returned as a path; the CLI never prints the image.
- **It installs only what you ask.** karagoz installs nothing on a device by itself; `install` installs only the app you pass it, and `install-runner` only karagoz's runner.

## Status

Early development. Every command runs on all four targets, except `install-runner` and `uninstall-runner`, which run only on iPhones. Windows and Linux have not been run.

## Requirements

- Node 22 or newer.
- **Android:** `adb` from Android platform-tools, and a running emulator or a phone with USB debugging on.
- **iOS simulator** (macOS): Xcode, opened once, and a booted simulator. `tap`, `swipe` and `key` need Xcode 27 or newer.
- **iPhone** (macOS): Xcode 15 or newer (27 for `screenshot`), and the iPhone paired with the Mac, with Developer Mode on. `logs` also needs a USB cable; `ui-tree`, `tap`, `swipe`, `text` and `key` a USB cable, UI Automation on, and karagoz's runner, which [`install-runner`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/install-runner.md) installs.

[What each command needs, and how karagoz finds `adb` and Xcode](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/requirements.md).

## Install

Not on npm yet. From source:

```sh
git clone https://github.com/yagizdo/karagoz-mcp.git
cd karagoz-mcp
npm install
npm run build          # writes packages/karagoz/dist/: cli.js and two chunks
node packages/karagoz/dist/cli.js devices
```

`npm link`, run in `packages/karagoz`, puts `karagoz` on your `PATH`. The examples below use `karagoz`.

## Quick start

```sh
$ karagoz devices
{"devices":[{"id":"emulator-5554","platform":"android","kind":"emulator","state":"device","name":"Medium_Phone_API_36.1"}]}

$ karagoz tap --text Chrome
{"device":"emulator-5554","x":667.5,"y":2002.5,"element":{"class":"android.widget.TextView","text":"Chrome","contentDesc":"Chrome","clickable":true,"longClickable":true,"focusable":true,"bounds":[581,1905,754,2100]}}

$ karagoz key HOME
{"device":"emulator-5554","key":"KEYCODE_HOME","code":3}

$ karagoz screenshot --out home.png
{"path":"/Users/me/home.png","device":"emulator-5554","pixels":{"width":1080,"height":2400},"logical":{"width":411.42857142857144,"height":914.2857142857143},"scale":2.625,"safeArea":{"top":63,"right":0,"bottom":63,"left":0},"rotation":0}
```

`karagoz ui-tree` prints the screen's accessibility tree; `tap --text` above found its target in that tree.

## Commands

| Command | Does |
| --- | --- |
| [`devices`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/devices.md) | List connected devices |
| [`screenshot`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/screenshot.md) | Save a full-resolution PNG and return its path with scale metadata |
| [`ui-tree`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/ui-tree.md) | Return the accessibility tree of the focused window |
| [`tap`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/tap.md) | Tap or long-press a point, or a node found by text or id |
| [`swipe`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/swipe.md) | Swipe between two points |
| [`text`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/text.md) | Type text into the focused field |
| [`key`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/key.md) | Press a key |
| [`install`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/install.md) | Install or replace an app |
| [`launch`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/launch.md) | Start an app as its launcher icon does |
| [`terminate`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/terminate.md) | Stop every process of an app |
| [`uninstall`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/uninstall.md) | Remove an app |
| [`logs`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/logs.md) | Read the device log |
| [`doctor`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/doctor.md) | Report which adb and Xcode karagoz uses |
| [`install-runner`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/install-runner.md) | Build karagoz's runner and install it on an iPhone |
| [`uninstall-runner`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/uninstall-runner.md) | Remove karagoz's runner from an iPhone |
| [`mcp`](#mcp-server) | Start the MCP server on stdio |

Every command except `devices` works on one device. When more than one is listed, pick it with `--device <id or name>` or `KARAGOZ_DEVICE`: [Device selection](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/device-selection.md).

## Output and errors

Every command prints one line of JSON on stdout: its result with exit code `0`, or `{"error":{"code":"<CODE>","message":"<text>"}}` with exit code `1`. Branch on `error.code`, not on the message.

[Output, arguments and coordinates](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/output.md) · [Error codes](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/error-codes.md)

## MCP server

```
karagoz mcp
```

Starts an MCP server for an AI agent on stdin and stdout. It opens no port: the client starts the process and talks to it over stdio. The 15 commands are its tools, and each tool returns the JSON line the CLI prints. The server code loads only when `mcp` runs, so the other commands start as fast as before.

Register it with Claude Code:

```sh
claude mcp add karagoz -- node /abs/path/karagoz-mcp/packages/karagoz/dist/cli.js mcp
```

[Claude Desktop, Cursor, VS Code and Codex, the tools, their arguments, results and behavior](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/mcp.md).

### Token cost

What the server adds to a Claude Code session, measured on 2026-10-21 with Claude Code 2.1.306 and `claude-opus-5-5`: input tokens of the first API call with karagoz registered, minus the same call with no MCP server.

| Case | Tokens |
| --- | --- |
| Every session, tool search on (the default): the 15 tool names and `instructions` | 370 |
| All 15 definitions, loaded by one `ToolSearch` call | 2,750 |
| Every session, tool search off (`ENABLE_TOOL_SEARCH=false`): every definition and `instructions` | 2,632 |

The `tools/list` result is 7,152 characters, `instructions` 398. One `ui_tree` of the launcher home screen is 5,383 characters.

## Scope

karagoz is the primitive layer. Each command does one thing and exits.

- **Not a test framework.** No assertions, no test runner, no recorded flows, no retry policy, no reports. `tap --timeout` waits for a node to appear; it never repeats an action.
- **Not a design comparison tool.** Figma diffing, measurement and reporting belong a layer above. karagoz produces the raw input, and the metadata to measure it with, but does not interpret it.

## Development

Build, checks and smoke scripts: [docs/development.md](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/development.md).

## Name

Karagöz is Turkish shadow puppet theatre. Figures are driven with rods from behind a lit screen while the audience watches the movement on the screen. That is what this tool does.

## License

MIT
