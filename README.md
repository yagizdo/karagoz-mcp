<div align="center">

<a href="https://karagozmcp.com/?utm_source=github&utm_medium=readme"><img src="https://raw.githubusercontent.com/yagizdo/karagoz-mcp/main/.github/assets/banner.png" alt="Karagöz: device automation for mobile apps on an Android emulator, Android device, iOS simulator and iOS device. karagoz ui-tree on emulator-5554 returns the Chrome icon with bounds [581,1905,754,2100], and karagoz tap --text Chrome taps it at x 667.5, y 2002.5." width="100%"></a>

# Karagöz

[![npm version](https://img.shields.io/npm/v/karagoz-mcp.svg)](https://www.npmjs.com/package/karagoz-mcp)
[![CI](https://github.com/yagizdo/karagoz-mcp/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/yagizdo/karagoz-mcp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/yagizdo/karagoz-mcp/blob/main/LICENSE)
[![Node.js](https://img.shields.io/badge/node-%3E%3D22-brightgreen)](https://nodejs.org)
[![npm downloads](https://img.shields.io/npm/d18m/karagoz-mcp.svg)](https://www.npmjs.com/package/karagoz-mcp)
[![Glama score](https://glama.ai/mcp/servers/yagizdo/karagoz-mcp/badges/score.svg)](https://glama.ai/mcp/servers/yagizdo/karagoz-mcp)

[Website](https://karagozmcp.com/?utm_source=github&utm_medium=readme) · [Docs](https://karagozmcp.com/docs/?utm_source=github&utm_medium=readme)

</div>

Device automation for mobile apps. One tool for four targets: Android emulator, Android physical device, iOS simulator, iOS physical device. It is a CLI, and `karagoz mcp` serves the same commands to an AI agent as an [MCP server](#mcp-server).

## Contents

- [Why karagoz](#why-karagoz)
- [Scope](#scope)
- [Status](#status)
- [Getting started](#getting-started)
- [MCP server](#mcp-server)
- [Things to ask your agent](#things-to-ask-your-agent)
- [Commands](#commands)
- [Output and errors](#output-and-errors)
- [How it works](#how-it-works)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)

## Why karagoz

`adb`, `simctl` and `devicectl` run the command; karagoz tells you what the command actually did.

- **What happened, as a code.** `am force-stop` on an app that is not installed says nothing, `simctl` and `devicectl` report success for uninstalling an app that is not there, and Android answers a missing package with the code it gives a package it will not remove. karagoz checks first and returns `APP_NOT_FOUND`. A refused install is `INSTALL_FAILED` with the platform's own code in `reason`, not text to parse.
- **One contract on four targets.** The same commands, flags, device selection, [output and error codes](#output-and-errors) on an Android emulator, an Android phone, an iOS simulator and an iPhone. The MCP server returns the CLI's JSON line unchanged.
- **The accessibility tree first.** To see the screen, read `ui-tree` before taking a screenshot. The tree is text a program can search, costs a few hundred to a few thousand tokens, and gives the bounds needed to tap. A screenshot is written to disk at full resolution and returned as a path, with its pixel size, logical size and scale (and safe area on Android) to measure against; the CLI never prints the image.
- **It installs only what you ask and starts no daemon of its own.** karagoz installs nothing on a device by itself, with one exception: on a Mac that never had Xcode 27, the first `tap`, `long-press`, `double-tap`, `swipe`, `text` or `key` on a simulator installs karagoz's runner there ([Requirements](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/requirements.md)). `install` installs only the app you pass it, and `install-runner` only karagoz's runner. Each command is one process that exits when it answers, and `karagoz mcp` lives as long as the client that started it. Only karagoz's runner, on an iPhone or on that simulator, stays up between calls, and it stops itself 10 minutes after its last use.

## Scope

karagoz is the primitive layer. Each command does one thing and exits.

- **Not a test framework.** No assertions, no test runner, no recorded flows, no retry policy, no reports. `tap --timeout` waits for a node to appear; it never repeats an action.
- **Not a design comparison tool.** Figma diffing, measurement and reporting belong a layer above. karagoz produces the raw input, and the metadata to measure it with, but does not interpret it.

## Status

Early development. Every command runs on all four targets, except `install-runner`, which runs only on iPhones, and `uninstall-runner`, which runs on iPhones and on simulators of a Mac that never had Xcode 27. For Windows and Linux, see the [FAQ](#faq).

## Getting started

### Requirements

- Node 22 or newer.
- **Android:** `adb` from Android platform-tools, and a running emulator or a phone with USB debugging on.
- **iOS simulator** (macOS): Xcode, opened once, and a booted simulator. `tap`, `long-press`, `double-tap`, `swipe`, `text` and `key` need Xcode 27 or newer, or a Mac that never had Xcode 27, where they go through karagoz's runner.
- **iPhone** (macOS): Xcode 15 or newer (27 for `screenshot`) and the iPhone paired with the Mac. `screenshot`, `install`, `launch`, `open-url`, `terminate` and `uninstall` need Developer Mode on; `logs` needs a USB cable; `ui-tree`, `tap`, `long-press`, `double-tap`, `swipe`, `text` and `key` need both, plus UI Automation on and karagoz's runner, which [`install-runner`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/install-runner.md) installs.

[What each command needs, and how karagoz finds `adb` and Xcode](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/requirements.md).

### Install

```sh
npm install -g karagoz-mcp
karagoz devices
```

Or without installing: `npx -y karagoz-mcp devices`. To build from source: [Development](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/development.md).

### Quick start

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

Claude Code with the [MCP server](#mcp-server) on an iOS simulator, in real time. The right side lists each karagoz call and part of the JSON it returned.

![An iOS simulator next to a list of tool calls. Asked to open Settings on the iOS simulator and turn on dark mode, Claude Code calls devices, launch, ui_tree, tap on the Appearance row by id, ui_tree, tap on Dark by text, and ui_tree, and the simulator switches to dark mode.](https://raw.githubusercontent.com/yagizdo/karagoz-mcp/main/.github/assets/demo.gif)

## MCP server

```
karagoz mcp
```

Starts an MCP server for an AI agent on stdin and stdout. It opens no port: the client starts the process and talks to it over stdio. The 18 commands are its tools, and each tool returns the JSON line the CLI prints.

### Claude Code

```sh
claude mcp add karagoz -- npx -y karagoz-mcp mcp
```

### Claude Desktop

Download [`karagoz.mcpb`](https://github.com/yagizdo/karagoz-mcp/releases/latest/download/karagoz.mcpb) from the latest release and open it. Desktop installs it as an extension.

### Cursor

[![Add to Cursor](https://cursor.com/deeplink/mcp-install-dark.svg)](https://cursor.com/link/mcp/install?name=karagoz&config=eyJ0eXBlIjoic3RkaW8iLCJjb21tYW5kIjoibnB4IiwiYXJncyI6WyIteSIsImthcmFnb3otbWNwIiwibWNwIl19)

Or in `.cursor/mcp.json`:

```json
{"mcpServers":{"karagoz":{"type":"stdio","command":"npx","args":["-y","karagoz-mcp","mcp"]}}}
```

### VS Code

In `.vscode/mcp.json`:

```json
{"servers":{"karagoz":{"type":"stdio","command":"npx","args":["-y","karagoz-mcp","mcp"]}}}
```

### Codex

```sh
codex mcp add karagoz -- npx -y karagoz-mcp mcp
```

Then add these two lines under `[mcp_servers.karagoz]` in `~/.codex/config.toml`. The command cannot write them, and without them Codex hides `ANDROID_HOME` from karagoz and cuts long calls short:

```toml
env_vars = ["ANDROID_HOME", "ANDROID_SDK_ROOT", "KARAGOZ_DEVICE", "ANDROID_SERIAL", "DEVELOPER_DIR"]
tool_timeout_sec = 600
```

[Other ways to register each client, running from a clone, and the tools' arguments, results and behavior](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/mcp.md).

### Token cost

What the server adds to a Claude Code session, measured on 2026-10-30 with Claude Code 2.1.306 and `claude-opus-5-5`: input tokens of the first API call with karagoz registered, minus the same call with no MCP server.

| Case | Tokens |
| --- | --- |
| Every session, tool search on (the default): the 18 tool names and `instructions` | 410 |
| All 18 definitions, loaded by one `ToolSearch` call | 3,634 |
| Every session, tool search off (`ENABLE_TOOL_SEARCH=false`): every definition and `instructions` | 3,476 |

The `tools/list` result is 9,547 characters, `instructions` 398. One `ui_tree` of the launcher home screen is 5,127 characters (11,767 with `detail: full`).

## Things to ask your agent

Once the server is registered, describe the task to your agent. It reads the screen with `ui_tree` and calls one tool per step.

- "Open Settings on the emulator and turn on dark mode."
- "Install `./build/app-debug.apk`, open it, and tell me what the first screen shows."
- "On the sign-in screen, type `test@example.com` into the email field and tap Continue."
- "Open `myapp://orders/42` on the iOS simulator and take a screenshot."
- "The app closes right after launch on the emulator. Show me its last 50 log lines."

## Commands

| Command | Does |
| --- | --- |
| [`devices`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/devices.md) | List connected devices |
| [`screenshot`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/screenshot.md) | Save a full-resolution PNG and return its path with scale metadata |
| [`ui-tree`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/ui-tree.md) | Return the accessibility tree of the focused window |
| [`tap`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/tap.md) | Tap a point, or a node found by text or id |
| [`long-press`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/long-press.md) | Press and hold a point or a node |
| [`double-tap`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/double-tap.md) | Tap a point or a node twice |
| [`swipe`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/swipe.md) | Swipe between two points |
| [`text`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/text.md) | Type text into the focused field |
| [`key`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/key.md) | Press a key |
| [`install`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/install.md) | Install or replace an app |
| [`launch`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/launch.md) | Start an app as its launcher icon does |
| [`open-url`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/open-url.md) | Open a URL or deep link in the app that handles it |
| [`terminate`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/terminate.md) | Stop every process of an app |
| [`uninstall`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/uninstall.md) | Remove an app |
| [`logs`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/logs.md) | Read the device log |
| [`doctor`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/doctor.md) | Report which adb and Xcode karagoz uses |
| [`install-runner`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/install-runner.md) | Build karagoz's runner and install it on an iPhone |
| [`uninstall-runner`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/uninstall-runner.md) | Remove karagoz's runner from an iPhone or a simulator |
| [`mcp`](#mcp-server) | Start the MCP server on stdio |

Every command except `devices`, `doctor` and `mcp` works on one device. When more than one is listed, pick it with `--device <id or name>` or `KARAGOZ_DEVICE`: [Device selection](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/device-selection.md).

## Output and errors

Every command prints one line of JSON on stdout: its result with exit code `0`, or `{"error":{"code":"<CODE>","message":"<text>"}}` with exit code `1`. Branch on `error.code`, not on the message.

[Output, arguments and coordinates](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/output.md) · [Error codes](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/error-codes.md) · [Known limitations](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/known-limitations.md)

## How it works

A command finds the device, runs the platform's own tool for the job, and turns the answer into one JSON line. `karagoz mcp` calls the same code.

| Target | Screen | Accessibility tree | Input | Apps | Logs |
| --- | --- | --- | --- | --- | --- |
| Android emulator and phone | `adb` `screencap` | `uiautomator dump` | `input`; text outside ASCII and `double-tap` through a helper copied to the device for the call | `adb install`, `am`, `pm`, `cmd package` | `logcat` |
| iOS simulator | `simctl io screenshot` | karagoz's Swift helper, compiled on first use with Xcode's `swiftc` | The helper: the simulator's input service, and XCUIAutomation for `text` (Xcode 27). On a Mac that never had Xcode 27, karagoz's runner inside the simulator | `simctl` | `log show` inside the simulator |
| iPhone | `devicectl` | karagoz's runner, an XCUITest bundle that `xcodebuild` starts and karagoz reaches over USB | karagoz's runner | `devicectl` | The phone's log relay over USB, read with macOS's `log` |

## FAQ

**What does karagoz install on my device?**
Nothing by itself, apart from the simulator runner in [Why karagoz](#why-karagoz). Typing text outside ASCII on Android copies a small helper to `/data/local/tmp` and deletes it when the call ends ([`text`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/text.md)).

**What does an iPhone need?**
A Mac with Xcode and the iPhone paired, with Developer Mode on. Reading the screen and input also need a USB cable, UI Automation on, and karagoz's runner, installed once with [`install-runner`](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/commands/install-runner.md). A free Apple ID signs the runner for 7 days ([Known limitations](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/known-limitations.md)).

**Why does `screenshot` return a path, not the image?**
The tree answers most questions about a screen as text. The PNG is kept at full resolution on disk, with the scale needed to measure against it. Over MCP, `inline: true` also returns the image, which the client scales down, so take coordinates from the tree ([MCP results](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/mcp.md#results)).

**Does it work on Windows or Linux?**
iOS targets need macOS. Android targets need only Node and `adb`, and karagoz looks for `adb` in the Windows and Linux SDK folders too, but no device command has been run on either system yet. On Linux, CI runs the type check, lint, build and the smoke tests that need no device.

**Can another UI automation tool run at the same time?**
On Android only one UiAutomation client can be connected, so `ui-tree`, and a tap by `--text` or `--id`, return `AUTOMATION_BUSY` while another holds it. On an iOS simulator, `text` fails the same way while a UI test runs ([Error codes](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/error-codes.md)).

## Contributing

Bug reports and pull requests are welcome. [CONTRIBUTING.md](https://github.com/yagizdo/karagoz-mcp/blob/main/CONTRIBUTING.md) covers what to put in an issue, the checks a pull request needs, and what device data must never be posted.

## License

MIT
