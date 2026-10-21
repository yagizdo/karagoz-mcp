# launch

```
karagoz launch <package> [--device <id>]
```

Starts an app the way tapping its launcher icon does.

| Option | Default | Meaning |
| --- | --- | --- |
| `<package>` | | The package name, such as `com.android.settings`. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

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
- Plus the [device selection](../device-selection.md) errors and the adb errors.

**Notes**

- Exit `0` means Android started the activity, not that the app is up. An app that crashes at start, and a start with the screen off, also exit `0`. Read the [tree](ui-tree.md) to check.
- Nothing is restarted or cleared. For a fresh start, run [`terminate`](terminate.md) first.
- A cold start of a small app took 1.7 to 2.0 s.

## On an iOS simulator

`<package>` is the bundle id, such as `com.apple.Preferences`: letters, digits, `-` and `_`, in dot-separated parts. Runs `simctl launch`.

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","package":"dev.karagoz.probe","activity":null}
```

- It returns when the app's process starts, before the app is in front: a `ui-tree` read right away can still show the previous screen. The app was in front 0.3 to 1.5 s later.
- `activity` is always `null`.
- An app that crashes at start also exits `0`. A running app comes to the front as it is.
- `APP_NOT_FOUND`: `app 'dev.karagoz.nope' is not installed on <udid>`. Any other refusal is `SIMCTL_FAILED` with simctl's message. `APP_NOT_LAUNCHABLE` does not come from a simulator: a bundle without an executable is refused at install.

## On an iPhone

Runs `devicectl device process launch`, with `<package>` the bundle id.

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","package":"dev.karagoz.probe","activity":null}
```

- It returns when the app's process starts (0.3 to 0.5 s), before the app is in front. A running app, also one in the background, comes to the front with the same process; nothing is restarted. `activity` is always `null`.
- `APP_NOT_FOUND`: `app 'dev.karagoz.nope' is not installed on <UDID>`. A locked iPhone gives `DEVICE_NOT_READY` after about 10 s. Any other refusal is `DEVICECTL_FAILED` with devicectl's description and the phone's reason, such as an app whose developer the phone does not trust yet.
- An app stopped in a debugger, or started stopped, holds the launch until it continues: karagoz exits with `DEVICECTL_TIMEOUT` after 30 s, and the message names that cause.
