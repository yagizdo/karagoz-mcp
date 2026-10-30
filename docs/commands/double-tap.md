# double-tap

```
karagoz double-tap <x> <y> [--device <id>]
karagoz double-tap --text <label> [--timeout <ms>] [--device <id>]
karagoz double-tap --id <resource-id> [--timeout <ms>] [--device <id>]
```

Taps a point twice, or finds one node in the [tree](ui-tree.md) and taps its center twice. Give exactly one of `<x> <y>`, `--text` or `--id`; nodes are found as in [`tap`](tap.md). It selects a word in a text field, or fires a double-tap gesture.

| Option | Default | Meaning |
| --- | --- | --- |
| `<x> <y>` | | A point in [screen pixels](../output.md#coordinates). Non-negative, decimals allowed (`12`, `12.5`). |
| `--text <label>` | | A node whose `text` or `contentDesc` equals the label, as in [`tap`](tap.md). |
| `--id <resource-id>` | | A node whose `resourceId` equals the value, or ends with `:id/<value>`, as in [`tap`](tap.md). |
| `--timeout <ms>` | `0` | Keep reading the tree until a node matches or this much time has passed. Only with `--text` or `--id`. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

```json
{"device":"emulator-5554","x":540,"y":160}
```

The same fields as [`tap`](tap.md): `device`, `x`, `y`, and `element` with `--text` or `--id`.

**Timing**

Each touch is held 50 ms, and the second starts 100 ms after the first lifts, on every target. Both touches come from one process, so nothing else sets the gap. The window this fits: Android takes the second press 40-300 ms after the first lift and within 300 ms of the first press.

**Errors**

- `INVALID_ARGS`: no target or more than one (`'double-tap' takes <x> <y>, --text or --id`), a single coordinate (`'double-tap' needs <x> <y>`), `--timeout` with a point, or a malformed number.
- `HELPER_FAILED`: the input helper failed on the device, with its error in the message.
- The rest as [`tap`](tap.md): `ELEMENT_NOT_FOUND`, `ELEMENT_AMBIGUOUS`, `ELEMENT_COVERED`, `INPUT_BLOCKED`, the `ui-tree` errors for node taps, and those of the target.

**Notes**

- On Android karagoz pushes its small helper to `/data/local/tmp`, as [`text`](text.md) does for text beyond ASCII, runs it, and removes it in the same call. A call takes about 1.5-3.5 s on an emulator, most of it the helper's start.
- Exit `0` means the device accepted the touches, not that the app reacted to them. Read the tree again to check.

## On an iOS simulator

Same arguments and output. The two touches go to the simulator's own input service, or through karagoz's runner on a Mac that never had Xcode 27, as for [`tap`](tap.md#on-an-ios-simulator).

## On an iPhone

Same arguments and output; karagoz's runner plays both touches in one event, as for [`tap`](tap.md#on-an-iphone). The runner changed with `double-tap`: after updating karagoz to this version, run [`install-runner`](install-runner.md) again. Until then every call that needs the runner fails with `RUNNER_NOT_INSTALLED`.
