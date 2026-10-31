# Known limitations

Limits that come from the platform or the MCP client, not from karagoz, and that cross commands. A limit of one command is on that command's page.

## Android

- **A lock screen takes the input.** On a lock screen, `text` and `key` type into the PIN field, and a wrong PIN counts as a failed unlock attempt. Both exit `0`. Unlock the phone before sending input, unless the input is the PIN. ([Requirements](requirements.md))

## iPhone

- **iOS asks for the passcode before UI automation starts.** With a passcode set, the phone shows "Enter iPhone Passcode for XCTest" when the runner starts: the first time after a restart, about once a day, and the first time after the phone was locked. `xcodebuild` does not report it, so `ui-tree` and the input commands wait up to 60 s and return `DEVICE_NOT_READY`, whose message says to look at the iPhone. Enter the passcode on the phone and run the command again. ([`ui-tree`](commands/ui-tree.md#on-an-iphone))
- **A free Apple ID signs the runner for 7 days.** The Personal Team's profile expires after 7 days, and the next command that needs the runner returns `RUNNER_NOT_INSTALLED`. Run `install-runner` again. The phone also asks once to trust the developer (Settings > General > VPN & Device Management, needs internet). ([`install-runner`](commands/install-runner.md))

## MCP clients

- **A cancelled call does not stop the device.** Cancelling a call (Esc in Claude Code) ends karagoz's work for it, but what reached the device finishes: a gesture plays to the end, and a cancelled `install` may leave the app installed. On Android the UiAutomation slot stays held for about 1-2 s, so a `ui_tree` right after can return `AUTOMATION_BUSY`. Read the screen before the next step. ([MCP server](mcp.md#behavior))
- **`codex exec` refuses `install` and `uninstall`.** Codex asks for approval before these two tools, and `codex exec` never asks, so it refuses them with `MCP tool call requires approval, but approval policy is never`. Run them in an interactive Codex session or from the CLI. ([MCP server](mcp.md#registration))
- **Claude Desktop does not update the extension.** Install the new `karagoz.mcpb` after each release. ([MCP server](mcp.md#registration))
