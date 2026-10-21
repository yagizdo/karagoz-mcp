# swipe

```
karagoz swipe <x1> <y1> <x2> <y2> [--duration <ms>] [--device <id>]
```

Moves one finger from `(x1, y1)` to `(x2, y2)`.

| Option | Default | Meaning |
| --- | --- | --- |
| `<x1> <y1> <x2> <y2>` | | [Screen pixels](../output.md#coordinates), same rules as `tap`. |
| `--duration <ms>` | `300` | Time from start to end. Whole milliseconds, 0 to 999999999. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

```json
{"device":"emulator-5554","x1":540,"y1":1800,"x2":540,"y2":600,"duration":300}
```

`duration` is always present, including the default.

**Duration matters.** A fast swipe flings a list and a slow one drags it. Measured on a 1200 px drag: 300 ms scrolled a further 1059 px after the finger lifted, 1000 ms scrolled 131 px further, 3000 ms 19 px.

**Errors:** `INVALID_ARGS`, `INPUT_BLOCKED`, the [device selection](../device-selection.md) errors and the adb errors. On a simulator, `NOT_SUPPORTED`, `DEVICE_NOT_READY` and `HELPER_FAILED` as for [`tap`](tap.md#on-an-ios-simulator).

On an iOS simulator the arguments and output are the same, with the same default duration:

```json
{"device":"27024DC1-EDB0-4BF2-8010-08FE3936BAB6","x1":603,"y1":2228,"x2":603,"y2":917,"duration":300}
```

On an iPhone too, through karagoz's runner, with the errors of [`tap`](tap.md#on-an-iphone) there:

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","x1":645,"y1":2097,"x2":645,"y2":699,"duration":1000}
```

The duration is played as given. On a 1398 px drag up a list, 300 ms flung it out of view, 1000 ms moved it 1318 px and 3000 ms 1354 px.
