# screenshot

```
karagoz screenshot [--out <path>] [--device <id>]
```

Saves the screen as a PNG at full device resolution, never scaled, and prints where it went with the metadata needed to measure against it. Runs on an Android emulator, an Android device and, on macOS, a booted iOS simulator and a paired iPhone.

| Option | Default | Meaning |
| --- | --- | --- |
| `--out <path>` | a new file under the temp directory | Where to write the PNG; must end in `.png`. |
| `--device <id>` | see [Device selection](../device-selection.md) | An adb serial, a simulator's or iPhone's UDID, or a name. |

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
| `pixels.width` | number | Width of the PNG in pixels. |
| `pixels.height` | number | Height of the PNG in pixels. |
| `logical` | `{width, height}` | `pixels / scale`, not rounded. |
| `logical.width` | number | Width of the screen in dp on Android, in points on iOS: `pixels.width / scale`. |
| `logical.height` | number | Height of the screen in dp on Android, in points on iOS: `pixels.height / scale`. |
| `scale` | number | Physical pixels per density-independent pixel on Android, per point on iOS. Android: density / 160, using the override density if one is set (`adb shell wm density`). iOS: the simulator's `SIMULATOR_MAINSCREEN_SCALE`, except `2.88` (1080 / 375) for a 1080x2340 or 2340x1080 PNG (iPhone 12 mini, 13 mini): the simulator reports 3 there, but apps lay out 375 points wide. On an iPhone, the `pointScale` that `devicectl device info displays` reports for the primary display, with the same exception. |
| `safeArea` | `{top, right, bottom, left}` or `null` | Pixels of this PNG covered by the status bar, navigation bar, caption bar or display cutout. A hidden bar counts as 0. The keyboard and gesture areas are not included. `null` on iOS: only the app itself can read its safe area, and neither the simulator nor `devicectl` exposes another source. |
| `safeArea.top` | number | Pixels covered along the top edge of the PNG. |
| `safeArea.right` | number | Pixels covered along the right edge of the PNG. |
| `safeArea.bottom` | number | Pixels covered along the bottom edge of the PNG. |
| `safeArea.left` | number | Pixels covered along the left edge of the PNG. |
| `rotation` | `0`, `90`, `180`, `270` or `null` | Screen rotation in degrees. On iOS with Xcode 27, the interface orientation from `devicectl`, in Android's meaning: turned counter-clockwise (landscape left) is `90`. `null` on Xcode 26 and earlier, or when `devicectl` fails. |

On iOS the PNG is exactly what simctl or devicectl wrote; karagoz does not rotate or re-encode it. A simulator's PNG follows the interface orientation with Xcode 27; with Xcode 26 it is the panel in portrait, and a landscape app's UI is drawn sideways in it. Its corners are square, not rounded, and the Dynamic Island area is black pixels. An iPhone's PNG has 16 bits per channel and a Display P3 color profile, about 1 to 5 MB, and follows the interface orientation.

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
- Plus the [device selection](../device-selection.md) errors, the other `INVALID_ARGS` cases and the adb errors.

**Notes**

- About 1 s on the emulator, about 0.5 s on a phone over USB, about 0.6 s on a simulator, about 0.9 s on an iPhone over USB; the first call after an iPhone was plugged in or sat idle takes a few seconds more while devicectl connects to it.
- A screen that is off, or an app that sets `FLAG_SECURE`, gives a black PNG and exit `0`; so does a locked iPhone with its screen off. Some Android 14 builds refuse the capture instead while a `FLAG_SECURE` window or the lock screen's PIN pad is showing: `CAPTURE_FAILED` with `screencap returned no data`.
- If the density changes during a capture, `scale` and `safeArea` can disagree for that one capture.
