# Karagöz

Device automation for mobile apps. One tool for four targets: Android emulator, Android physical device, iOS simulator, iOS physical device. It is a CLI, and `karagoz mcp` serves the same commands to an AI agent as an [MCP server](#mcp-server).

Website: [karagozmcp.com](https://karagozmcp.com/?utm_source=github&utm_medium=readme)

> **Status: early development.** Twelve commands work on the Android emulator, `devices`, `screenshot`, `ui-tree`, `tap`, `swipe`, `text`, `key`, `install`, `launch`, `terminate`, `uninstall` and `logs` also work on a physical Android device, `doctor` reports the `adb` and Xcode they use, and the MCP server offers all thirteen to an AI agent. On an iOS simulator, all thirteen work. On macOS, `devices` also lists the iPhones connected to the Mac and `screenshot` captures a paired one; no other command runs on an iPhone yet. Nothing is published to npm. See [Status](#status).

## Contents

- [Status](#status)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Concepts](#concepts)
  - [Device selection](#device-selection)
  - [Coordinates](#coordinates)
  - [Accessibility tree first](#accessibility-tree-first)
- [Output and errors](#output-and-errors)
  - [Arguments](#arguments)
  - [Error codes](#error-codes)
- [Commands](#commands)
  - [devices](#devices)
  - [screenshot](#screenshot)
  - [ui-tree](#ui-tree)
  - [tap](#tap)
  - [swipe](#swipe)
  - [text](#text)
  - [key](#key)
  - [install](#install-1)
  - [launch](#launch)
  - [terminate](#terminate)
  - [uninstall](#uninstall)
  - [logs](#logs)
  - [doctor](#doctor)
- [MCP server](#mcp-server)
- [Scope](#scope)
- [Development](#development)
- [Name](#name)
- [License](#license)

## Status

| Command | Android emulator | Android device | iOS simulator | iOS device |
| --- | --- | --- | --- | --- |
| [`devices`](#devices) | done | done | done | done |
| [`screenshot`](#screenshot) | done | done | done | done |
| [`ui-tree`](#ui-tree) | done | done | done | planned |
| [`tap`](#tap) | done | done | done | planned |
| [`swipe`](#swipe) | done | done | done | planned |
| [`text`](#text) | done | done | done | planned |
| [`key`](#key) | done | done | done | planned |
| [`install`](#install-1) | done | done | done | planned |
| [`launch`](#launch) | done | done | done | planned |
| [`terminate`](#terminate) | done | done | done | planned |
| [`uninstall`](#uninstall) | done | done | done | planned |
| [`logs`](#logs) | done | done | done | planned |
| [`doctor`](#doctor) | done | done | done | planned |
| [MCP server](#mcp-server) | done | done | done | |

"Done" means tested against a live emulator: macOS, an API 36 image (Android 16), 1080x2400 at 420 dpi. In the iOS simulator column it means the step's smoke passes on macOS: `smoke/3.1-devices-ios.sh` for `devices`, `smoke/3.2-screenshot-ios.sh` for `screenshot`, `smoke/3.3-ui-tree-ios.sh` for `ui-tree`, `smoke/3.4-input-ios.sh` for `tap`, `swipe`, `text` and `key`, `smoke/3.5-app-lifecycle-ios.sh` for `install`, `launch`, `terminate` and `uninstall`, `smoke/3.6-logs-ios.sh` for `logs`. `devices`, `screenshot` and `ui-tree` were tested on a physical Samsung phone (Android 14) over USB, and `tap`, `swipe`, `text`, `key`, `install`, `launch`, `terminate`, `uninstall` and `logs` on an Infinix phone (Android 12) over USB. No other command has been run on one yet. `doctor` touches no device; its row means tested on the same Mac with fake and real `adb` binaries, and, in the iOS simulator column, with fake and real Xcode setups (`smoke/3.7-doctor-ios.sh`). For the MCP server, done means `smoke/M-mcp.sh` passes against the live emulator and Claude Code and Codex called its tools; in the Android device column it means its tools returned results from a phone over USB, and in the iOS simulator column, its tools returned results from a booted simulator. Windows and Linux have not been run.

## Requirements

- **Node 22 or newer.**
- **`adb`** from Android platform-tools, for Android targets. karagoz does not bundle it; it looks for it on every run, in this order:
  1. `$ANDROID_HOME/platform-tools/adb`
  2. `$ANDROID_SDK_ROOT/platform-tools/adb`
  3. `adb` on `PATH`
  4. Android Studio's default SDK: `~/Library/Android/sdk` on macOS, `~/Android/Sdk` on Linux, `%LOCALAPPDATA%\Android\Sdk` on Windows

  An empty variable is skipped. The first `adb` that starts is used for the rest of the run, so a broken `adb` under `ANDROID_HOME` does not fall back to `PATH`. The exception is an `adb` that fails to start with `ENOENT` (a missing interpreter or a broken link): it counts as not there, and the next one is tried. Under `karagoz mcp` the run is the whole server session, and if the `adb` in use disappears (`ENOENT`), the next call looks it up again. An `adb` that appears mid-session higher in the list is not picked up until the server restarts. [`karagoz doctor`](#doctor) shows which one is used and why. `install` needs platform-tools 30.0.0 or newer. When none is found:

  ```json
  {"error":{"code":"ADB_NOT_FOUND","message":"adb not found (tried ..., PATH). Install platform-tools (brew install --cask android-platform-tools, or download https://developer.android.com/tools/releases/platform-tools and add it to PATH) or set ANDROID_HOME to your Android SDK."}}
  ```

- **A running emulator** (`emulator -avd <name>`), or for `devices`, `screenshot`, `ui-tree`, `tap`, `swipe`, `text`, `key`, `install`, `launch`, `terminate`, `uninstall` and `logs`, a phone with USB debugging on, in state `device`, or for `devices`, `screenshot`, `ui-tree`, `tap`, `swipe`, `text`, `key`, `install`, `launch`, `terminate`, `uninstall` and `logs` on macOS, a booted iOS simulator (`open -a Simulator`; on Xcode 27, `xcrun simctl boot <name>`), or for `devices` and `screenshot` on macOS, an iPhone connected to the Mac (for `screenshot`, paired with the Mac and with Developer Mode on: Settings > Privacy & Security > Developer Mode). karagoz installs nothing on a device by itself; `install` installs only the app you pass it. A phone that adb cannot see is missing from the list: on Windows without the phone maker's USB driver, on a Mac laptop where "Allow accessory to connect" was refused, or in fastboot mode.
- For `smoke/1.5-app-lifecycle.sh`, and for `smoke/2.5-app-lifecycle-physical.sh` when a phone is attached: a JDK and Android SDK build-tools with one platform. Both smokes build their own test APK, `dev.karagoz.smoke`, and remove it at the end. See [Development](#development).
- For `ui-tree` and `tap --text` / `--id`: the screen is on, and no other UiAutomation client is connected (Appium, Maestro, `uiautomator events`). For input to reach apps, the screen is also unlocked: on a lock screen `text` and `key` type into the PIN field, and a wrong PIN counts as a failed unlock attempt; with the screen off, taps are dropped and keys still arrive. Both exit `0`.
- **Xcode, opened once**, for iOS simulators in `devices`, `screenshot`, `ui-tree`, `tap`, `swipe`, `text`, `key`, `install`, `launch`, `terminate`, `uninstall` and `logs` (macOS only). karagoz runs CoreSimulator's own `simctl` (`/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl`), or `$DEVELOPER_DIR/usr/bin/simctl` when `DEVELOPER_DIR` is set. The Command Line Tools alone have no `simctl`, and no `swiftc` for the helper below. For iPhones in `devices`, Xcode 15 or newer: karagoz runs CoreDevice's own `devicectl` (`/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl`), or `$DEVELOPER_DIR/usr/bin/devicectl` when `DEVELOPER_DIR` is set; the Command Line Tools alone have none. For `screenshot` on an iPhone, Xcode 27 or newer, opened once: Xcode 26's `devicectl` has no `device capture screenshot`. On macOS every command that targets a device runs `simctl` and `devicectl` too, to list simulators and iPhones ([Device selection](#device-selection)).
- The first `ui-tree`, `tap`, `swipe`, `text` or `key` on a simulator compiles a small helper with the selected Xcode's `swiftc` (`DEVELOPER_DIR`, else the `xcode-select` one, else `/Applications/Xcode.app`) into `~/Library/Caches/karagoz/`. That takes a few seconds, happens again after an Xcode update, and the directory is safe to delete.
- On a simulator, `tap`, `swipe` and `key` need Xcode 27 or newer: they go to the simulator's own input service, which older Xcodes do not have, and return `NOT_SUPPORTED` there. `text` loads Xcode's XCUIAutomation frameworks and puts the simulator in automation mode for the length of the call, as a UI test does; a UI test running on the same simulator makes it fail with `AUTOMATION_BUSY`. When the call ends, the simulator turns its app accessibility setting off; `text` writes it back if it was on, so later `ui-tree` reads still see apps.

## Install

Not on npm yet. From source:

```sh
git clone https://github.com/yagizdo/karagoz-mcp.git
cd karagoz-mcp
npm install
npm run build          # writes dist/: cli.js and two chunks
node dist/cli.js devices
```

`npm link` puts `karagoz` on your `PATH`. The examples below use `karagoz`.

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

## Concepts

### Device selection

Every command except `devices` works on one device, picked in this order:

1. `--device <id>`
2. the `KARAGOZ_DEVICE` environment variable
3. the `ANDROID_SERIAL` environment variable
4. the only listed device

A variable is ignored when anything above it is given; an empty one counts as unset. `KARAGOZ_DEVICE` names a device on either platform.

The value is matched against every listed id first, exactly: adb serials (`emulator-5554`) and, on macOS, the UDIDs of booted simulators and connected iPhones. If no id matches, it is matched against every `name` that [`devices`](#devices) prints: an emulator's AVD name (`Medium_Phone_API_36.1`), a phone's model (`SM-S908N`), a simulator's name (`iPhone 17 Pro`) or an iPhone's model (`iPhone 14 Pro Max`), exactly and case-sensitively. A name matched on both platforms, or by an iPhone and a simulator, is ambiguous; neither wins.

| Situation | Error |
| --- | --- |
| A value is given and nothing matches | `DEVICE_NOT_FOUND`, listing what is connected |
| No value, nothing connected | `NO_DEVICE` |
| No value and two or more devices listed (in any state), or a name that matches two entries: the same AVD listed as `emulator-5554` and `127.0.0.1:5555`, or two phones of the same model | `DEVICE_AMBIGUOUS` |
| The picked device is an iPhone and the command is not `screenshot`: no other command runs on one yet. This comes before any readiness check. | `NOT_SUPPORTED` |
| The picked device is not in state `device` (`offline`, `unauthorized`, ...), a simulator not `Booted` (`Booting`, `Shutting Down`), or an iPhone not `paired` (`unpaired`, `pairingInProgress`; the message says what to do on the phone) | `DEVICE_NOT_READY` |

karagoz never guesses between devices. There is no config file.

On macOS every command that targets a device lists booted simulators and connected iPhones next to adb's devices, in parallel. A missing `adb`, `simctl` or `devicectl` means that listing has no devices. Any other failure of one listing stops the command, unless the value is an id another listing returned: a hung simulator service makes a bare call fail with `SIMCTL_TIMEOUT` after 30 s, a hung CoreDevice service with `DEVICECTL_TIMEOUT` after 10 s. When nothing is listed and `adb` is missing, the error is `ADB_NOT_FOUND`.

A phone connected over Wi-Fi as well as USB is listed twice, once per serial, and its model matches both: pick it by serial then. Quote a `--device` value that contains spaces, as some mDNS serials do.

### Coordinates

`screenshot` pixels, `ui-tree` bounds and the `tap` / `swipe` coordinates share one space: physical pixels of the current screen orientation, origin top left. A node's `bounds` of `[581,1905,754,2100]` can be tapped at its center, `(667.5, 2002.5)`, and that point is the same pixel in the screenshot. Decimals are allowed. On an iOS simulator with Xcode 27 the screenshot and the tree follow the interface orientation; with Xcode 26 the screenshot is the panel in portrait, whatever the interface orientation. On iOS, `ui-tree` bounds are the element's frame in points times `scale`, and `tap` and `swipe` take the same pixels: karagoz turns them for the interface orientation, and takes a `null` rotation as portrait.

`screenshot` reports `scale` (physical pixels per density-independent pixel on Android, per point on iOS) and `logical` size so a caller can convert to dp or points.

### Accessibility tree first

To see the screen, read `ui-tree` before taking a screenshot. The tree is text a program can search, costs a few hundred to a few thousand tokens, and gives the bounds needed to tap. A screenshot is written to disk and returned as a path; the CLI never prints the image.

## Output and errors

Every command prints exactly one line of JSON on stdout and exits, except `mcp`, which speaks JSON-RPC on stdout until stdin closes ([MCP server](#mcp-server)).

- **Success:** the command's result object, exit code `0`.
- **Failure:** an error object, exit code `1`:

  ```json
  {"error":{"code":"DEVICE_NOT_FOUND","message":"device 'nosuch' from --device matches no device id or name. Listed: emulator-5554 (Medium_Phone_API_36.1)."}}
  ```

  The same message goes to stderr as `karagoz: <message>`. It can span more than one line when it quotes adb or Node output; the stdout line never does.

  `INSTALL_FAILED` and `UNINSTALL_FAILED` add a `reason` field with the platform's own code for the failure: Android's code, or on an iOS simulator simctl's `<domain>:<code>` (`IXUserPresentableErrorDomain:4`), or `SYSTEM_APP` when `uninstall` is asked to remove a simulator's system app:

  ```json
  {"error":{"code":"INSTALL_FAILED","message":"adb: failed to install /Users/me/app-v1.apk: Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected: Update version code 1 is older than current 2]","reason":"INSTALL_FAILED_VERSION_DOWNGRADE"}}
  ```

  No other code has it.

Branch on `error.code`, not on the message. Messages are for people and can change.

stderr also carries adb's own notices on success, such as `* daemon started successfully` when the adb server was not running. That first call takes about 3 s longer.

`karagoz --version` prints the version as plain text (`0.0.0`) and exits `0`. It wins over any command: `karagoz devices --version` prints the version.

### Arguments

- Options can appear anywhere, before or after the command name. A repeated option keeps its last value.
- There are no short flags. A value that starts with `-` is read as an option: `--device=-x` passes it as a value, and a positional that starts with `-` goes after `--`, with options before it: `karagoz text --device emulator-5554 -- -5`.
- An empty value (`--out=`) is refused.
- An option the command does not take is refused: `'devices' does not take the option '--device'`.

All of these fail with `INVALID_ARGS` before any device is contacted.

### Error codes

The set is closed. Any failure without a code of its own is reported as `INTERNAL`.

| Code | Meaning | From |
| --- | --- | --- |
| `NO_COMMAND` | No command given. The message lists the commands. | all |
| `UNKNOWN_COMMAND` | The command name is not known. | all |
| `INVALID_ARGS` | Missing, extra, malformed or unknown arguments, an unknown key name or one with no iOS key on a simulator (`BACK`), an app path that is not an existing `.apk` or `.ipa` file or `.app` directory, an app for the other platform, a screenshot `--out` that does not end in `.png`, a malformed package name, a `--since` that is not Unix time in seconds, or a `--lines` outside 1 to 999999999. | all |
| `ADB_NOT_FOUND` | No `adb` found. See [Requirements](#requirements). | all that reach adb, except `doctor`, which reports these in its output; `devices` reports them in `errors` when the other platform could be listed |
| `ADB_TIMEOUT` | adb did not answer in time: 10 s per call, 20 s for a `ui-tree` read, 10 s plus the duration for a long press or swipe, 30 s plus 1 s per started MB for `install`, 30 s for the start in `launch`. The message suggests `adb kill-server`; for `ui-tree` the cause is more often a stuck dump, and for `install` an install prompt on the phone, which the message names first. | all that reach adb, except `doctor`, which reports these in its output; `devices` reports them in `errors` when the other platform could be listed |
| `ADB_FAILED` | adb exited with an error. The message is adb's stderr, or Node's error when adb printed nothing. For `launch`, `terminate` and `uninstall` it can also be the error the device command printed. For `logs`, logcat's own error text or output that is not whole log records. A device that disconnects mid-command ends here. | all that reach adb, except `doctor`, which reports these in its output; `devices` reports them in `errors` when the other platform could be listed |
| `SIMCTL_NOT_FOUND` | No `simctl` found: Xcode is missing or was never opened, or `DEVELOPER_DIR` points somewhere without one. See [Requirements](#requirements). | `devices`, inside `errors`; `screenshot`, `install`, `launch`, `terminate`, `uninstall` and `logs` on a simulator; on macOS, every command that targets a device (listing, see [Device selection](#device-selection)) |
| `SIMCTL_TIMEOUT` | simctl did not answer in 30 s; for `install`, 30 s plus 1 s per started MB of the file (31 s for a `.app`). For `logs`, the read did not finish in 30 s; the message says what to pass to read less. | `devices`, inside `errors`; `screenshot`, `install`, `launch`, `terminate`, `uninstall` and `logs` on a simulator; on macOS, every command that targets a device (listing, see [Device selection](#device-selection)) |
| `SIMCTL_FAILED` | simctl exited with an error, or printed something karagoz does not expect. The message is simctl's stderr, or Node's error when simctl printed nothing; for unexpected output, `unexpected simctl output:` and its first line. For `logs`, `log`'s own error, or output that is not `log show`'s records. | `devices`, inside `errors`; `screenshot`, `install`, `launch`, `terminate`, `uninstall` and `logs` on a simulator; on macOS, every command that targets a device (listing, see [Device selection](#device-selection)) |
| `DEVICECTL_NOT_FOUND` | No `devicectl` found: Xcode older than 15, or never opened, or only the Command Line Tools, or `DEVELOPER_DIR` points somewhere without one. See [Requirements](#requirements). | `devices`, inside `errors`; on macOS, every command that targets a device (listing, see [Device selection](#device-selection)) |
| `DEVICECTL_TIMEOUT` | devicectl did not answer in 10 s; 30 s for `screenshot` on an iPhone. | `devices`, inside `errors`; `screenshot` on an iPhone; on macOS, every command that targets a device (listing, see [Device selection](#device-selection)) |
| `DEVICECTL_FAILED` | devicectl exited with an error, or printed something karagoz does not expect. The message is devicectl's stderr, or Node's error when it printed nothing; for unexpected output, `unexpected devicectl output:` and its first line. For `screenshot` on an iPhone, any capture failure not listed under `DEVICE_NOT_READY`, such as no connection to the phone, a developer disk image that could not be mounted, or a second capture of the same phone while one runs. | `devices`, inside `errors`; `screenshot` on an iPhone; on macOS, every command that targets a device (listing, see [Device selection](#device-selection)) |
| `NO_DEVICE` | No device connected and none named. On macOS the message also names booting a simulator. | all but `devices` and `doctor` |
| `DEVICE_NOT_FOUND` | The named device is not connected. | all but `devices` and `doctor` |
| `DEVICE_AMBIGUOUS` | More than one device and none named, or a name that matches more than one. | all but `devices` and `doctor` |
| `DEVICE_NOT_READY` | The device is `offline`, `unauthorized` or similar, or the simulator is `Booting` or `Shutting Down`, or its input service did not answer within 4 s (`tap`, `swipe`, `key` right after a boot), or for `screenshot` an iPhone that is not paired yet, has Developer Mode off, is no longer paired with this Mac, or is locked since it restarted. The message says what to do. | all but `devices` and `doctor` |
| `HELPER_FAILED` | The iOS helper cannot run on this Mac: no Xcode selected, no `swiftc` (the Command Line Tools are not enough), a failed compile, a crash, an Xcode that changed a private interface karagoz uses, or input the simulator did not take (no automation session, typing that failed, no answer within 30 s). The message says which and what to do. | `ui-tree`, `tap`, `swipe`, `text`, `key` on a simulator |
| `NOT_SUPPORTED` | The device is an iOS simulator with Xcode 26 or older: `'tap' on iOS simulators needs Xcode 27 or later`. Or the device is an iPhone and the command is not `screenshot`: `device <UDID> is an iPhone; karagoz runs only screenshot on one yet.` Or `screenshot` on an iPhone with a `devicectl` older than Xcode 27's: `'screenshot' on an iPhone needs Xcode 27 or later: ...`. Argument checks come first. | `tap`, `swipe`, `key`; `screenshot` on an iPhone before Xcode 27; for an iPhone, all but `devices`, `screenshot` and `doctor` |
| `CAPTURE_FAILED` | The screen could not be read: bad screenshot data, missing display info, a uiautomator failure, or on iOS a read the helper could not finish. The message says which. | `screenshot`, `ui-tree`, `tap --text/--id` |
| `AUTOMATION_BUSY` | Another UiAutomation client holds the device; on a simulator, a UI test holds automation mode. | `ui-tree`, `tap --text/--id`; `text` on a simulator |
| `WRITE_FAILED` | The screenshot file could not be written. | `screenshot` |
| `TEXT_UNSUPPORTED` | The text has a character the target cannot type: on Android anything but printable ASCII, newline, tab, `ç`, `Ç` and `ß`; on a simulator a control character other than newline and tab. | `text` |
| `ELEMENT_NOT_FOUND` | No node matches. | `tap --text/--id` |
| `ELEMENT_AMBIGUOUS` | More than one node matches. | `tap --text/--id` |
| `ELEMENT_COVERED` | The node's center is under the on-screen keyboard. | `tap --text/--id` |
| `INPUT_BLOCKED` | The device does not let adb inject input; on Xiaomi, Redmi and POCO, "USB debugging (Security settings)" is off; on vivo and iQOO, "USB simulated click". | `tap`, `swipe`, `text`, `key` |
| `INSTALL_FAILED` | The device refused the app. `reason` is Android's code, or simctl's `<domain>:<code>` on a simulator. | `install` |
| `UNINSTALL_FAILED` | The device refused to remove the app, or it is a simulator's system app (`reason` `SYSTEM_APP`). `reason` is Android's code, or simctl's `<domain>:<code>` on a simulator. | `uninstall` |
| `APP_NOT_FOUND` | The package is not installed. | `launch`, `terminate`, `uninstall`, `logs` |
| `APP_NOT_LAUNCHABLE` | The package is installed but has no activity a launcher can start. | `launch` on Android |
| `INTERNAL` | A bug in karagoz. Please report it with the message. | all |

## Commands

| Command | Does |
| --- | --- |
| [`devices`](#devices) | List connected devices |
| [`screenshot`](#screenshot) | Save a full-resolution PNG and return its path with scale metadata |
| [`ui-tree`](#ui-tree) | Return the accessibility tree of the focused window |
| [`tap`](#tap) | Tap or long-press a point, or a node found by text or id |
| [`swipe`](#swipe) | Swipe between two points |
| [`text`](#text) | Type text into the focused field |
| [`key`](#key) | Press a key |
| [`install`](#install-1) | Install or replace an app |
| [`launch`](#launch) | Start an app as its launcher icon does |
| [`terminate`](#terminate) | Stop every process of an app |
| [`uninstall`](#uninstall) | Remove an app |
| [`logs`](#logs) | Read the device log |
| [`doctor`](#doctor) | Report which adb and Xcode karagoz uses |
| [`mcp`](#mcp-server) | Start the MCP server on stdio |

### devices

```
karagoz devices
```

Lists what `adb devices` lists and, on macOS, the iOS simulators that are running and the iPhones connected to the Mac. Takes no options.

**Output**

```json
{"devices":[{"id":"emulator-5554","platform":"android","kind":"emulator","state":"device","name":"Medium_Phone_API_36.1"}]}
```

A phone on USB next to the emulator (serial masked):

```json
{"devices":[{"id":"XXXXXXXXXXX","platform":"android","kind":"physical","state":"device","name":"SM-S908N"},{"id":"emulator-5554","platform":"android","kind":"emulator","state":"device","name":"Medium_Phone_API_36.1"}]}
```

An iOS simulator running next to the emulator (macOS):

```json
{"devices":[{"id":"emulator-5554","platform":"android","kind":"emulator","state":"device","name":"Medium_Phone_API_36.1"},{"id":"4E70BFCA-5FC6-49B5-92EC-48E265B2D50F","platform":"ios","kind":"simulator","state":"Booted","name":"iPhone 17 Pro"}]}
```

An iPhone on USB next to the emulator (macOS, UDID masked, simulator rows left out):

```json
{"devices":[{"id":"emulator-5554","platform":"android","kind":"emulator","state":"device","name":"Medium_Phone_API_37.0"},{"id":"XXXXXXXX-XXXXXXXXXXXXXXXX","platform":"ios","kind":"physical","state":"paired","name":"iPhone 14 Pro Max"}]}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | The adb serial, or the simulator's or iPhone's UDID. Pass it to `--device`. |
| `platform` | `"android"` or `"ios"` | |
| `kind` | `"emulator"`, `"physical"` or `"simulator"` | `simulator` for iOS simulators, `physical` for iPhones. `emulator` when the id is `emulator-<port>`, or when the device reports `ro.boot.qemu` or `ro.kernel.qemu` as `1`, or `ro.hardware` as `ranchu` or `goldfish` (an emulator attached with `adb connect`). Genymotion, and other ids not in state `device`, read as `physical`. |
| `state` | string | adb's state, unchanged: `device`, `offline`, `unauthorized`, ... Only `device` can be used. For simulators, simctl's state: `Booted`, `Booting`, `Shutting Down`; only `Booted` is usable. For iPhones, devicectl's pairing state: `paired`, `unpaired` (unlock the phone and tap Trust when it asks), `pairingInProgress`. |
| `name` | string or `null` | The AVD name for emulators, the model (`ro.product.model`) for phones, the simulator's name for simulators, the model (`iPhone 14 Pro Max`) for iPhones, `null` for an unpaired iPhone and for a paired one devicectl is not connected to (right after pairing, or when the connection went idle; pick it by UDID then). `null` when the device does not answer, or when it is not in state `device` and its id is not `emulator-<port>`. |

No devices is not an error: `{"devices":[]}`, exit `0`. Android devices come first in adb's order, then simulators in simctl's order, then iPhones in devicectl's order.

If adb, simctl or devicectl is missing, fails or hangs, the other listings are still printed, `errors` holds one `{"platform","code","message"}` per failed listing (two `ios` entries when simctl and devicectl both fail), and the exit is `0`. When every listing tried fails, Android's error is printed as the usual envelope and the exit is `1`. On Linux and Windows simulators and iPhones are not looked for.

**Errors:** `INVALID_ARGS`, `ADB_NOT_FOUND`, `ADB_TIMEOUT`, `ADB_FAILED`; `SIMCTL_NOT_FOUND`, `SIMCTL_TIMEOUT`, `SIMCTL_FAILED`, `DEVICECTL_NOT_FOUND`, `DEVICECTL_TIMEOUT`, `DEVICECTL_FAILED` inside `errors` only.

**Notes**

- About 55 ms, plus about 50 ms per emulator for its name, asked in parallel. A device whose id is not `emulator-<port>` costs one more call in parallel, a chained `getprop` of about 135 ms. With a phone on USB and one emulator, the whole `karagoz devices` run took 257 to 289 ms (three runs, macOS).
- On macOS the simulator listing runs in parallel with adb and takes about 0.12 s once the simulator service runs. The first call after login can take several seconds while macOS starts that service (30 s limit).
- Shut-down simulators, and watchOS, tvOS and visionOS simulators, are not listed.
- The iPhone listing is one `devicectl list devices` call, also in parallel, about 0.06 s. devicectl also knows simulators, phones paired before but not connected now, and nearby devices that could be paired: none of them is listed. iPhones on iOS 16 and older are not listed either. An iPad is listed the way an iPhone is.
- A device listed as `(no serial number)`, or two devices that share one serial, cannot be targeted: adb's `-s` cannot tell them apart.
- karagoz does not pair or connect over Wi-Fi. Use `adb pair` and `adb connect`; a paired Android 11+ phone reconnects by itself.
- If an emulator's name comes back `null`, check that `HOME` points to your home directory; the emulator console reads a token from there.

### screenshot

```
karagoz screenshot [--out <path>] [--device <id>]
```

Saves the screen as a PNG at full device resolution, never scaled, and prints where it went with the metadata needed to measure against it. Runs on an Android emulator, an Android device and, on macOS, a booted iOS simulator and a paired iPhone.

| Option | Default | Meaning |
| --- | --- | --- |
| `--out <path>` | a new file under the temp directory | Where to write the PNG; must end in `.png`. |
| `--device <id>` | see [Device selection](#device-selection) | An adb serial, a simulator's or iPhone's UDID, or a name. |

**Output**

```json
{"path":"/Users/me/home.png","device":"emulator-5554","pixels":{"width":1080,"height":2400},"logical":{"width":411.42857142857144,"height":914.2857142857143},"scale":2.625,"safeArea":{"top":63,"right":0,"bottom":63,"left":0},"rotation":0}
```

An iPhone 17 simulator (macOS, Xcode 27), without `--out`:

```json
{"path":"/var/folders/.../T/karagoz/27024DC1-EDB0-4BF2-8010-08FE3936BAB6-20261012T182033769Z.png","device":"27024DC1-EDB0-4BF2-8010-08FE3936BAB6","pixels":{"width":1206,"height":2622},"logical":{"width":402,"height":874},"scale":3,"safeArea":null,"rotation":0}
```

An iPhone 14 Pro Max (macOS, Xcode 27), without `--out`, UDID masked:

```json
{"path":"/var/folders/.../T/karagoz/XXXXXXXX-XXXXXXXXXXXXXXXX-20261016T075742926Z.png","device":"XXXXXXXX-XXXXXXXXXXXXXXXX","pixels":{"width":1290,"height":2796},"logical":{"width":430,"height":932},"scale":3,"safeArea":null,"rotation":0}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `path` | string | Absolute path of the PNG. |
| `device` | string | The adb serial, or the simulator's or iPhone's UDID. |
| `pixels` | `{width, height}` | Size of the PNG, read from the file itself. |
| `logical` | `{width, height}` | `pixels / scale`, not rounded. |
| `scale` | number | Android: density / 160, using the override density if one is set (`adb shell wm density`). iOS: the simulator's `SIMULATOR_MAINSCREEN_SCALE`, except `2.88` (1080 / 375) for a 1080x2340 or 2340x1080 PNG (iPhone 12 mini, 13 mini): the simulator reports 3 there, but apps lay out 375 points wide. On an iPhone, the `pointScale` that `devicectl device info displays` reports for the primary display, with the same exception. |
| `safeArea` | `{top, right, bottom, left}` or `null` | Pixels of this PNG covered by the status bar, navigation bar, caption bar or display cutout. A hidden bar counts as 0. The keyboard and gesture areas are not included. `null` on iOS: only the app itself can read its safe area, and neither the simulator nor `devicectl` exposes another source. |
| `rotation` | `0`, `90`, `180`, `270` or `null` | Screen rotation in degrees. On iOS with Xcode 27, the interface orientation from `devicectl`, in Android's meaning: turned counter-clockwise (landscape left) is `90`. `null` on Xcode 26 and earlier, or when `devicectl` fails. |

On iOS the PNG is exactly what simctl or devicectl wrote; karagoz does not rotate or re-encode it. An iPhone's PNG has 16 bits per channel and a Display P3 color profile, about 1 to 5 MB, and follows the interface orientation. With Xcode 27 it follows the interface orientation. With Xcode 26 it is the panel in portrait, and a landscape app's UI is drawn sideways in it. The corners are square, not rounded, and the Dynamic Island area is black pixels.

**File location**

- Without `--out`: `<temp dir>/karagoz/<device id>-<UTC timestamp>.png`, where the device id is a UDID on iOS, for example `/var/folders/.../T/karagoz/emulator-5554-20260926T101530123Z.png`. The temp directory follows `TMPDIR`. The `karagoz` directory is created private to your user (mode 0700) and must be a real directory you own; the file is created with mode 0600 and never overwrites. Characters other than letters, digits, `.`, `_` and `-` in the device id become `_`.
- With `--out`: the path must end in `.png`, in any case, or the command fails with `INVALID_ARGS` before any device call. Relative paths resolve against the current directory, missing parent directories are created, and an existing `.png` is overwritten.
- karagoz never deletes screenshots. One 1080x2400 capture is about 1.4 MB; one 1206x2622 simulator capture about 2.9 MB; one 1290x2796 iPhone capture 1 to 5 MB, depending on what is on screen.

**Errors**

- `CAPTURE_FAILED`: screencap returned something other than a whole PNG (its message is included); the density, display size, rotation or insets could not be read (`cannot read <value> from <command>`); or the screen rotated or resized during the capture (`display is WxH but the screenshot is WxH`). With more than one display, screencap's warning comes back as `CAPTURE_FAILED`. On iOS: simctl printed something other than a whole PNG (its text, or `simctl returned no image data`), or the scale could not be read (`cannot read scale from 'simctl getenv' (got '<value>')`). On an iPhone: `devicectl returned no image data`, `cannot read scale from 'devicectl device info displays'`, or `the screen rotated during the capture (rotation <r>, screenshot <w>x<h>)` when the phone turned between the capture and the display read.
- `SIMCTL_FAILED`: on iOS the capture failed; the message is simctl's text. The first capture right after a boot can fail with `Error creating the image`. `SIMCTL_TIMEOUT` after 30 s, `SIMCTL_NOT_FOUND` without Xcode.
- On an iPhone: `DEVICE_NOT_READY` before any capture when it is `unpaired` or `pairingInProgress`, and from the capture when Developer Mode is off, the phone is no longer paired with this Mac, or it is locked since it restarted; the message says what to do on the phone. `NOT_SUPPORTED` when this Mac's `devicectl` predates Xcode 27. `DEVICECTL_TIMEOUT` after 30 s, `DEVICECTL_FAILED` with devicectl's text for any other failure.
- `WRITE_FAILED`: the file could not be written, or the default directory is not yours (`pass --out`). Two captures of one device in the same millisecond without `--out`: the second fails.
- `INVALID_ARGS`: `'<absolute path>' is not a .png file` for an `--out` that does not end in `.png`, before any device call.
- Plus the [device selection](#device-selection) errors, the other `INVALID_ARGS` cases and the adb errors.

**Notes**

- About 1 s on the emulator, about 0.5 s on a phone over USB, about 0.6 s on a simulator, about 0.9 s on an iPhone over USB; the first call after an iPhone was plugged in or sat idle takes a few seconds more while devicectl connects to it.
- A screen that is off, or an app that sets `FLAG_SECURE`, gives a black PNG and exit `0`; so does a locked iPhone with its screen off. Some Android 14 builds refuse the capture instead while a `FLAG_SECURE` window or the lock screen's PIN pad is showing: `CAPTURE_FAILED` with `screencap returned no data`.
- If the density changes during a capture, `scale` and `safeArea` can disagree for that one capture.

### ui-tree

```
karagoz ui-tree [--device <id>]
```

Returns the accessibility tree of the screen: on Android the focused window's, read with `uiautomator dump`; on an iOS simulator the frontmost app's, read by a helper karagoz compiles ([On an iOS simulator](#on-an-ios-simulator)).

**Output** on Android (children cut short here; the real tree nests the Chrome icon several levels deep)

```json
{"device":"emulator-5554","rotation":0,"root":{"class":"android.widget.FrameLayout","package":"com.google.android.apps.nexuslauncher","bounds":[0,0,1080,2400],"children":[...]}}
```

A node from the same tree:

```json
{"class":"android.widget.TextView","text":"Chrome","contentDesc":"Chrome","clickable":true,"longClickable":true,"focusable":true,"bounds":[581,1905,754,2100]}
```

| Field | Present | Meaning |
| --- | --- | --- |
| `device` | always | Serial, or the simulator's UDID. |
| `rotation` | always | `0`, `90`, `180` or `270`. On iOS also `null`, as in [`screenshot`](#screenshot). |
| `root` | always | The top node. |

Node fields on Android, in this order:

| Field | Present | Meaning |
| --- | --- | --- |
| `class` | always | Android class, e.g. `android.widget.Button`. Can be empty. |
| `package` | on the root, and on any node whose package differs from its parent's | App package. |
| `text`, `contentDesc`, `resourceId`, `hint` | when not empty | `resourceId` is the full form, `com.example:id/save`. `hint` exists from Android 15 QPR2 (some API 35 images) on. |
| `checkable`, `checked`, `clickable`, `longClickable`, `focusable`, `focused`, `scrollable`, `selected`, `password` | only when `true` | |
| `enabled` | only when `false` | |
| `bounds` | always | `[left, top, right, bottom]` in [screen pixels](#coordinates). Clipped to the screen: a node wholly off screen is `[0,0,0,0]`, and bottom can be above top. Up to Android 13 the clip also leaves out the status and navigation bars, so a node in the bottom band can be `[0,0,0,0]` while it is visible. |
| `children` | when the node has any | Nodes, same shape. |

Other attributes that uiautomator prints (`index`, `drawing-order`, `NAF`) are dropped. Every node uiautomator returns is kept; there is no filtering.

What the tree covers is what uiautomator covers: the focused window, and nodes visible to the user. Where a framework puts its labels differs: Jetpack Compose puts text in `text`, Flutter puts it in `contentDesc`.

**WebView:** a WebView's content often arrives only on the second read. When the tree has a WebView with no children, karagoz reads once more and returns the second tree, or the first if the second read fails.

**Errors**

- `CAPTURE_FAILED`, with the reason in the message:
  - the screen kept changing for uiautomator's 10 s idle wait (an animation or live content);
  - no focused window (the screen is off, an app is still starting, or the app is in a work profile or Secure Folder, which adb cannot read);
  - uiautomator was killed (the message names `adb -s <id> logcat -b crash`); a lone UTF-16 surrogate in on-screen text does this;
  - the output could not be parsed.
- `AUTOMATION_BUSY`: another UiAutomation client is connected. Only one can be at a time.
- `ADB_TIMEOUT` after 20 s.
- Plus the [device selection](#device-selection) errors, `INVALID_ARGS` and the adb errors.

**Notes**

- On Android one read takes 2.4 to 3.3 s; a screen with a fresh WebView about 5.3 s. The idle failure arrives after about 12 s.
- Output size on the screens measured was about 900 to 6,200 tokens.
- While a read runs, accessibility services such as TalkBack are unbound, and apps see accessibility as enabled. A service that requests the accessibility button is taken off the button and shortcut and stays off; add it back in the accessibility settings.

#### On an iOS simulator

An iPhone 17 home screen (macOS, Xcode 27; children cut short):

```json
{"device":"27024DC1-EDB0-4BF2-8010-08FE3936BAB6","rotation":0,"root":{"role":"Application","label":" ","bounds":[0,0,1206,2622],"children":[...]}}
```

Two nodes from the same tree:

```json
{"role":"Button","label":"Settings","identifier":"Settings","bounds":[917,1167,1122,1439]}
{"role":"Slider","label":"Search","identifier":"spotlight-pill","value":"Page 1 of 2","bounds":[486,2111,720,2201]}
```

Node fields, in this order:

| Field | Present | Meaning |
| --- | --- | --- |
| `role` | always | The accessibility subrole when there is one, else the role, without the `AX` prefix: `Application`, `Button`, `StaticText`, `Heading`, `TextField`, `SecureTextField`, `SearchField`, `Switch`, `Image`, `Group`, `Slider`, ... Can be empty. |
| `label` | when not empty | What VoiceOver reads. The home screen's root label is a single space. |
| `identifier` | when not empty | The app's `accessibilityIdentifier`. |
| `value` | when not empty | A text field's content, or its placeholder when empty; a switch's `0` or `1`; a slider's text. |
| `focused`, `selected` | only when `true` | |
| `enabled` | only when `false` | |
| `bounds` | always | `[left, top, right, bottom]` in [screen pixels](#coordinates): the frame in points times `screenshot`'s `scale`, rounded to 0.01. Not clipped to the screen: an element below the fold has a bottom past the screen's height. |
| `children` | when the node has any | Nodes, same shape. |

The root is the frontmost app, or SpringBoard on the home screen. An alert, a system alert included, is in the tree in place of what it covers. Only elements on screen are listed. Keyboard keys and WebView content have not been measured. An app stopped in a debugger (an Xcode breakpoint or pause) reads as a root `Application` with `bounds` `[0,0,0,0]` and no label or children, with exit 0.

The first call compiles the helper ([Requirements](#requirements)) and takes a few seconds; later calls take about 0.25 s. The helper only reads: it installs nothing in the simulator, needs no macOS permission and leaves no process running.

**Errors on iOS**

- `HELPER_FAILED`: this Mac cannot read iOS trees. No Xcode selected, no `swiftc` at the selected Xcode's toolchain path, a failed compile (swiftc's first error lines), a crashed helper, or an Xcode that changed a private interface karagoz uses (`update karagoz`).
- `CAPTURE_FAILED`: this screen could not be read: no frontmost application, an accessibility request that took over 5 s, no answer within 30 s, or helper output that could not be parsed. With Control Center open, a read ends this way after 30 s.
- `DEVICE_NOT_READY` for a simulator that is still booting, before anything is compiled.
- Plus the [device selection](#device-selection) errors and the simctl and devicectl errors from listing simulators and iPhones.

### tap

```
karagoz tap <x> <y> [--duration <ms>] [--device <id>]
karagoz tap --text <label> [--timeout <ms>] [--duration <ms>] [--device <id>]
karagoz tap --id <resource-id> [--timeout <ms>] [--duration <ms>] [--device <id>]
```

Taps a point, or finds one node in the [tree](#ui-tree) and taps its center. Give exactly one of `<x> <y>`, `--text` or `--id`.

| Option | Default | Meaning |
| --- | --- | --- |
| `<x> <y>` | | A point in [screen pixels](#coordinates). Non-negative, decimals allowed (`12`, `12.5`). |
| `--text <label>` | | A node whose `text` or `contentDesc` equals the label: whole string, case-sensitive, no trimming. Invisible direction marks (U+200E and the like) are ignored on both sides. |
| `--id <resource-id>` | | A node whose `resourceId` equals the value, or ends with `:id/<value>`. `--id save` matches `com.example:id/save`. |
| `--duration <ms>` | none | Hold for this long (a long press). Whole milliseconds, 0 to 999999999. |
| `--timeout <ms>` | `0` | Keep reading the tree until a node matches or this much time has passed. Only with `--text` or `--id`. |
| `--device <id>` | see [Device selection](#device-selection) | |

**Output**

Point:

```json
{"device":"emulator-5554","x":540,"y":1200}
```

With `--duration 10` a `"duration":10` field follows `y`. Node:

```json
{"device":"emulator-5554","x":667.5,"y":2002.5,"element":{"class":"android.widget.TextView","text":"Chrome","contentDesc":"Chrome","clickable":true,"longClickable":true,"focusable":true,"bounds":[581,1905,754,2100]}}
```

`element` is the matched node as [`ui-tree`](#ui-tree) returns it, without `children`. `x` and `y` are its center.

**How a node is found**

- The tap goes to the center of the node that matched, not to a clickable parent. Measured on View, Compose and Flutter test apps, the center of the matched node receives the click.
- A parent and a child that both match are two matches: `ELEMENT_AMBIGUOUS`. Pick one and tap its coordinates.
- Nodes with zero-size bounds never match.
- If the keyboard is visible and the node's center is inside it, the tap is refused with `ELEMENT_COVERED`. Close the keyboard with `karagoz key BACK`. Only the keyboard is checked; bubbles and picture-in-picture windows are not.
- With `--timeout`, only "no match" triggers another read, and it starts right away. The last read can end up to one read (about 3 s) past the timeout. The tap itself is never repeated.
- The screen can change between the read and the tap; the tap then lands on the old point.
- A long press with `--duration` is sent as a swipe that does not move. View and Compose use the device's long-press setting (`settings get secure long_press_timeout`; 400 ms on stock Android, Samsung offers 300 to 1500 ms), Flutter 500 ms.

**Errors**

- `INVALID_ARGS`: no target or more than one (`'tap' takes <x> <y>, --text or --id`), a single coordinate (`'tap' needs <x> <y>`), `--timeout` with a point, or a malformed number.
- `ELEMENT_NOT_FOUND`: `no node with text or contentDesc 'Save' in com.example (1 read in 2.6 s)`.
- `ELEMENT_AMBIGUOUS`: lists up to five matches with class and bounds.
- `ELEMENT_COVERED`: the node is under the keyboard.
- Node taps also get every [`ui-tree`](#ui-tree) error. A point tap does not read the tree, so it works while another UiAutomation client is connected.
- Plus `INPUT_BLOCKED`, the [device selection](#device-selection) errors and the adb errors.

**Notes**

- A point tap takes about 0.2 s. A node tap adds one tree read, 2.5 to 3.3 s.
- Points are not checked against the screen size.
- Exit `0` means Android accepted the event, not that the app reacted to it. Read the tree again to check.

#### On an iOS simulator

Same arguments and output. The point goes to the simulator's own input service as a real touch, and `--duration` holds it there.

```json
{"device":"27024DC1-EDB0-4BF2-8010-08FE3936BAB6","x":603,"y":1015,"element":{"role":"Button","label":"Tap me 0","identifier":"tap-button","bounds":[48,937,1158,1093]}}
```

- `--text` matches a node's `label` or `value`, `--id` its `identifier`; both whole and case-sensitive, direction marks ignored. There is no `:id/` rule.
- The node is tapped at its center like a finger, so what covers it gets the tap.
- There is no keyboard check: `ELEMENT_COVERED` is Android only. The message for no match is `no node with label or value 'Save' in the frontmost app (1 read in 0.3 s)`.
- A tap takes about 0.6 s; a node tap adds one tree read, about 0.3 s.
- Errors: `NOT_SUPPORTED` with Xcode 26 or older, `DEVICE_NOT_READY` when the input service does not answer within 4 s (a simulator that has just booted), `HELPER_FAILED`, and for node taps the [`ui-tree` errors on iOS](#on-an-ios-simulator).

### swipe

```
karagoz swipe <x1> <y1> <x2> <y2> [--duration <ms>] [--device <id>]
```

Moves one finger from `(x1, y1)` to `(x2, y2)`.

| Option | Default | Meaning |
| --- | --- | --- |
| `<x1> <y1> <x2> <y2>` | | [Screen pixels](#coordinates), same rules as `tap`. |
| `--duration <ms>` | `300` | Time from start to end. Whole milliseconds, 0 to 999999999. |
| `--device <id>` | see [Device selection](#device-selection) | |

**Output**

```json
{"device":"emulator-5554","x1":540,"y1":1800,"x2":540,"y2":600,"duration":300}
```

`duration` is always present, including the default.

**Duration matters.** A fast swipe flings a list and a slow one drags it. Measured on a 1200 px drag: 300 ms scrolled a further 1059 px after the finger lifted, 1000 ms scrolled 131 px further, 3000 ms 19 px.

**Errors:** `INVALID_ARGS`, `INPUT_BLOCKED`, the [device selection](#device-selection) errors and the adb errors. On a simulator, `NOT_SUPPORTED`, `DEVICE_NOT_READY` and `HELPER_FAILED` as for [`tap`](#on-an-ios-simulator-1).

On an iOS simulator the arguments and output are the same, with the same default duration:

```json
{"device":"27024DC1-EDB0-4BF2-8010-08FE3936BAB6","x1":603,"y1":2228,"x2":603,"y2":917,"duration":300}
```

### text

```
karagoz text <text> [--device <id>]
karagoz text [--device <id>] -- <text starting with ->
```

Types into whatever has focus, as Android's `input text` does.

**Output**

```json
{"device":"emulator-5554","text":"hello"}
```

**Characters.** Printable ASCII, newline (sent as Enter), tab (sent as Tab), `ç`, `Ç` and `ß`. Anything else fails before anything is typed:

```json
{"error":{"code":"TEXT_UNSUPPORTED","message":"cannot type 'ü' (U+00FC): Android's input text types only printable ASCII, newline, tab, ç, Ç and ß; nothing was typed"}}
```

Quotes, spaces and `%s` are typed as they are; karagoz handles the escaping.

**Errors**

- `INVALID_ARGS`: empty text.
- `TEXT_UNSUPPORTED`: see above.
- Long text is sent in pieces of up to 100 characters. If a piece fails, the error keeps its code and the message ends with `; <n> of <total> characters were typed before this`.
- Plus `INPUT_BLOCKED`, the [device selection](#device-selection) errors and the adb errors.

**Notes**

- Characters typed right after a field appears can be lost. Waiting about 2 s after the field shows up fixed it in testing.
- 100 characters take about 0.9 s.

#### On an iOS simulator

Any Unicode text is typed exactly, at the cursor; iOS's auto-capitalization and smart quotes and dashes are not applied.

```json
{"device":"27024DC1-EDB0-4BF2-8010-08FE3936BAB6","text":"çğş it's -- ok"}
```

- Control characters other than newline and tab fail before anything is typed: `cannot type 'U+0001' on an iOS simulator: control characters other than newline and tab; nothing was typed` (`TEXT_UNSUPPORTED`).
- With no focused field nothing is typed, and the call still exits `0`.
- It types 120 characters a second after about 1 s of setup: 300 characters took 3.5 s.
- A cancelled or timed-out call can still type the whole text: the simulator gets it in one piece.
- An app opened while the call ends can read as an empty tree until it is opened again ([Requirements](#requirements)).
- Errors: `AUTOMATION_BUSY` when a UI test holds the simulator, `HELPER_FAILED` when the session is not granted or the typing fails.

### key

```
karagoz key <key> [--device <id>]
```

Presses one key.

`<key>` is an Android [KeyEvent](https://developer.android.com/reference/android/view/KeyEvent) name or code:

- A name, case-insensitive, with or without `KEYCODE_`: `HOME`, `back`, `KEYCODE_ENTER`, `VOLUME_UP`.
- A number from 1 to 340 is a key code: `key 3` is `HOME`. To press the digit 7, use `KEYCODE_7`, because `key 7` is code 7, which is `KEYCODE_0`.

**Output**

```json
{"device":"emulator-5554","key":"KEYCODE_HOME","code":3}
```

`key` is the resolved name and `code` its number.

**Errors**

- `INVALID_ARGS`: `unknown key 'FOO'; use a KeyEvent name such as HOME, BACK or ENTER, or a code from 1 to 340`. Checked before any device call.
- Plus `INPUT_BLOCKED`, the [device selection](#device-selection) errors and the adb errors.

**Notes**

- A device knows the key codes of its Android version only (12: up to 288, 13: 304, 14: 316, 15: 318, 16: 337); a higher code is sent as `KEYCODE_UNKNOWN`, still with exit `0`.
- Some keys act on the whole device: code 312 opens Recents, 318 saves a screenshot.
- Exit `0` means Android accepted the key, not that the app reacted to it.

#### On an iOS simulator

The same names and codes, and the same output. Only these have an iOS key:

| Name | On the simulator |
| --- | --- |
| `HOME` | The Home button |
| `POWER` | The side button: locks the screen |
| `VOLUME_UP`, `VOLUME_DOWN` | The volume buttons |
| `A`-`Z`, `0`-`9`, `ENTER`, `DEL` (backspace), `FORWARD_DEL`, `TAB`, `SPACE`, `ESCAPE`, `DPAD_UP`, `DPAD_DOWN`, `DPAD_LEFT`, `DPAD_RIGHT`, `MOVE_HOME`, `MOVE_END`, `PAGE_UP`, `PAGE_DOWN`, `F1`-`F24`, `COMMA`, `PERIOD`, `MINUS`, `EQUALS`, `LEFT_BRACKET`, `RIGHT_BRACKET`, `BACKSLASH`, `SEMICOLON`, `APOSTROPHE`, `SLASH`, `GRAVE`, `SHIFT_*`, `CTRL_*`, `ALT_*`, `META_*`, `CAPS_LOCK` | The hardware keyboard key |

Any other name fails before anything is sent:

```json
{"error":{"code":"INVALID_ARGS","message":"'BACK' has no iOS simulator key; iOS takes HOME, POWER, VOLUME_UP, VOLUME_DOWN and keyboard keys (letters, digits, ENTER, DEL, TAB, ESCAPE, DPAD_*, F1-F24); tap the app's back button or swipe from the left edge"}}
```

- Each key is pressed alone, with no modifier held.
- Keyboard keys act only where iOS uses them: in a focused field, or with Full Keyboard Access. A letter goes through iOS's typing, so auto-capitalization applies: `key A` in an empty field typed `A`.
- Errors: `NOT_SUPPORTED`, `DEVICE_NOT_READY` and `HELPER_FAILED` as for [`tap`](#on-an-ios-simulator-1).

### install

```
karagoz install <apk> [--device <id>]
```

Installs an app from one APK file, or on an iOS simulator from a `.app` or `.ipa`, or replaces the installed version of the same app.

| Option | Default | Meaning |
| --- | --- | --- |
| `<apk>` | | Path to an `.apk` file, or for a simulator a `.app` directory or an `.ipa` file. A relative path is resolved against the current directory. |
| `--device <id>` | see [Device selection](#device-selection) | |

**Output**

```json
{"device":"emulator-5554","path":"/Users/me/app/build/outputs/apk/debug/app-debug.apk"}
```

`path` is the absolute path of the app, as given (symlinks are not followed). The package name is not reported.

**Errors**

- `INVALID_ARGS`: `'<path>' is not an .apk, .app or .ipa file`, `no file at '<path>'`, `'<path>' is not a file`, or for a `.app` `'<path>' is not a directory`. Checked before any device call. Once the device is picked, and before anything is sent to it: `'<path>' is an Android app; <udid> is an iOS simulator` or `'<path>' is an iOS app; <serial> is an Android device`.
- `INSTALL_FAILED`: Android refused the APK. The message is adb's, and `reason` is Android's code, as in the [example above](#output-and-errors). Codes seen on the emulator: `INSTALL_FAILED_VERSION_DOWNGRADE` (a lower `versionCode` than the installed app), `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (signed with another key), `INSTALL_PARSE_FAILED_NOT_APK`, `INSTALL_FAILED_DEPRECATED_SDK_VERSION` (`targetSdkVersion` below 24 on Android 16).
- On a phone, Android's code can come from the phone's own install check, with text that says someone cancelled when nobody did: `INSTALL_FAILED_VERIFICATION_FAILURE` (Play Protect refused the app), `INSTALL_FAILED_USER_RESTRICTED` with `Install canceled by user` (Xiaomi, Redmi, POCO: "Install via USB" is off, or its prompt ran out), `INSTALL_FAILED_ABORTED` with `User rejected permissions` (vivo, iQOO: the same).
- A failure without an Android code, such as `Error: device is still booting.`, stays `ADB_FAILED`.
- `ADB_TIMEOUT` after 30 s plus 1 s for every started MB of the APK. On a phone, the install may be held on a prompt (Play Protect, or the maker's check for USB installs) that waits for a tap; if it is accepted later, the app still installs.
- Plus the [device selection](#device-selection) errors and the adb errors.

**Notes**

- Runs `adb install -r --no-incremental`. Since Android 9 a reinstall replaces the app without `-r`; it stays for older devices. `--no-incremental` matters when an `.idsig` file sits next to the APK (`apksigner` writes one by default): adb would then install incrementally, through a background `adb inc-server` process.
- One `.apk` only. Split APKs, `.apks` and `.aab` are not supported. There is no way to pass `-g` (grant runtime permissions), `-d` (allow a downgrade) or `-t`: an APK marked `testOnly`, which Android Studio's Run button can produce, fails with `INSTALL_FAILED_TEST_ONLY`.
- Android installs the app for every user on the device that allows adb installs; Secure Folder, Dual Messenger and work profiles get it too.
- An 8.5 KB APK took 0.7 s, a 100 MB one 2.5 to 3.4 s.
- On Android 17, installing over the app in front puts a system placeholder in its task and restarts the app 2 to 20 s after `install` returns; such an install took 4 to 10 s. A `launch` in that window exits 0, reports `com.android.systemui/com.android.wm.shell.packageupdate.PackageUpdateActivity` as `activity` and starts nothing.

#### On an iOS simulator

Takes a `.app` bundle directory or an `.ipa`, built for the simulator, and runs `simctl install`.

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","path":"/Users/me/Build/Products/Debug-iphonesimulator/Probe.app"}
```

- A build for a physical iPhone is refused: `INSTALL_FAILED` with `reason` `IXUserPresentableErrorDomain:4` and simctl's message, which says the executable has no code for the simulator. Other refusals carry simctl's own `<domain>:<code>`, such as `IXErrorDomain:13` for a bundle without `Info.plist`. A failure without one stays `SIMCTL_FAILED`.
- A lower `CFBundleVersion` than the installed app is not refused. The app's data is kept across reinstalls.
- `SIMCTL_TIMEOUT` after 30 s plus 1 s for every started MB of the file; a `.app` gets 31 s. Over an app stopped in a debugger (an Xcode breakpoint or pause) the install waits for the debugger: the call ends in `SIMCTL_TIMEOUT`, and the app is installed once it continues or the debug session ends. Meanwhile other calls to that simulator can time out too.

### launch

```
karagoz launch <package> [--device <id>]
```

Starts an app the way tapping its launcher icon does.

| Option | Default | Meaning |
| --- | --- | --- |
| `<package>` | | The package name, such as `com.android.settings`. |
| `--device <id>` | see [Device selection](#device-selection) | |

**Output**

```json
{"device":"emulator-5554","package":"com.android.settings","activity":"com.android.settings/.homepage.SettingsHomepageActivity"}
```

`activity` is the activity Android reports as started, in its `package/.Class` short form, or `null` when Android names none. It is not always the launcher activity:

- Settings' launcher activity `.Settings` hands off to `.homepage.SettingsHomepageActivity`, and that one is reported.
- If the app's task is already running, it comes to the front as it is, and its top activity is reported, even one from another package. With the Settings search open, `launch com.android.settings` reports `com.google.android.settings.intelligence/.modules.search.activity.SearchActivity`.

**Which activity is started.** Android's own rule for launch intents: the first activity with the `MAIN` action and the `INFO` category, otherwise the first with `MAIN` and `LAUNCHER`. With two launcher activities the first one Android lists is started; no chooser appears.

**Errors**

- `INVALID_ARGS`: `'<value>' is not a package name`. A package name is letters, digits and `_`, in dot-separated parts that each start with a letter. Checked before any device call, except for a value that is a valid iOS bundle id (`com.foo-bar`, `1abc.x`): that one is refused once an Android device is picked.
- `APP_NOT_FOUND`: `package 'dev.karagoz.nope' is not installed on emulator-5554`.
- `APP_NOT_LAUNCHABLE`: `package 'com.android.shell' has no launcher activity`.
- `ADB_FAILED`: Android refused the start. The message is Android's `Error:` line, such as `Error: Activity class {com.example/com.example.Main} does not exist.`
- `ADB_TIMEOUT` after 30 s. Android itself gives up after 10 s for a process to start and 10 s for the activity to settle.
- Plus the [device selection](#device-selection) errors and the adb errors.

**Notes**

- Exit `0` means Android started the activity, not that the app is up. An app that crashes at start, and a start with the screen off, also exit `0`. Read the [tree](#ui-tree) to check.
- Nothing is restarted or cleared. For a fresh start, run [`terminate`](#terminate) first.
- A cold start of a small app took 1.7 to 2.0 s.

#### On an iOS simulator

`<package>` is the bundle id, such as `com.apple.Preferences`: letters, digits, `-` and `_`, in dot-separated parts. Runs `simctl launch`.

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","package":"dev.karagoz.probe","activity":null}
```

- It returns when the app's process starts, before the app is in front: a `ui-tree` read right away can still show the previous screen. The app was in front 0.3 to 1.5 s later.
- `activity` is always `null`.
- An app that crashes at start also exits `0`. A running app comes to the front as it is.
- `APP_NOT_FOUND`: `app 'dev.karagoz.nope' is not installed on <udid>`. Any other refusal is `SIMCTL_FAILED` with simctl's message. `APP_NOT_LAUNCHABLE` does not come from a simulator: a bundle without an executable is refused at install.

### terminate

```
karagoz terminate <package> [--device <id>]
```

Stops an app with `am force-stop`: every process of the package is killed before the command returns, and Android removes its alarms, scheduled jobs and notifications.

| Option | Default | Meaning |
| --- | --- | --- |
| `<package>` | | The package name. |
| `--device <id>` | see [Device selection](#device-selection) | |

**Output**

```json
{"device":"emulator-5554","package":"com.android.settings"}
```

An app that is installed but not running gives the same output.

**Errors**

- `INVALID_ARGS`: `'<value>' is not a package name`, as for [`launch`](#launch).
- `APP_NOT_FOUND`: the package is not installed. `am force-stop` alone says nothing in that case, so karagoz checks first.
- `ADB_FAILED`: `am force-stop` printed an error; the message is that error.
- Plus the [device selection](#device-selection) errors and the adb errors.

**Notes**

- Only the package's own processes stop. An activity from another package in the same task stays on screen: after `terminate com.android.settings` with the Settings search open, the search is still in front.
- The app stops in every user on the device, Secure Folder and work profiles included.
- Took 0.8 to 1.3 s.

#### On an iOS simulator

Runs `simctl terminate`. System apps are stopped like any other.

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","package":"com.apple.Preferences"}
```

- Stopping the app in front shows the home screen's first page, not the app that was open before.
- An app that is installed but not running gives the same output. `APP_NOT_FOUND` when it is not installed: simctl answers both the same way, so karagoz checks first.
- An app stopped in a debugger (an Xcode breakpoint or pause) does not stop until the debugger lets it run: karagoz exits with `SIMCTL_TIMEOUT` after 30 s, the app stops when it continues or the debug session ends, and other calls to that simulator can time out for up to 5 minutes. An app that runs under the debugger stops at once, and Xcode's session ends.

### uninstall

```
karagoz uninstall <package> [--device <id>]
```

Removes an app and its data.

| Option | Default | Meaning |
| --- | --- | --- |
| `<package>` | | The package name. |
| `--device <id>` | see [Device selection](#device-selection) | |

**Output**

```json
{"device":"emulator-5554","package":"dev.karagoz.smoke"}
```

**Errors**

- `INVALID_ARGS`: `'<value>' is not a package name`, as for [`launch`](#launch).
- `APP_NOT_FOUND`: the package is not installed. Checked first, because Android answers a missing package with `DELETE_FAILED_INTERNAL_ERROR`, the same code it gives for a package it will not remove.
- `UNINSTALL_FAILED`: Android refused. The message is Android's `Failure [...]` line and `reason` its code, such as `DELETE_FAILED_INTERNAL_ERROR` for a system app with no updates.
- Plus the [device selection](#device-selection) errors and the adb errors.

**Notes**

- A system app with installed updates goes back to its factory version. Android reports that as success, and so does karagoz.
- The app's data is always removed; `adb uninstall -k` (keep data) is not offered.
- The app and its data go from every user on the device, Secure Folder and work profiles included. The installed check looks at the main user only, so an app installed only in a profile gives `APP_NOT_FOUND`.
- Took 0.6 to 0.8 s.

#### On an iOS simulator

Runs `simctl uninstall`.

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","package":"dev.karagoz.probe"}
```

- A system app is refused before anything is sent, since a simulator can lose it until it is erased:

  ```json
  {"error":{"code":"UNINSTALL_FAILED","message":"'com.apple.Preferences' is a system app; a simulator does not remove system apps","reason":"SYSTEM_APP"}}
  ```

- A running app is killed first; the home screen then shows the page its icon was on.
- `APP_NOT_FOUND` when it is not installed: simctl reports success for a missing app, so karagoz checks first. A refusal from simctl is `UNINSTALL_FAILED` with its `<domain>:<code>` as `reason`.
- As with `install`, an app stopped in a debugger ends the call in `SIMCTL_TIMEOUT` after 30 s; the app is removed once the debugger lets it run or the debug session ends.

### logs

```
karagoz logs [--package <package>] [--since <seconds>] [--lines <n>] [--device <id>]
```

Reads the device log once and prints the newest records as JSON. Each record is whole: a stack trace is one record with newlines in its message, not one entry per line.

| Option | Default | Meaning |
| --- | --- | --- |
| `--package <package>` | all records | Keep only this app's records. On Android, those written under its Linux user id (uid) in the main Android user; on a simulator, see [On an iOS simulator](#on-an-ios-simulator-8). |
| `--since <seconds>` | Android: the whole log. iOS: the last minute, or the whole log with `--package` | Unix time in seconds on the device clock, up to 9 decimals and at most 4294967295. Only records stamped later are read. |
| `--lines <n>` | `30` | How many of the newest matching records to return, 1 to 999999999. |
| `--device <id>` | see [Device selection](#device-selection) | |

**Output**

```json
{"device":"emulator-5554","package":"com.android.shell","uid":2000,"records":[{"time":1790521762.474251,"pid":24931,"tid":24931,"level":"I","tag":"KaragozManual","message":"hello from karagoz"}],"omitted":0}
```

That record was written with `adb shell log -t KaragozManual "hello from karagoz"`; `adb shell` runs as `com.android.shell`.

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | Serial or UDID of the device read. |
| `package` | string | Only with `--package`: the package as given. |
| `uid` | number | Only with `--package`, on Android: the uid the records were matched on. `com.android.settings` has 1000, which it shares with the system server. |
| `records` | array | The matching records, at most `--lines`, oldest first: on Android in the order the device's log daemon received them, on iOS by time. |
| `records[].time` | number | When the record was written: seconds since the Unix epoch on the device clock, to the microsecond. Rounded up on Android; on iOS as `log` prints it. |
| `records[].pid`, `records[].tid` | number | Process and thread that wrote it. |
| `records[].level` | string | `V`, `D`, `I`, `W`, `E` or `F`; `?` for any other priority. On iOS, `D`, `I`, `E`, `F` or `?` (see [On an iOS simulator](#on-an-ios-simulator-8)). |
| `records[].tag` | string | On Android the log tag; on iOS the name of the process that wrote it. |
| `records[].subsystem`, `records[].category` | string | Only on iOS: the record's `os_log` subsystem and category, `""` when it has none. |
| `records[].message` | string | The message, newlines kept. |
| `omitted` | number | How many older matching records `--lines` left out. `0` when `records` holds every match. |

An empty `records` with `omitted` `0` means nothing matched. It is not an error.

**Reading since your last call.** Pass the largest `time` of one result as the next `--since` to get only newer records. The rounding up makes this exact: no record comes back in the next call. After the call above:

```
karagoz logs --package com.android.shell --since 1790521762.474251
```

```json
{"device":"emulator-5554","package":"com.android.shell","uid":2000,"records":[],"omitted":0}
```

Take the largest `time`, not the last record's: records are in arrival order, and times can step back by a few milliseconds.

**Errors**

- `INVALID_ARGS`: `'<value>' is not a package name`, as for [`launch`](#launch); `--since must be Unix time in seconds (got '<value>')`; `--lines must be a whole number from 1 to 999999999 (got '<value>')`. Checked before any device call.
- `APP_NOT_FOUND`: `package 'dev.karagoz.missing' is not installed on emulator-5554`.
- `ADB_FAILED`: logcat printed its own error instead of records, such as `Failed to wait for logd.ready to become true. logd not running?`; the output was not whole log records; or `pm list packages` printed an error while karagoz looked up the uid. The message is that output, cut at 300 characters. A log larger than the 64 MB karagoz reads at once is `ADB_FAILED` too, with a message that says to pass `--since`.
- `ADB_TIMEOUT` after 10 s.
- Plus the [device selection](#device-selection) errors and the adb errors.

**Notes on Android**

- Logs read: main, system and crash, plus kernel from Android 11, logcat's defaults. The events log is not read.
- The log is never cleared, resized or reconfigured, so other tools and the user keep their history. A call reads what is there and exits; nothing streams. To wait for a line, call again with `--since`.
- The whole window is read from the device and filtered on the host, because logcat counts records before it filters by uid. A full log on the test emulator was 26 MB, about 133,000 records: `logs --lines 1` took 0.7 s, 0.8 s with `--package`. The default 30 records come to about 7 KB of JSON on average; over every 30-record window of a 141,000-record log, the largest was 47 KB.
- `--package` matches the uid, not a process: every process of the app, every restart, and its Java and native crash lines. Lines the system server writes about the app, such as `Start proc` and `ANR in`, have uid 1000 and are not included. A package that shares a system uid, such as Settings, gets the other processes of that uid as well.
- `--package` reads the app in the main Android user. Its copies in Secure Folder, a work profile or a second instance (Dual Messenger, Dual Apps) run under another uid and are not included.
- A record stamped at or before `--since` that the log daemon receives after the previous read is returned by neither call. Records arrived up to 54 ms late in testing.
- `--since` is on the device clock, which can differ from the computer's: a phone ran 10 s behind with automatic time on, so a computer timestamp skipped every new record. Pass a `time` from an earlier result.
- A missing line does not prove the app did not write it: some phones drop lines before they reach the log. A `log.tag` property of `I` (`adb shell getprop log.tag`) drops `D` and `V` lines, Developer options' "Logger buffer sizes: Off" drops nearly all, and Huawei and Honor phones keep app logs off until "AP Log" is turned on in a hidden menu.
- Android cuts a record's tag and message at 4068 bytes together when it is written. Bytes that are not valid UTF-8 become U+FFFD.
- From Android 15 the device ends a read after 5 s without data and still exits `0`, so a read cut short looks complete.

#### On an iOS simulator

Runs `simctl spawn <udid> log show --style ndjson --info --debug` once, bounded in time and filtered, and reads its output as it streams.

```
karagoz logs --package dev.karagoz.probe --lines 1
```

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","package":"dev.karagoz.probe","records":[{"time":1792054562.937849,"pid":43961,"tid":5236136,"level":"I","tag":"Probe","subsystem":"com.apple.Accessibility","category":"AXAppAccessibility","message":"Presentation controller doesn't modalize: <_UIRootPresentationController: 0x10536f350>"}],"omitted":297}
```

- `log show` has no record count, so the window is a time span: without `--since`, the last minute; with `--package`, the whole log. On an idle simulator a minute took under 1 s and an hour 8 s; a read that passes 30 s fails with `SIMCTL_TIMEOUT`.
- `--package` keeps the records of every process that runs the installed build of the app: the app and its extensions, with the lines of the frameworks they load, from this install and from earlier installs of the same build. It also keeps the `exited ...` line `launchd_sim` writes when such a process ends, the only trace of a crash by signal. Records of other builds of the app, other processes' lines about the app, and `print` and stderr output are not included. Two apps whose executables are byte for byte the same, such as two Flutter apps made from the template with the same plugins, are not told apart.
- `level`: Debug is `D`, Info and Default are `I`, Error is `E`, Fault is `F`, anything else `?`. `Logger.notice` and `NSLog` write Default.
- The simulator keeps Info records in memory only for a few minutes (gone after 213 s in testing) and does not store Debug records by default.
- `time` comes from the computer's clock. Pass the largest `time` of one result as the next `--since`: `log` takes whole seconds, and karagoz drops records at or before the exact value, so nothing comes back twice. Of two records in the same microsecond, the second can be lost.
- Each `log show` writes a record of its own run; karagoz leaves it out. The log is never cleared or reconfigured. There is no `uid`.
- Errors: `APP_NOT_FOUND` (`app 'dev.karagoz.nope' is not installed on <udid>`) before the read. `SIMCTL_FAILED` with `log`'s own error, such as `log: Bad predicate ...`, or for output that is not `log show`'s records: `unexpected log output: <line>`, `log show ended without its summary line`. `SIMCTL_TIMEOUT` after 30 s: `log show did not finish within 30s. Pass a later --since, or --package, to read less of the simulator log.` `DEVICE_NOT_READY` for a simulator that is not booted.

### doctor

```
karagoz doctor
```

Reports which `adb` karagoz uses, its version, every other `adb` it could use, and how to install platform-tools when adb is missing or too old. On macOS it also reports the Xcode the simulator commands use: its folder and version, `simctl`, `swiftc`, `devicectl` and the helper cache, and what to fix. It changes nothing. No options.

**Output**

```json
{"adb":{"status":"ok","source":"PATH","path":"/opt/homebrew/bin/adb","version":"37.0.0-14910828","candidates":[{"source":"ANDROID_HOME","status":"unset"},{"source":"ANDROID_SDK_ROOT","status":"unset"},{"source":"PATH","status":"ok","path":"/opt/homebrew/bin/adb","version":"37.0.0-14910828"},{"source":"default","status":"ok","path":"/Users/me/Library/Android/sdk/platform-tools/adb","version":"36.0.2-14143358"}]}}
```

On macOS the same line goes on with `xcode`, shown here alone:

```json
{"xcode":{"status":"ok","source":"xcode-select","path":"/Applications/Xcode.app/Contents/Developer","version":"27.0","build":"27A266a","simctl":{"status":"ok","path":"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl","version":"1171.7"},"swiftc":{"status":"ok","path":"/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"},"devicectl":{"status":"ok","path":"/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"},"helper":{"status":"ok","path":"/Users/me/Library/Caches/karagoz/0bad1277ab4f7da7/ax"}}}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `adb.status` | string | `ok`, `outdated` or `failed`: the status of the candidate karagoz uses. `missing`: no candidate can be used. |
| `adb.source`, `adb.path`, `adb.version`, `adb.message` | string | Copied from the candidate karagoz uses, when it has them. |
| `adb.install` | string | Only when `status` is not `ok`: how to install platform-tools on this OS, the same text `ADB_NOT_FOUND` prints. |
| `adb.candidates` | array | The four places karagoz looks, in lookup order (see [Requirements](#requirements)). |
| `candidates[].source` | string | `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `PATH`, or `default` for Android Studio's default SDK. |
| `candidates[].status` | string | See below. |
| `candidates[].path` | string | When known: the file karagoz would run. For `PATH`, the path adb prints for itself in `adb version`, so it is absent when adb printed none; on Windows, the `adb.exe` found on `PATH`. |
| `candidates[].version` | string | With `ok` and `outdated`: the `Version` line of `adb version`, as printed. |
| `candidates[].message` | string | With `failed` and `outdated`: why, cut at 300 characters. |
| `xcode` | object | macOS only: the Xcode the iOS simulator commands use. |
| `xcode.status` | string | `ok`, `outdated`, `failed` or `missing`, see below. |
| `xcode.source` | string | Which rule picked the developer folder, in the commands' order: `DEVELOPER_DIR`, `xcode-select` (`/var/db/xcode_select_link`), or `default` (`/Applications/Xcode.app/Contents/Developer`). Absent when none is there. |
| `xcode.path` | string | With `source`: the developer folder. |
| `xcode.version`, `xcode.build` | string | From that Xcode's `version.plist`, when it has them: `27.0`, `27A266a`. |
| `xcode.message` | string | When `status` is not `ok`: the first entry's message in the order `simctl`, `swiftc`, `devicectl`, `helper`, or for `outdated`, which commands need a newer Xcode. |
| `xcode.simctl`, `xcode.swiftc`, `xcode.devicectl`, `xcode.helper` | object | One entry each: `status`, `path` when known, and `message` when not `ok`: why. For `simctl` and `swiftc` `missing`, it is the text the command itself would fail with. |
| `xcode.simctl.version` | string | Unless `simctl` is `missing`: this Mac's CoreSimulator version. |

| Status | Means |
| --- | --- |
| `ok` | `adb version` exited `0` and reported platform-tools 30.0.0 or newer. |
| `outdated` | `adb version` exited `0` and reported a version below 30.0.0. |
| `failed` | Something is there but cannot be used: it did not start, exited non-zero, did not answer within 10 s, or printed no `Version` line. The message says which. |
| `missing` | Nothing at that location. For `PATH`: no `adb` on `PATH`, or on macOS and Linux only ones that fail to start with `ENOENT` (see Notes). |
| `unset` | No location to check: the variable is unset or empty. For `default`: Windows without `LOCALAPPDATA`. |

| `xcode.status` | Means |
| --- | --- |
| `ok` | `simctl`, `swiftc` and `devicectl` are `ok`, and the helper is `ok` or `not built`. |
| `outdated` | As `ok`, with an Xcode below 27. |
| `failed` | `simctl`, `swiftc` or `devicectl` is not `ok`, or the helper is `failed`. |
| `missing` | `simctl` and `swiftc` are both `missing`: no Xcode karagoz can use, such as the Command Line Tools alone. |

| Entry status | Means |
| --- | --- |
| `ok` | `simctl`, `swiftc`, `devicectl`: a file karagoz can run. `helper`: built, and a file you own. |
| `missing` | Nothing at `path`. With no developer folder, `swiftc` has no `path` and says no Xcode is selected. |
| `failed` | There but not runnable: `cannot run <path> (EACCES)`. For `simctl`, also when Xcode's first launch has not finished: `the selected Xcode expects CoreSimulator <version>, this Mac has <version>: open Xcode once to finish installing its components`. For `helper`, the cache folder or binary is not yours or not the right type: delete `~/Library/Caches/karagoz`. |
| `not built` | `helper` only: the next `ui-tree`, `tap`, `swipe`, `text` or `key` compiles it. |

The exit code is `0` whenever the report is printed, with adb or Xcode missing or broken as well. Check `adb.status` and `xcode.status`.

**Errors:** `INVALID_ARGS` for any argument or option (`'doctor' does not take the option '--device'`), `INTERNAL`.

**Notes**

- Only `adb version` runs, on every candidate at once. It never connects to the adb server, so server trouble does not show up here; the other commands report it as `ADB_TIMEOUT`.
- Nothing runs for Xcode: doctor reads files only, so it cannot start the simulator service or Xcode's first launch. A stuck simulator service shows in the `errors` of `devices`, not here.
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

## MCP server

```
karagoz mcp
```

Starts an MCP server for an AI agent on stdin and stdout. It opens no port: the client starts the process and talks to it over stdio. The 13 commands are its tools, and each tool returns the JSON line the CLI prints. The server code loads only when `mcp` runs, so the other commands start as fast as before.

`mcp` takes no arguments or options. It exits when stdin closes, or on SIGINT or SIGTERM.

### Registration

karagoz is not on npm yet, so every example runs the built file by its absolute path. After the first release, `npx -y karagoz mcp` replaces `node /abs/path/karagoz-mcp/dist/cli.js mcp`.

Claude Code and Codex were run against this server. The Claude Desktop, Cursor and VS Code entries follow their documentation and were not run.

**Claude Code**

```sh
claude mcp add karagoz -- node /abs/path/karagoz-mcp/dist/cli.js mcp
```

The server starts in the directory `claude` started in, with the shell's environment. A call still running after 2 minutes becomes a background task.

**Claude Desktop**, in `~/Library/Application Support/Claude/claude_desktop_config.json` on macOS or `%APPDATA%\Claude\claude_desktop_config.json` on Windows; quit and restart Desktop after editing:

```json
{"mcpServers":{"karagoz":{"command":"node","args":["/abs/path/karagoz-mcp/dist/cli.js","mcp"],"env":{"ANDROID_HOME":"/Users/me/Library/Android/sdk"}}}}
```

Desktop starts servers with part of your environment and possibly `/` as the working directory, so set `ANDROID_HOME` in `env` when `adb` is not on the `PATH` it passes, and use absolute paths.

**Cursor**, in `.cursor/mcp.json` in the project or `~/.cursor/mcp.json`:

```json
{"mcpServers":{"karagoz":{"type":"stdio","command":"node","args":["/abs/path/karagoz-mcp/dist/cli.js","mcp"]}}}
```

**VS Code**, in `.vscode/mcp.json` in the workspace:

```json
{"servers":{"karagoz":{"type":"stdio","command":"node","args":["/abs/path/karagoz-mcp/dist/cli.js","mcp"]}}}
```

or from the command line: `code --add-mcp '{"name":"karagoz","command":"node","args":["/abs/path/karagoz-mcp/dist/cli.js","mcp"]}'`.

**Codex**, in `~/.codex/config.toml`:

```toml
[mcp_servers.karagoz]
command = "node"
args = ["/abs/path/karagoz-mcp/dist/cli.js", "mcp"]
env_vars = ["ANDROID_HOME", "ANDROID_SDK_ROOT", "KARAGOZ_DEVICE", "ANDROID_SERIAL", "DEVELOPER_DIR"]
tool_timeout_sec = 600
```

Codex passes a server only a short list of environment variables; `env_vars` forwards the ones karagoz reads. `tool_timeout_sec` covers long `tap` waits and big installs. `install` and `uninstall` ask for approval; `codex exec`, which never asks, refuses them with `MCP tool call requires approval, but approval policy is never`.

### Tools

| Tool | Command | Arguments | Marked |
| --- | --- | --- | --- |
| `devices` | [`devices`](#devices) | none | read-only |
| `screenshot` | [`screenshot`](#screenshot) | `out`, `inline`, `device` | |
| `ui_tree` | [`ui-tree`](#ui-tree) | `device` | read-only |
| `tap` | [`tap`](#tap) | `x`, `y`, `text`, `id`, `duration`, `timeout`, `device` | |
| `swipe` | [`swipe`](#swipe) | `x1`, `y1`, `x2`, `y2` (required), `duration`, `device` | |
| `text` | [`text`](#text) | `text` (required), `device` | |
| `key` | [`key`](#key) | `key` (required), `device` | |
| `install` | [`install`](#install-1) | `apk` (required), `device` | destructive |
| `launch` | [`launch`](#launch) | `package` (required), `device` | |
| `terminate` | [`terminate`](#terminate) | `package` (required), `device` | |
| `uninstall` | [`uninstall`](#uninstall) | `package` (required), `device` | destructive |
| `logs` | [`logs`](#logs) | `package`, `since`, `lines`, `device` | read-only |
| `doctor` | [`doctor`](#doctor) | none | read-only |

"Marked" is the tool's annotation: `readOnlyHint` or `destructiveHint`. The other seven carry `destructiveHint: false`, and all 13 carry `openWorldHint: false` and a title. Clients use these to decide what needs approval and what may run in parallel.

### Arguments

- The names are the CLI's option and positional names: `tap {"x": 540, "y": 1200}` is `karagoz tap 540 1200`, and `logs {"lines": 5}` is `karagoz logs --lines 5`. `ui_tree` is the one renamed tool, because Codex turns `-` into `_`.
- Values go through the CLI's own checks, as the text of the value (`12.5` is `12.5`), and the messages keep CLI syntax: `tap {"x": 1, "y": 2, "duration": 1.5}` fails with `--duration must be a whole number of milliseconds (got '1.5')`.
- `null` counts as not given. An argument the tool does not take is refused: `'devices' does not take the option '--foo'`.
- `inline` exists only here: `true` or `false`, else `INVALID_ARGS` `inline must be true or false (got 'yes')`.
- `out` and `apk` should be absolute. A relative path resolves against the server's working directory, which the client picks.
- `device` picks one of several devices. Without it the server uses `KARAGOZ_DEVICE`, then `ANDROID_SERIAL` from its own environment, then the only device ([Device selection](#device-selection)). Codex passes these variables only through `env_vars`.

### Results

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

### Behavior

- Calls run in parallel, except UiAutomation reads (`ui_tree`, and `tap` with `text` or `id`), which take turns per device inside one server. Another process that holds UiAutomation still causes `AUTOMATION_BUSY`.
- A cancelled call kills its adb child at once and gets no response. The device does not stop with it: it keeps its UiAutomation slot for about 1-2 s, so a `ui_tree` right after can get `AUTOMATION_BUSY`; a gesture already sent finishes on the device; and a cancelled `install` may leave the app installed. Esc in Claude Code cancels the running call: the adb dump was gone within 0.3 s and the server kept running.
- stdin closing, SIGINT and SIGTERM cancel every call the same way; the process exits with `0`, `130` and `143`.
- The server keeps the `adb` it found for the whole session. If that file disappears (`ENOENT`), the next call looks it up again.

### Token cost

What the server adds to a Claude Code session, measured on 2026-10-15 with Claude Code 2.1.300 and `claude-opus-5-5`: input tokens of the first API call with karagoz registered, minus the same call with no MCP server.

| Case | Tokens |
| --- | --- |
| Every session, tool search on (the default): the 13 tool names and `instructions` | 337 |
| All 13 definitions, loaded by one `ToolSearch` call | 2,325 |
| Every session, tool search off (`ENABLE_TOOL_SEARCH=false`): every definition and `instructions` | 2,213 |

The `tools/list` result is 5,878 characters and `instructions` 395. One `ui_tree` of the launcher home screen is 5,383 characters.

## Scope

karagoz is the primitive layer. Each command does one thing and exits.

- **Not a test framework.** No assertions, no test runner, no recorded flows, no retry policy, no reports. `tap --timeout` waits for a node to appear; it never repeats an action.
- **Not a design comparison tool.** Figma diffing, measurement and reporting belong a layer above. karagoz produces the raw input, and the metadata to measure it with, but does not interpret it.

## Development

```sh
npm run build       # empty dist/, then bundle to dist/cli.js and two chunks
npm run typecheck
npm run lint        # oxlint and the Prettier check; npm run format fixes formatting
```

Each step has one smoke script in `smoke/`. Each builds first and needs a running emulator, `smoke/M-mcp.sh` included, except `smoke/0b-version.sh`, `smoke/1.7-doctor.sh`, `smoke/2.2-screenshot-physical.sh`, `smoke/2.3-ui-tree-physical.sh`, `smoke/2.4-input-physical.sh`, `smoke/2.5-app-lifecycle-physical.sh`, `smoke/2.6-logs-physical.sh`, `smoke/3.1-devices-ios.sh`, `smoke/3.2-screenshot-ios.sh`, `smoke/3.3-ui-tree-ios.sh`, `smoke/3.4-input-ios.sh`, `smoke/3.5-app-lifecycle-ios.sh`, `smoke/3.6-logs-ios.sh`, `smoke/4.1-devices-ios-device.sh` and `smoke/4.2-screenshot-ios-device.sh`: 1.7 uses fake `adb` scripts only and never runs the real adb, 3.1 uses fake `adb` and `simctl` scripts and reads the real simulator list, 3.2 uses fake `adb`, `simctl` and `devicectl` scripts and captures a booted simulator when one runs (else its real step prints `SKIP`), 3.3 adds a fake `swiftc` and reads a booted simulator's tree the same way, 3.4, 3.5 and 3.6 build a test app from `smoke/fixtures/input-ios/` and drive, install and remove it as `dev.karagoz.probe` on a booted simulator (3.6 reads its log back), 4.1 uses fake `adb`, `simctl` and `devicectl` scripts and reads the real iPhone list, 4.2 uses the same fakes and captures a paired iPhone when one is attached (else its real step prints `SKIP`), all eight macOS only (they print `SKIP` elsewhere), and 2.2, 2.3, 2.4, 2.5 and 2.6 need a phone only for their phone step, which they skip when none is listed. The header of each script lists its preconditions:

```sh
sh smoke/1.4-input.sh
```

`smoke/1.5-app-lifecycle.sh` also builds a test APK on every run, and `smoke/2.5-app-lifecycle-physical.sh` when a phone is attached, with `smoke/fixtures/app-lifecycle/build.sh` from the manifest in that folder, and installs and removes it as `dev.karagoz.smoke`. No APK is kept in the repository. They need a JDK (`java` and `keytool` on `PATH`) and, from the Android SDK, build-tools with `aapt2` and `apksigner` plus one platform. The SDK is the first of `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, `~/Library/Android/sdk` and `~/Android/Sdk` that has both `build-tools/` and `platforms/`. When something is missing the smoke fails and says what, rather than skipping.

The full check, with the emulator running:

```sh
npm run typecheck && npm run lint && for s in smoke/*.sh; do sh "$s" || exit 1; done
```

## Name

Karagöz is Turkish shadow puppet theatre. Figures are driven with rods from behind a lit screen while the audience watches the movement on the screen. That is what this tool does.

## License

MIT
