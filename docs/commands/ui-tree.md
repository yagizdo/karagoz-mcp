# ui-tree

```
karagoz ui-tree [--device <id>]
```

Returns the accessibility tree of the screen: on Android the focused window's, read with `uiautomator dump`; on an iOS simulator the frontmost app's, read by a helper karagoz compiles ([On an iOS simulator](#on-an-ios-simulator)); on an iPhone the frontmost app's, read by karagoz's runner on the phone ([On an iPhone](#on-an-iphone)).

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
| `device` | always | Serial, or the simulator's or iPhone's UDID. |
| `rotation` | always | `0`, `90`, `180` or `270`. On iOS also `null`, as in [`screenshot`](screenshot.md). |
| `root` | always | The top node. |

Node fields on Android, in this order:

| Field | Present | Meaning |
| --- | --- | --- |
| `class` | always | Android class, e.g. `android.widget.Button`. Can be empty. |
| `package` | on the root, and on any node whose package differs from its parent's | App package. |
| `text`, `contentDesc`, `resourceId`, `hint` | when not empty | `resourceId` is the full form, `com.example:id/save`. `hint` exists from Android 15 QPR2 (some API 35 images) on. |
| `checkable`, `checked`, `clickable`, `longClickable`, `focusable`, `focused`, `scrollable`, `selected`, `password` | only when `true` | |
| `enabled` | only when `false` | |
| `bounds` | always | `[left, top, right, bottom]` in [screen pixels](../output.md#coordinates). Clipped to the screen: a node wholly off screen is `[0,0,0,0]`, and bottom can be above top. Up to Android 13 the clip also leaves out the status and navigation bars, so a node in the bottom band can be `[0,0,0,0]` while it is visible. |
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
- Plus the [device selection](../device-selection.md) errors, `INVALID_ARGS` and the adb errors.

**Notes**

- On Android one read takes 2.4 to 3.3 s; a screen with a fresh WebView about 5.3 s. The idle failure arrives after about 12 s.
- Output size on the screens measured was about 900 to 6,200 tokens.
- While a read runs, accessibility services such as TalkBack are unbound, and apps see accessibility as enabled. A service that requests the accessibility button is taken off the button and shortcut and stays off; add it back in the accessibility settings.

## On an iOS simulator

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
| `bounds` | always | `[left, top, right, bottom]` in [screen pixels](../output.md#coordinates): the frame in points times `screenshot`'s `scale`, rounded to 0.01. Not clipped to the screen: an element below the fold has a bottom past the screen's height. |
| `children` | when the node has any | Nodes, same shape. |

The root is the frontmost app, or SpringBoard on the home screen. An alert, a system alert included, is in the tree in place of what it covers. Only elements on screen are listed. Keyboard keys and WebView content have not been measured. An app stopped in a debugger (an Xcode breakpoint or pause) reads as a root `Application` with `bounds` `[0,0,0,0]` and no label or children, with exit 0.

The first call compiles the helper ([Requirements](../requirements.md)) and takes a few seconds; later calls take about 0.25 s. The helper only reads: it installs nothing in the simulator, needs no macOS permission and leaves no process running.

**Errors on iOS**

- `HELPER_FAILED`: this Mac cannot read iOS trees. No Xcode selected, no `swiftc` at the selected Xcode's toolchain path, a failed compile (swiftc's first error lines), a crashed helper, or an Xcode that changed a private interface karagoz uses (`update karagoz`).
- `CAPTURE_FAILED`: this screen could not be read: no frontmost application, an accessibility request that took over 5 s, no answer within 30 s, or helper output that could not be parsed. With Control Center open, a read ends this way after 30 s. An app opened while the simulator's app accessibility setting was off (an Xcode UI test, or another XCUI client, turns it off when it ends) reads as an empty root: karagoz turns the setting back on and fails with `the app in front opened while the simulator's app accessibility was off ...: restart the app (terminate, then launch) and read again`. After `terminate` and `launch` the tree is full.
- `DEVICE_NOT_READY` for a simulator that is still booting, before anything is compiled.
- Plus the [device selection](../device-selection.md) errors and the simctl and devicectl errors from listing simulators and iPhones.

## On an iPhone

The tree comes from karagoz's own runner, a small XCUITest bundle that [`install-runner`](install-runner.md) builds with your Apple team and installs on the phone. When nothing answers, `ui-tree` starts the runner with `xcodebuild test-without-building`; it stays up between calls and stops itself after 10 minutes without a read or an input. No daemon is left behind: the only process is that `xcodebuild`, which exits with the runner. `ui-tree` never installs the runner: without it the error is `RUNNER_NOT_INSTALLED`.

The output's shape on an iPhone 14 Pro Max (UDID masked, label made up, children cut short):

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","rotation":0,"root":{"role":"Application","label":"Example","bounds":[0,0,1290,2796],"children":[...]}}
```

The node fields are the simulator's, with these differences:

- `role` is XCTest's element type: `Application`, `Window`, `Group` (XCTest's `Other`), `Button`, `StaticText`, `Heading` (a static text with the header trait), `Cell`, `Icon`, `Image`, `Switch` (also XCTest's `Toggle`), `TextField`, `SearchField`, `Keyboard`, `Key`, `NavigationBar`, `CollectionView`, ... A type karagoz does not know is `Element<number>`.
- XCTest's layers stay: windows and unlabeled groups. The measured trees were larger than the simulator's: home screen 224 nodes, Settings 183, an app with the keyboard up 158 (14 to 20 on the simulator).
- Elements off screen are listed; icons on another home screen page have `bounds` `[0,0,0,0]`.
- In landscape XCTest reports the keyboard in portrait coordinates; karagoz turns it into the screen's. Measured with the phone turned clockwise (`rotation` `270`); the other direction is turned by symmetry and was not measured.
- `rotation` and the scale come from `devicectl device info displays`, as in [`screenshot`](screenshot.md), so `bounds` are that screenshot's pixels.
- The root is the app in front, or SpringBoard on the home screen. A system alert, when one is up, is the root's only child. Not measured on a phone: an alert, Control Center, Notification Center, the lock screen.

Starting the runner and reading the first tree took 3 to 4.4 s; later reads about 0.7 s for the whole command (measured on one iPhone over USB).

**Errors on an iPhone**

- `RUNNER_NOT_INSTALLED`: no runner to start. The message names `karagoz install-runner --device <UDID>` and the MCP tool `install_runner`.
- `DEVICE_NOT_READY`: the iPhone is not connected by USB cable; it is locked (the start ends at once); it does not trust the runner's developer yet (free accounts: Settings > General > VPN & Device Management); the runner did not start within 60 s: look at the phone for a passcode prompt to enable UI automation, and check Settings > Developer > Enable UI Automation; something else answers on the runner's port without this Mac's key (another app, or a runner another user of this Mac started, which stops within 10 minutes; restart the iPhone if it stays); or another app holds that port. Plus the pairing states of [Device selection](../device-selection.md).
- `HELPER_FAILED`: the selected Xcode has no `xcodebuild` (`xcodebuild not found in <developer dir>`, as `install-runner` says), `xcodebuild` could not start the runner for a reason karagoz does not know (its last error line and the log path), or this iOS changed an interface the runner uses (`update karagoz`).
- `CAPTURE_FAILED`: XCTest could not take the snapshot (its message), no answer within 30 s, or the runner closed the connection. A snapshot stuck for 20 s ends the runner; the next call starts a new one.
- Plus the [device selection](../device-selection.md) errors and the devicectl errors.

**Notes on an iPhone**

- The runner listens on 127.0.0.1 port 27753 on the phone. karagoz reaches it over the USB cable through macOS's usbmuxd, so nothing on the phone's network can. An iPhone on Wi-Fi only is not supported.
- Other apps on the phone can reach that port, so each start gives the runner a new secret: it is kept in `~/Library/Caches/karagoz/runner/<UDID>.token` (mode 0600) and handed over in a 0600 copy of the build's `.xctestrun`, never on a command line. Every request and every answer carries an HMAC-SHA256 under it, so the secret never crosses the connection, and the runner refuses anything unsigned (HTTP 401).
- Two first calls at once start one runner: a lock file in `~/Library/Caches/karagoz/locks/` lines them up, and the kernel releases it if a call crashes.
- The runner plays one input or `ui-tree` read at a time. A call that waits more than 8 s behind another fails with `HELPER_FAILED` (`CAPTURE_FAILED` for `ui-tree`) and plays nothing.
- The runner build is in `~/Library/Caches/karagoz/runner/`, one folder per karagoz version, Xcode and team; after deleting it, run `install-runner` again. `xcodebuild`'s output for the last start is in `~/Library/Caches/karagoz/runner/<UDID>.log`.
- With a passcode set, iOS asks for it on the phone ("Enter iPhone Passcode for XCTest") before UI automation can start: at the first start after a restart, about once a day (Apple's description), and, measured, at the first start after the phone was locked. xcodebuild says nothing about it, so the start waits up to 60 s.
