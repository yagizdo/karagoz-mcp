# MCP server

How to register `karagoz mcp` with each client, and what its tools take, return and do.

`mcp` takes no arguments or options. It exits when stdin closes, or on SIGINT or SIGTERM.

## Registration

Every example runs the published package with `npx`. From a clone, use `node /abs/path/karagoz-mcp/packages/karagoz/dist/cli.js mcp` instead.

Claude Code and Codex were run against this server. The Claude Desktop, Cursor and VS Code entries follow their documentation and were not run.

**Claude Code**

```sh
claude mcp add karagoz -- npx -y karagoz-mcp mcp
```

The server starts in the directory `claude` started in, with the shell's environment. A call still running after 2 minutes becomes a background task.

**Claude Desktop**, in `~/Library/Application Support/Claude/claude_desktop_config.json` on macOS or `%APPDATA%\Claude\claude_desktop_config.json` on Windows; quit and restart Desktop after editing:

```json
{"mcpServers":{"karagoz":{"command":"npx","args":["-y","karagoz-mcp","mcp"],"env":{"ANDROID_HOME":"/Users/me/Library/Android/sdk"}}}}
```

Desktop starts servers with part of your environment and possibly `/` as the working directory, so set `ANDROID_HOME` in `env` when `adb` is not on the `PATH` it passes, and use absolute paths.

**Cursor**, in `.cursor/mcp.json` in the project or `~/.cursor/mcp.json`:

```json
{"mcpServers":{"karagoz":{"type":"stdio","command":"npx","args":["-y","karagoz-mcp","mcp"]}}}
```

**VS Code**, in `.vscode/mcp.json` in the workspace:

```json
{"servers":{"karagoz":{"type":"stdio","command":"npx","args":["-y","karagoz-mcp","mcp"]}}}
```

or from the command line: `code --add-mcp '{"name":"karagoz","command":"npx","args":["-y","karagoz-mcp","mcp"]}'`.

**Codex**, in `~/.codex/config.toml`:

```toml
[mcp_servers.karagoz]
command = "npx"
args = ["-y", "karagoz-mcp", "mcp"]
env_vars = ["ANDROID_HOME", "ANDROID_SDK_ROOT", "KARAGOZ_DEVICE", "ANDROID_SERIAL", "DEVELOPER_DIR"]
tool_timeout_sec = 600
```

Codex passes a server only a short list of environment variables; `env_vars` forwards the ones karagoz reads. `tool_timeout_sec` covers long `tap` waits and big installs. `install` and `uninstall` ask for approval; `codex exec`, which never asks, refuses them with `MCP tool call requires approval, but approval policy is never`.

## Tools

| Tool | Command | Arguments | Marked |
| --- | --- | --- | --- |
| `devices` | [`devices`](commands/devices.md) | none | read-only |
| `screenshot` | [`screenshot`](commands/screenshot.md) | `out`, `inline`, `device` | |
| `ui_tree` | [`ui-tree`](commands/ui-tree.md) | `device`, `detail` | read-only |
| `tap` | [`tap`](commands/tap.md) | `x`, `y`, `text`, `id`, `timeout`, `device` | |
| `long_press` | [`long-press`](commands/long-press.md) | `x`, `y`, `text`, `id`, `duration`, `timeout`, `device` | |
| `double_tap` | [`double-tap`](commands/double-tap.md) | `x`, `y`, `text`, `id`, `timeout`, `device` | |
| `swipe` | [`swipe`](commands/swipe.md) | `x1`, `y1`, `x2`, `y2` (required), `duration`, `device` | |
| `text` | [`text`](commands/text.md) | `text` (required), `device` | |
| `key` | [`key`](commands/key.md) | `key` (required), `device` | |
| `install` | [`install`](commands/install.md) | `apk` (required), `device` | destructive |
| `launch` | [`launch`](commands/launch.md) | `package` (required), `device` | |
| `open_url` | [`open-url`](commands/open-url.md) | `url` (required), `app`, `device` | open world |
| `terminate` | [`terminate`](commands/terminate.md) | `package` (required), `device` | |
| `uninstall` | [`uninstall`](commands/uninstall.md) | `package` (required), `device` | destructive |
| `logs` | [`logs`](commands/logs.md) | `package`, `since`, `lines`, `device` | read-only |
| `doctor` | [`doctor`](commands/doctor.md) | none | read-only |
| `install_runner` | [`install-runner`](commands/install-runner.md) | `team`, `device` | open world |
| `uninstall_runner` | [`uninstall-runner`](commands/uninstall-runner.md) | `device` | destructive |

"Marked" is the tool's annotation: `readOnlyHint`, `destructiveHint`, or `openWorldHint` for `install_runner`, whose build talks to Apple's developer service, and for `open_url`, whose URL can send the device to any host on the web. The other 11 carry `destructiveHint: false`, the other 16 `openWorldHint: false`, and all 18 a title. Clients use these to decide what needs approval and what may run in parallel.

## Arguments

- The names are the CLI's option and positional names: `tap {"x": 540, "y": 1200}` is `karagoz tap 540 1200`, and `logs {"lines": 5}` is `karagoz logs --lines 5`. `ui_tree`, `long_press` and `double_tap` are renamed, because Codex turns `-` into `_`.
- Values go through the CLI's own checks, as the text of the value (`12.5` is `12.5`), and the messages keep CLI syntax: `long_press {"x": 1, "y": 2, "duration": 1.5}` fails with `--duration must be a whole number of milliseconds (got '1.5')`.
- `null` counts as not given. An argument the tool does not take is refused: `'devices' does not take the option '--foo'`.
- `inline` exists only here: `true` or `false`, else `INVALID_ARGS` `inline must be true or false (got 'yes')`.
- `out` and `apk` should be absolute. A relative path resolves against the server's working directory, which the client picks.
- `device` picks one of several devices. Without it the server uses `KARAGOZ_DEVICE`, then `ANDROID_SERIAL` from its own environment, then the only device ([Device selection](device-selection.md)). Codex passes these variables only through `env_vars`.

## Results

- Success: one text block with the command's JSON line.
- Failure: `isError: true` and one text block with the CLI's error envelope. `karagoz: <message>` goes to stderr, as in the CLI.
- An unknown tool name is a JSON-RPC error, `-32602` `Unknown tool: <name>`.
- `screenshot` with `inline: true` adds the full-resolution PNG as an `image` block. Clients scale it before the model sees it (Claude Code sent a 1080x2400 capture as a JPEG), so take coordinates from `ui_tree` bounds, or from `pixels` and `scale`, never from the image.

A real exchange, one line per message, `-->` sent and `<--` received. The `data` string is cut.

```
--> {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"devices","arguments":{}}}
<-- {"result":{"content":[{"type":"text","text":"{\"devices\":[{\"id\":\"emulator-5554\",\"platform\":\"android\",\"kind\":\"emulator\",\"state\":\"device\",\"name\":\"Medium_Phone_API_36.1\"}]}"}]},"jsonrpc":"2.0","id":2}
--> {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tap","arguments":{"x":1}}}
<-- {"result":{"content":[{"type":"text","text":"{\"error\":{\"code\":\"INVALID_ARGS\",\"message\":\"'tap' needs <x> <y>\"}}"}],"isError":true},"jsonrpc":"2.0","id":3}
--> {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"screenshot","arguments":{"out":"/Users/me/home.png","inline":true}}}
<-- {"result":{"content":[{"type":"text","text":"{\"path\":\"/Users/me/home.png\",\"device\":\"emulator-5554\",\"pixels\":{\"width\":1080,\"height\":2400},\"logical\":{\"width\":411.42857142857144,\"height\":914.2857142857143},\"scale\":2.625,\"safeArea\":{\"top\":63,\"right\":0,\"bottom\":63,\"left\":0},\"rotation\":0}"},{"type":"image","data":"iVBORw0KGgoAAAANSUhEUgAABDgAAAlgCAYAAABt...","mimeType":"image/png"}]},"jsonrpc":"2.0","id":4}
--> {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ui-tree","arguments":{}}}
<-- {"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"Unknown tool: ui-tree"}}
```

## Behavior

- Calls run in parallel, except UiAutomation reads (`ui_tree`, and `tap`, `long_press` or `double_tap` with `text` or `id`), which take turns per device inside one server. Another process that holds UiAutomation still causes `AUTOMATION_BUSY`.
- A cancelled call kills its adb child at once and gets no response. The device does not stop with it: it keeps its UiAutomation slot for about 1-2 s, so a `ui_tree` right after can get `AUTOMATION_BUSY`; a gesture already sent finishes on the device; and a cancelled `install` may leave the app installed. Esc in Claude Code cancels the running call: the adb dump was gone within 0.3 s and the server kept running.
- stdin closing, SIGINT and SIGTERM cancel every call the same way; the process exits with `0`, `130` and `143`.
- The server keeps the `adb` it found for the whole session. If that file disappears (`ENOENT`), the next call looks it up again.
