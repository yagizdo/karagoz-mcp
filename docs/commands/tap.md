# tap

```
karagoz tap <x> <y> [--duration <ms>] [--device <id>]
karagoz tap --text <label> [--timeout <ms>] [--duration <ms>] [--device <id>]
karagoz tap --id <resource-id> [--timeout <ms>] [--duration <ms>] [--device <id>]
```

Taps a point, or finds one node in the [tree](ui-tree.md) and taps its center. Give exactly one of `<x> <y>`, `--text` or `--id`.

| Option | Default | Meaning |
| --- | --- | --- |
| `<x> <y>` | | A point in [screen pixels](../output.md#coordinates). Non-negative, decimals allowed (`12`, `12.5`). |
| `--text <label>` | | A node whose `text` or `contentDesc` equals the label: whole string, case-sensitive, no trimming. Invisible direction marks (U+200E and the like) are ignored on both sides. |
| `--id <resource-id>` | | A node whose `resourceId` equals the value, or ends with `:id/<value>`. `--id save` matches `com.example:id/save`. |
| `--duration <ms>` | none | Hold for this long (a long press). Whole milliseconds, 0 to 999999999. |
| `--timeout <ms>` | `0` | Keep reading the tree until a node matches or this much time has passed. Only with `--text` or `--id`. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

Point:

```json
{"device":"emulator-5554","x":540,"y":1200}
```

With `--duration 10` a `"duration":10` field follows `y`. Node:

```json
{"device":"emulator-5554","x":667.5,"y":2002.5,"element":{"class":"android.widget.TextView","text":"Chrome","contentDesc":"Chrome","clickable":true,"longClickable":true,"focusable":true,"bounds":[581,1905,754,2100]}}
```

`element` is the matched node as [`ui-tree`](ui-tree.md) returns it, without `children`. `x` and `y` are its center.

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
- Node taps also get every [`ui-tree`](ui-tree.md) error. A point tap does not read the tree, so it works while another UiAutomation client is connected.
- Plus `INPUT_BLOCKED`, the [device selection](../device-selection.md) errors and the adb errors.

**Notes**

- A point tap takes about 0.2 s. A node tap adds one tree read, 2.5 to 3.3 s.
- Points are not checked against the screen size.
- Exit `0` means Android accepted the event, not that the app reacted to it. Read the tree again to check.

## On an iOS simulator

Same arguments and output. The point goes to the simulator's own input service as a real touch, and `--duration` holds it there.

```json
{"device":"27024DC1-EDB0-4BF2-8010-08FE3936BAB6","x":603,"y":1015,"element":{"role":"Button","label":"Tap me 0","identifier":"tap-button","bounds":[48,937,1158,1093]}}
```

- `--text` matches a node's `label` or `value`, `--id` its `identifier`; both whole and case-sensitive, direction marks ignored. There is no `:id/` rule.
- The node is tapped at its center like a finger, so what covers it gets the tap.
- There is no keyboard check on a simulator. The message for no match is `no node with label or value 'Save' in the frontmost app (1 read in 0.3 s)`.
- A tap takes about 0.6 s; a node tap adds one tree read, about 0.3 s.
- Errors: `NOT_SUPPORTED` with Xcode 26 or older, `DEVICE_NOT_READY` when the input service does not answer within 4 s (a simulator that has just booted), `HELPER_FAILED`, and for node taps the [`ui-tree` errors on iOS](ui-tree.md#on-an-ios-simulator).

## On an iPhone

Same arguments and output. karagoz's runner plays the touch; it is started and stopped as for [`ui-tree`](ui-tree.md#on-an-iphone), and installed with [`install-runner`](install-runner.md). The pixels are turned into the panel's points for the interface orientation; measured in portrait and both landscapes.

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","x":645,"y":1006}
```

- `--text` and `--id` match as on the simulator. Unlike there, a node whose center the on-screen keyboard covers is refused with `ELEMENT_COVERED` (a key of the keyboard itself can be tapped); hide the keyboard first, for example with `key ENTER` in a single-line field.
- `--duration` holds for that long: on a test app with a 0.5 s long press, 500 ms did not trigger it and 550 ms did.
- A tap takes about 0.6 s; the first after the runner stopped about 3.3 s.
- Errors: those of [`ui-tree` on an iPhone](ui-tree.md#on-an-iphone), with `HELPER_FAILED` for a touch the runner could not play.
