# terminate

```
karagoz terminate <package> [--device <id>]
```

Stops an app with `am force-stop`: every process of the package is killed before the command returns, and Android removes its alarms, scheduled jobs and notifications.

| Option | Default | Meaning |
| --- | --- | --- |
| `<package>` | | The package name. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

```json
{"device":"emulator-5554","package":"com.android.settings"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | The adb serial, or the simulator's or iPhone's UDID. |
| `package` | string | The package name as given; on iOS, the bundle id. |

An app that is installed but not running gives the same output.

**Errors**

- `INVALID_ARGS`: `'<value>' is not a package name`, as for [`launch`](launch.md).
- `APP_NOT_FOUND`: the package is not installed. `am force-stop` alone says nothing in that case, so karagoz checks first.
- `ADB_FAILED`: `am force-stop` printed an error; the message is that error.
- Plus the [device selection](../device-selection.md) errors and the adb errors.

**Notes**

- Only the package's own processes stop. An activity from another package in the same task stays on screen: after `terminate com.android.settings` with the Settings search open, the search is still in front.
- The app stops in every user on the device, Secure Folder and work profiles included.
- Took 0.8 to 1.3 s.

## On an iOS simulator

Runs `simctl terminate`. System apps are stopped like any other.

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","package":"com.apple.Preferences"}
```

- Stopping the app in front shows the home screen's first page, not the app that was open before.
- An app that is installed but not running gives the same output. `APP_NOT_FOUND` when it is not installed: simctl answers both the same way, so karagoz checks first.
- An app stopped in a debugger (an Xcode breakpoint or pause) does not stop until the debugger lets it run: karagoz exits with `SIMCTL_TIMEOUT` after 30 s, the app stops when it continues or the debug session ends, and other calls to that simulator can time out for up to 5 minutes. An app that runs under the debugger stops at once, and Xcode's session ends.

## On an iPhone

Looks the app up with `devicectl device info apps`, then kills every process running from its bundle, the app and its extensions, with `devicectl device process terminate --kill`. System apps are stopped like any other.

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","package":"com.apple.Preferences"}
```

- An app that is installed but not running gives the same output. `APP_NOT_FOUND` when it is not installed.
- An app stopped in a debugger, or started stopped, stops at once.
- Took 0.5 to 0.6 s.
