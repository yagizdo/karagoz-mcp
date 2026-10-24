# uninstall

```
karagoz uninstall <package> [--device <id>]
```

Removes an app and its data.

| Option | Default | Meaning |
| --- | --- | --- |
| `<package>` | | The package name. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

```json
{"device":"emulator-5554","package":"dev.karagoz.smoke"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | The adb serial, or the simulator's or iPhone's UDID. |
| `package` | string | The package name as given; on iOS, the bundle id. |

**Errors**

- `INVALID_ARGS`: `'<value>' is not a package name`, as for [`launch`](launch.md).
- `APP_NOT_FOUND`: the package is not installed. Checked first, because Android answers a missing package with `DELETE_FAILED_INTERNAL_ERROR`, the same code it gives for a package it will not remove.
- `UNINSTALL_FAILED`: Android refused. The message is Android's `Failure [...]` line and `reason` its code, such as `DELETE_FAILED_INTERNAL_ERROR` for a system app with no updates.
- Plus the [device selection](../device-selection.md) errors and the adb errors.

**Notes**

- A system app with installed updates goes back to its factory version. Android reports that as success, and so does karagoz.
- The app's data is always removed; `adb uninstall -k` (keep data) is not offered.
- The app and its data go from every user on the device, Secure Folder and work profiles included. The installed check looks at the main user only, so an app installed only in a profile gives `APP_NOT_FOUND`.
- Took 0.6 to 0.8 s.

## On an iOS simulator

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

## On an iPhone

Runs `devicectl device uninstall app`.

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","package":"dev.karagoz.probe"}
```

- A system app, one not installed under the phone's `/private/var/containers/Bundle/Application/` such as Settings, is refused before anything is sent: `UNINSTALL_FAILED`, `reason` `SYSTEM_APP`, `'com.apple.Preferences' is a system app; an iPhone does not remove system apps`.
- `APP_NOT_FOUND` when it is not installed: devicectl reports success for a missing app, so karagoz checks first. A refusal is `UNINSTALL_FAILED` with the phone's `<domain>:<code>` as `reason`.
- A running app, also one stopped in a debugger, is killed and removed. A locked iPhone removes too. Took about 0.55 s.
