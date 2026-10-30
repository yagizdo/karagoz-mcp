# open-url

```
karagoz open-url <url> [--app <id>] [--device <id>]
```

Opens a URL, such as a deep link (`myapp://item/42`) or a web link, in the app the system picks for it, or in the app named by `--app`.

| Option | Default | Meaning |
| --- | --- | --- |
| `<url>` | | The URL. It needs a scheme (`https:`, `myapp:`); nothing else is checked before the device gets it. |
| `--app <id>` | none: the system picks the app | The package name of the app that gets the URL, such as `com.android.chrome`. Not on an iOS simulator. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

```json
{"device":"emulator-5554","url":"https://example.com"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | The adb serial, or the simulator's or iPhone's UDID. |
| `url` | string | The URL as given. |
| `app` | string | The package name or bundle id from `--app`. Only present when `--app` was given. |

**Errors**

- `INVALID_ARGS`: `'<url>' is not a URL: it needs a scheme such as https: or myapp:`, or `--app`'s `'<value>' is not a package name`, as for [`launch`](launch.md). Checked before any device call.
- `APP_NOT_FOUND`: without `--app`, `no app on emulator-5554 opens 'nosuchscheme://x'`; with it, `package 'dev.karagoz.nope' is not installed on emulator-5554`.
- `APP_NOT_LAUNCHABLE`: `package 'com.android.shell' has no activity that opens 'myapp://x'`. The app is installed but declares nothing for this URL.
- `ADB_FAILED`: Android refused the start. The message is Android's `Error:` line.
- `ADB_TIMEOUT` after 30 s, as for [`launch`](launch.md).
- Plus the [device selection](../device-selection.md) errors and the adb errors.

**Notes**

- The URL reaches the app as given, including `&`, `#`, `;`, quotes and spaces; the caller quotes it only for its own shell.
- Exit `0` means Android started an activity for the URL, not that the app handled it. Read the [tree](ui-tree.md) to check.
- With two apps for the URL and no default set, Android shows its chooser and `open-url` exits `0`.
- An `https` URL opens the app that owns the domain only when that app is verified for it. Otherwise the browser opens it.
- `open-url` never restarts the app. If it is in front, the URL goes to the running app.

## On an iOS simulator

Runs `simctl openurl`. `--app` is refused: `NOT_SUPPORTED`, `an iOS simulator opens a URL only in the app the system picks; run open-url without --app`.

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","url":"https://example.com"}
```

- It returns before the app is in front: Safari took 1.3 to 2.2 s from a cold start.
- For an app's own scheme, iOS first asks `Open in “<app>”?` with Cancel and Open, and the app gets the URL only after Open is tapped ([`tap --text Open`](tap.md)).
- `APP_NOT_FOUND`: `no app on <udid> opens 'nosuchscheme://x'`. Any other refusal is `SIMCTL_FAILED` with simctl's message.

## On an iPhone

Without `--app`, runs `devicectl device process openURL`; with it, `devicectl device process launch --payload-url`, with `--app` the bundle id.

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","url":"myapp://item/42","app":"com.example.app"}
```

- `APP_NOT_FOUND`: `app 'dev.karagoz.nope' is not installed on <UDID>` for `--app`. A locked iPhone gives `DEVICE_NOT_READY`. Any other refusal, such as a URL no app opens, is `DEVICECTL_FAILED` with devicectl's description and the phone's reason.
