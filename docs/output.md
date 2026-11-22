# Output and errors

Every command prints exactly one line of JSON on stdout and exits, except `mcp`, which speaks JSON-RPC on stdout until stdin closes ([MCP server](mcp.md)).

That line is what you get whenever stdout is not a terminal: a pipe, the MCP server, or an agent's shell that runs commands without one (Claude Code's does). When stdout is a terminal, an agent's shell that runs commands in one included, [`devices`](commands/devices.md) and [`doctor`](commands/doctor.md) print a summary for a person instead, and every other command prints the same JSON indented over several lines. An error is the one line either way, and the exit code and stderr do not change.

- **Success:** the command's result object, exit code `0`.
- **Failure:** an error object, exit code `1`:

  ```json
  {"error":{"code":"DEVICE_NOT_FOUND","message":"device 'nosuch' from --device matches no device id or name. Listed: emulator-5554 (Medium_Phone_API_36.1)."}}
  ```

  The same message goes to stderr as `karagoz: <message>`. It can span more than one line when it quotes adb or Node output; the stdout line never does.

  `INSTALL_FAILED` from `install` and `UNINSTALL_FAILED` from `uninstall` add a `reason` field with the platform's own code for the failure: Android's code; on an iOS simulator simctl's `<domain>:<code>` (`IXUserPresentableErrorDomain:4`); on an iPhone the `<domain>:<code>` of the deepest error devicectl reports (`MIInstallerErrorDomain:13`); or `SYSTEM_APP` when `uninstall` is asked to remove an iOS system app:

  ```json
  {"error":{"code":"INSTALL_FAILED","message":"adb: failed to install /Users/me/app-v1.apk: Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected: Update version code 1 is older than current 2]","reason":"INSTALL_FAILED_VERSION_DOWNGRADE"}}
  ```

  No other code has it.

Branch on `error.code`, not on the message. Messages are for people and can change.

stderr also carries adb's own notices on success, such as `* daemon started successfully` when the adb server was not running. That first call takes about 3 s longer.

`karagoz --version` prints the package version as plain text and exits `0`. It wins over any command: `karagoz devices --version` prints the version.

## Update notice

A copy installed with `npm install -g` checks once a day whether a newer release is out. At a terminal, after a command succeeds, it can print one more line to stderr:

```
karagoz: 0.6.0 is available, you have 0.5.0. To update: npm install -g karagoz-mcp
```

The line comes from the last check, which karagoz keeps in `update.json` under `~/Library/Caches/karagoz` on macOS, `$XDG_CACHE_HOME/karagoz` or `~/.cache/karagoz` on Linux, and `%LOCALAPPDATA%\karagoz` on Windows. When that check is a day old or missing, karagoz starts a background process that asks the npm registry for the package's `latest` tag and writes the answer there; the command does not wait for it. The request is a plain GET of `-/package/karagoz-mcp/dist-tags` on `npm_config_registry` when it is set, else on `https://registry.npmjs.org/`, and sends nothing about you or your devices. A failed request is not retried until the next day.

The check stays off when stdout or stderr is not a terminal (a pipe, an agent's shell), when karagoz runs from a clone or from a project's `node_modules`, and in the copy `npx` runs, which npx brings up to date on every start. Set `KARAGOZ_NO_UPDATE_CHECK=1` or `NO_UPDATE_NOTIFIER=1` to turn it off; any value of `CI` turns it off too. With `min-release-age` in your npm config, the line can name a release that npm does not install yet. The MCP server shows the same check in its instructions ([MCP server](mcp.md#behavior)).

## Arguments

- Options can appear anywhere, before or after the command name. A repeated option keeps its last value.
- There are no short flags. A value that starts with `-` is read as an option: `--device=-x` passes it as a value, and a positional that starts with `-` goes after `--`, with options before it: `karagoz text --device emulator-5554 -- -5`.
- An empty value (`--out=`) is refused.
- An option the command does not take is refused: `'devices' does not take the option '--device'`.

All of these fail with `INVALID_ARGS` before any device is contacted.

## Coordinates

`screenshot` pixels, `ui-tree` bounds and the `tap` / `swipe` coordinates share one space: physical pixels of the current screen orientation, origin top left. A node's `bounds` of `[581,1905,754,2100]` can be tapped at its center, `(667.5, 2002.5)`, and that point is the same pixel in the screenshot. Decimals are allowed. On an iOS simulator with Xcode 27 the screenshot and the tree follow the interface orientation; with Xcode 26 the screenshot is the panel in portrait, whatever the interface orientation. On iOS, `ui-tree` bounds are the element's frame in points times `scale`, and `tap` and `swipe` take the same pixels: karagoz turns them for the interface orientation, and takes a `null` rotation as portrait.

`screenshot` reports `scale` (physical pixels per density-independent pixel on Android, per point on iOS) and `logical` size so a caller can convert to dp or points.
