# doctor

```
karagoz doctor
```

Reports which `adb` karagoz uses, its version, every other `adb` it could use, and how to install platform-tools when adb is missing or too old. On macOS it also reports the Xcode the simulator commands use: its folder and version, `simctl`, `swiftc`, `devicectl` and the helper cache, and what to fix; and for iPhones, the Apple teams karagoz's runner can be signed with, the runner builds this Mac has, and the `xcodebuild`, usbmuxd socket, `tar` and `log` the iPhone commands need. It changes nothing. No options.

**Output**

```json
{"adb":{"status":"ok","source":"PATH","path":"/opt/homebrew/bin/adb","version":"37.0.0-14910828","candidates":[{"source":"ANDROID_HOME","status":"unset"},{"source":"ANDROID_SDK_ROOT","status":"unset"},{"source":"PATH","status":"ok","path":"/opt/homebrew/bin/adb","version":"37.0.0-14910828"},{"source":"default","status":"ok","path":"/Users/me/Library/Android/sdk/platform-tools/adb","version":"36.0.2-14143358"}]}}
```

On macOS the same line goes on with `xcode`, shown here alone:

```json
{"xcode":{"status":"ok","source":"xcode-select","path":"/Applications/Xcode.app/Contents/Developer","version":"27.1","build":"27A9275","simctl":{"status":"ok","path":"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl","version":"1174.9.2"},"swiftc":{"status":"ok","path":"/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"},"devicectl":{"status":"ok","path":"/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"},"helper":{"status":"ok","path":"/Users/me/Library/Caches/karagoz/e465b8a54d020f31/ax"},"signing":{"status":"ok","teams":[{"id":"XXXXXXXXXX","name":"Example Team","free":false}]},"iosRunner":{"status":"ok","path":"/Users/me/Library/Caches/karagoz/runner/7daac8e099b4044e","teams":["XXXXXXXXXX"]},"xcodebuild":{"status":"ok","path":"/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"},"usbmuxd":{"status":"ok","path":"/var/run/usbmuxd"},"tar":{"status":"ok","path":"/usr/bin/tar"},"log":{"status":"ok","path":"/usr/bin/log"}}}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `adb.status` | string | `ok`, `outdated` or `failed`: the status of the candidate karagoz uses. `missing`: no candidate can be used. |
| `adb.source`, `adb.path`, `adb.version`, `adb.message` | string | Copied from the candidate karagoz uses, when it has them. |
| `adb.install` | string | Only when `status` is not `ok`: how to install platform-tools on this OS, the same text `ADB_NOT_FOUND` prints. |
| `adb.candidates` | array | The four places karagoz looks, in lookup order (see [Requirements](../requirements.md)). |
| `candidates[].source` | string | `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `PATH`, or `default` for Android Studio's default SDK. |
| `candidates[].status` | string | See below. |
| `candidates[].path` | string | When known: the file karagoz would run. For `PATH`, the path adb prints for itself in `adb version`, so it is absent when adb printed none; on Windows, the `adb.exe` found on `PATH`. |
| `candidates[].version` | string | With `ok` and `outdated`: the `Version` line of `adb version`, as printed. |
| `candidates[].message` | string | With `failed` and `outdated`: why, cut at 300 characters. |
| `xcode` | object | macOS only: the Xcode the iOS commands use, and what the iPhone commands need from this Mac. |
| `xcode.status` | string | `ok`, `outdated`, `failed` or `missing`, see below. |
| `xcode.source` | string | Which rule picked the developer folder, in the commands' order: `DEVELOPER_DIR`, `xcode-select` (`/var/db/xcode_select_link`), or `default` (`/Applications/Xcode.app/Contents/Developer`). Absent when none is there. |
| `xcode.path` | string | With `source`: the developer folder. |
| `xcode.version`, `xcode.build` | string | From that Xcode's `version.plist`, when it has them: `27.0`, `27A266a`. |
| `xcode.message` | string | When `status` is not `ok`: the first entry's message in the order `simctl`, `swiftc`, `devicectl`, `helper`, or for `outdated`, which commands need a newer Xcode. |
| `xcode.simctl`, `xcode.swiftc`, `xcode.devicectl`, `xcode.helper` | object | One entry each: `status`, `path` when known, and `message` when not `ok`: why. For `simctl` and `swiftc` `missing`, it is the text the command itself would fail with. |
| `xcode.simctl.version` | string | Unless `simctl` is `missing`: this Mac's CoreSimulator version. |
| `xcode.signing` | object | The teams [`install-runner`](install-runner.md) can sign with: `status` `ok` with `teams`, an array of `{id, name, free}` (`free` for a Personal Team), or `missing` with a `message`: no Apple account in Xcode, or an account whose teams Xcode has not saved yet (open a project's Signing & Capabilities tab once, or pass `--team`). `failed` when Xcode's preferences could not be read. |
| `xcode.iosRunner` | object | The runner builds for this karagoz and Xcode: `status` `ok` with `path` and `teams` (one build per team), `not built` (with `path` when an Xcode is selected), or `failed` with a `message`: the cache folder is not yours, or karagoz's runner sources are missing. |
| `xcode.xcodebuild` | object | The `xcodebuild` in the developer folder, which builds the runner (`install-runner`) and starts it (`ui-tree` and input on an iPhone). An entry like `swiftc`; `missing` has `install-runner`'s own text. |
| `xcode.usbmuxd` | object | The socket the runner and iPhone `logs` connect to, `/var/run/usbmuxd` (or `USBMUXD_SOCKET_ADDRESS` in its `UNIX:<path>` form). Read without connecting; its messages are the commands' `cannot reach usbmuxd at <path> (<code>)`. |
| `xcode.tar`, `xcode.log` | object | The `tar` and `log` iPhone `logs` runs, found on `PATH` as the command finds them (no `PATH`: `/usr/bin:/bin`). `missing` has no `path` and the command's text: `tar not found on PATH`. |

| Status | Means |
| --- | --- |
| `ok` | `adb version` exited `0` and reported platform-tools 30.0.0 or newer. |
| `outdated` | `adb version` exited `0` and reported a version below 30.0.0. |
| `failed` | Something is there but cannot be used: it did not start, exited non-zero, did not answer within 10 s, or printed no `Version` line. The message says which. |
| `missing` | Nothing at that location. For `PATH`: no `adb` on `PATH`, or on macOS and Linux only ones that fail to start with `ENOENT` (see Notes). |
| `unset` | No location to check: the variable is unset or empty. For `default`: Windows without `LOCALAPPDATA`. |

| `xcode.status` | Means |
| --- | --- |
| `ok` | `simctl`, `swiftc` and `devicectl` are `ok`, and the helper is `ok` or `not built`. `signing`, `iosRunner`, `xcodebuild`, `usbmuxd`, `tar` and `log` do not count: a Mac without iPhones needs none of them. Check their own `status`. |
| `outdated` | As `ok`, with an Xcode below 27. |
| `failed` | `simctl`, `swiftc` or `devicectl` is not `ok`, or the helper is `failed`. |
| `missing` | `simctl` and `swiftc` are both `missing`: no Xcode karagoz can use, such as the Command Line Tools alone. |

| Entry status | Means |
| --- | --- |
| `ok` | `simctl`, `swiftc`, `devicectl`, `xcodebuild`, `tar`, `log`: a file karagoz can run. `usbmuxd`: a socket karagoz can read and write. `helper`: built, and a file you own. |
| `missing` | Nothing at `path`. With no developer folder, `swiftc` and `xcodebuild` have no `path` and say no Xcode is selected. `tar` and `log` have no `path`. |
| `failed` | There but not runnable: `cannot run <path> (EACCES)`. For `tar` and `log`, the first such file on `PATH` when none after it runs. For `usbmuxd`, not a socket (`ENOTSOCK`) or not yours to use (`EACCES`). For `simctl` and `devicectl`, also when Xcode's first launch has not finished: `the selected Xcode expects CoreSimulator <version>, this Mac has <version>: open Xcode once to finish installing its components` (CoreDevice for `devicectl`). And, with `DEVELOPER_DIR` set, when that Xcode's own `simctl` or `devicectl` would run `xcodebuild -runFirstLaunch` on every call because a newer Xcode installed a newer framework: `the Xcode in DEVELOPER_DIR expects CoreSimulator <version> but this Mac has <version> from a newer Xcode, so its simctl runs xcodebuild -runFirstLaunch on every call: point DEVELOPER_DIR at the newest Xcode, or unset it`. For `helper`, the cache folder or binary is not yours or not the right type: delete `~/Library/Caches/karagoz`. |
| `not built` | `helper` only: the next `ui-tree`, `tap`, `swipe`, `text` or `key` compiles it. |

The exit code is `0` whenever the report is printed, with adb or Xcode missing or broken as well. Check `adb.status` and `xcode.status`.

**Errors:** `INVALID_ARGS` for any argument or option (`'doctor' does not take the option '--device'`), `INTERNAL`.

**Notes**

- Only `adb version` runs, on every candidate at once. It never connects to the adb server, so server trouble does not show up here; the other commands report it as `ADB_TIMEOUT`.
- For Xcode, doctor reads files, and runs only `plutil`, which converts Xcode's preference file to read the teams and reads CoreDevice's version; it cannot start the simulator service or Xcode's first launch. A stuck simulator service shows in the `errors` of `devices`, not here. It never runs `xcodebuild` and never connects to usbmuxd, so a socket that is there but answers nobody shows up only in the iPhone commands. Paired iPhones are listed by `devices`, not here.
- `xcode` is absent on Linux and Windows.
- Nothing is installed.
- `outdated` means below platform-tools 30.0.0, where `install` fails: it passes `--no-incremental`, which older versions forward to the device, and the device rejects it. Debian 12 ships 29.0.6. The other commands still work.
- `xcode.status` `outdated` means below Xcode 27, where `tap`, `swipe` and `key` return `NOT_SUPPORTED` on a simulator. The other commands work.
- `version` keeps the builder's suffix: digits from Google, `-debian`, `-android-tools`. Debian's 8.1.0 package prints its package version, `1:8.1.0+r23-8`, and is `outdated`. `1.0.41` in `Android Debug Bridge version 1.0.41` is adb's protocol number and is not shown.
- For `PATH`, `path` is the symlink as invoked on macOS (`/opt/homebrew/bin/adb`) and the resolved file on Linux.
- A candidate that is there but fails to start with `ENOENT` (a script whose interpreter is missing, a broken link) is shown `failed`, and karagoz moves on to the next one, as every command does. Any other failure stops the lookup at that candidate. The exception is `PATH` on macOS and Linux: `adb` runs by name there, the error does not say which file failed, and the candidate is shown `missing`.
- An invalid `ANDROID_ADB_SERVER_PORT` makes `adb version` itself fail, so every `adb` found is `failed` with adb's message: `adb: $ANDROID_ADB_SERVER_PORT must be a positive number less than 65535: got "abc"`.
- Took 0.15 s on a Mac with two adbs and Xcode; 1.4 s on a cold first run. A candidate that hangs costs 10 s, and the others run meanwhile.
- Windows and Linux were not run.
