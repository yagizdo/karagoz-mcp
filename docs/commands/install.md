# install

```
karagoz install <apk> [--device <id>]
```

Installs an app from one APK file, or on an iOS simulator or iPhone from a `.app` or `.ipa`, or replaces the installed version of the same app.

| Option | Default | Meaning |
| --- | --- | --- |
| `<apk>` | | Path to an `.apk` file, or for a simulator or an iPhone a `.app` directory or an `.ipa` file. A relative path is resolved against the current directory. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

```json
{"device":"emulator-5554","path":"/Users/me/app/build/outputs/apk/debug/app-debug.apk"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | The adb serial, or the simulator's or iPhone's UDID. |
| `path` | string | The absolute path of the app, as given (symlinks are not followed). |

The package name is not reported.

**Errors**

- `INVALID_ARGS`: `'<path>' is not an .apk, .app or .ipa file`, `no file at '<path>'`, `'<path>' is not a file`, or for a `.app` `'<path>' is not a directory`. Checked before any device call. Once the device is picked, and before anything is sent to it: `'<path>' is an Android app; <udid> is an iOS simulator` (`is an iPhone` on one) or `'<path>' is an iOS app; <serial> is an Android device`.
- `INSTALL_FAILED`: Android refused the APK. The message is adb's, and `reason` is Android's code, as in the [example](../output.md). Codes seen on the emulator: `INSTALL_FAILED_VERSION_DOWNGRADE` (a lower `versionCode` than the installed app), `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (signed with another key), `INSTALL_PARSE_FAILED_NOT_APK`, `INSTALL_FAILED_DEPRECATED_SDK_VERSION` (`targetSdkVersion` below 24 on Android 16).
- On a phone, Android's code can come from the phone's own install check, with text that says someone cancelled when nobody did: `INSTALL_FAILED_VERIFICATION_FAILURE` (Play Protect refused the app), `INSTALL_FAILED_USER_RESTRICTED` with `Install canceled by user` (Xiaomi, Redmi, POCO: "Install via USB" is off, or its prompt ran out), `INSTALL_FAILED_ABORTED` with `User rejected permissions` (vivo, iQOO: the same).
- A failure without an Android code, such as `Error: device is still booting.`, stays `ADB_FAILED`.
- `ADB_TIMEOUT` after 30 s plus 1 s for every started MB of the APK. On a phone, the install may be held on a prompt (Play Protect, or the maker's check for USB installs) that waits for a tap; if it is accepted later, the app still installs.
- Plus the [device selection](../device-selection.md) errors and the adb errors.

**Notes**

- Runs `adb install -r --no-incremental`. Since Android 9 a reinstall replaces the app without `-r`; it stays for older devices. `--no-incremental` matters when an `.idsig` file sits next to the APK (`apksigner` writes one by default): adb would then install incrementally, through a background `adb inc-server` process.
- One `.apk` only. Split APKs, `.apks` and `.aab` are not supported. There is no way to pass `-g` (grant runtime permissions), `-d` (allow a downgrade) or `-t`: an APK marked `testOnly`, which Android Studio's Run button can produce, fails with `INSTALL_FAILED_TEST_ONLY`.
- Android installs the app for every user on the device that allows adb installs; Secure Folder, Dual Messenger and work profiles get it too.
- An 8.5 KB APK took 0.7 s, a 100 MB one 2.5 to 3.4 s.
- On Android 17, installing over the app in front puts a system placeholder in its task and restarts the app 2 to 20 s after `install` returns; such an install took 4 to 10 s. A `launch` in that window exits 0, reports `com.android.systemui/com.android.wm.shell.packageupdate.PackageUpdateActivity` as `activity` and starts nothing.

## On an iOS simulator

Takes a `.app` bundle directory or an `.ipa`, built for the simulator, and runs `simctl install`.

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","path":"/Users/me/Build/Products/Debug-iphonesimulator/Probe.app"}
```

- A build for a physical iPhone is refused: `INSTALL_FAILED` with `reason` `IXUserPresentableErrorDomain:4` and simctl's message, which says the executable has no code for the simulator. Other refusals carry simctl's own `<domain>:<code>`, such as `IXErrorDomain:13` for a bundle without `Info.plist`. A failure without one stays `SIMCTL_FAILED`.
- A lower `CFBundleVersion` than the installed app is not refused. The app's data is kept across reinstalls.
- `SIMCTL_TIMEOUT` after 30 s plus 1 s for every started MB of the file; a `.app` gets 31 s. Over an app stopped in a debugger (an Xcode breakpoint or pause) the install waits for the debugger: the call ends in `SIMCTL_TIMEOUT`, and the app is installed once it continues or the debug session ends. Meanwhile other calls to that simulator can time out too.

## On an iPhone

Takes a `.app` bundle directory or an `.ipa` built and signed for this iPhone, and runs `devicectl device install app`. karagoz does not re-sign the app: build it for the phone in Xcode or Flutter, which sign it with a profile that includes this iPhone.

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","path":"/Users/me/Build/Products/Debug-iphoneos/Probe.app"}
```

- The phone checks the signature first. A refusal is `INSTALL_FAILED` whose `reason` is the phone's own `<domain>:<code>`, the deepest error devicectl reports, and whose message names the cause: `MIInstallerErrorDomain:13` with `0xe8008014 (The executable contains an invalid signature.)` for a simulator build, `0xe800801c (No code signature found.)` for an unsigned app, and, from public reports (not measured here), `0xe8008015` or `0xe8008012` for a profile that does not include this iPhone. The message then says that karagoz does not re-sign. A bundle without `Info.plist` is refused on the Mac: `com.apple.dt.CoreDeviceError:3000`.
- A reinstall replaces the version, a lower one too, and keeps the app's data. Installing over the running app stops it. A locked iPhone installs too.
- A small app took 1.4 to 1.5 s, a 100 MB one 4.1 s the first time (devicectl then sends only what changed).
- `DEVICECTL_TIMEOUT` after 30 s plus 1 s for every started MB of the file; a `.app` gets 31 s.
