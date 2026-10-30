# long-press

```
karagoz long-press <x> <y> [--duration <ms>] [--device <id>]
karagoz long-press --text <label> [--timeout <ms>] [--duration <ms>] [--device <id>]
karagoz long-press --id <resource-id> [--timeout <ms>] [--duration <ms>] [--device <id>]
```

Presses a point and holds it, or finds one node in the [tree](ui-tree.md) and holds its center. Give exactly one of `<x> <y>`, `--text` or `--id`; nodes are found as in [`tap`](tap.md).

| Option | Default | Meaning |
| --- | --- | --- |
| `<x> <y>` | | A point in [screen pixels](../output.md#coordinates). Non-negative, decimals allowed (`12`, `12.5`). |
| `--text <label>` | | A node whose `text` or `contentDesc` equals the label, as in [`tap`](tap.md). |
| `--id <resource-id>` | | A node whose `resourceId` equals the value, or ends with `:id/<value>`, as in [`tap`](tap.md). |
| `--duration <ms>` | `1000` | How long to hold. Whole milliseconds, 0 to 999999999. |
| `--timeout <ms>` | `0` | Keep reading the tree until a node matches or this much time has passed. Only with `--text` or `--id`. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

```json
{"device":"emulator-5554","x":540,"y":1100,"duration":1000}
```

With `--text` or `--id`, an `element` field follows `duration`.

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | The adb serial, or the simulator's or iPhone's UDID. |
| `x` | number | Where the press went, in [screen pixels](../output.md#coordinates): the point given, or the matched node's center. |
| `y` | number | Where the press went, in screen pixels: the point given, or the matched node's center. |
| `duration` | number | How long the touch was held, in milliseconds. |
| `element` | object | Only with `--text` or `--id`: the matched node, with the fields [`tap`](tap.md) lists. |

**Errors**

- `INVALID_ARGS`: no target or more than one (`'long-press' takes <x> <y>, --text or --id`), a single coordinate (`'long-press' needs <x> <y>`), `--timeout` with a point, or a malformed number.
- The rest as [`tap`](tap.md): `ELEMENT_NOT_FOUND`, `ELEMENT_AMBIGUOUS`, `ELEMENT_COVERED`, the `ui-tree` errors for node presses, and those of the target.

**Notes**

- The press is sent as a swipe that does not move. View and Compose use the device's long-press setting (`settings get secure long_press_timeout`; 400 ms on stock Android, Samsung offers 300 to 1500 ms), Flutter 500 ms. The 1000 ms default covers all of them but Samsung's 1500 ms setting, which needs `--duration`.
- Exit `0` means Android accepted the event, not that the app reacted to it. Read the tree again to check.

## On an iOS simulator

Same arguments and output. The touch goes to the simulator's own input service and is held there, or through karagoz's runner on a Mac that never had Xcode 27, as for [`tap`](tap.md#on-an-ios-simulator).

## On an iPhone

Same arguments and output; karagoz's runner holds the touch, as for [`tap`](tap.md#on-an-iphone). For a shorter `--duration`, pass more than the app's press time: with a 0.5 s long press, 500 ms did not trigger it and 550 ms did.
