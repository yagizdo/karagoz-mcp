# text

```
karagoz text <text> [--device <id>]
karagoz text [--device <id>] -- <text starting with ->
```

Types into whatever has focus.

| Option | Default | Meaning |
| --- | --- | --- |
| `<text>` | | The text to type, not empty. Text that starts with `-` goes after `--`. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

```json
{"device":"emulator-5554","text":"hello"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | The adb serial, or the simulator's or iPhone's UDID. |
| `text` | string | The text that was sent, as given. |

**Characters.** Any text. Printable ASCII, newline (sent as Enter), tab (sent as Tab), `ç`, `Ç` and `ß` are typed with Android's `input text`. Text with any other character, such as `ğ` or an emoji, is pasted instead, all of it: karagoz copies a small helper of its own to `/data/local/tmp`, runs it, and deletes it when the call ends. The helper puts the text on the device clipboard, presses Ctrl+V, and puts the previous clip back; newlines and tabs in it are still sent as Enter and Tab. Control characters other than newline and tab fail before anything is typed:

```json
{"error":{"code":"TEXT_UNSUPPORTED","message":"cannot type 'U+0001' on Android: control characters other than newline and tab; nothing was typed"}}
```

Quotes, spaces and `%s` are typed as they are; karagoz handles the escaping.

**Errors**

- `INVALID_ARGS`: empty text.
- `TEXT_UNSUPPORTED`: see above.
- `HELPER_FAILED`: the helper could not run on the device; the message has its error.
- Long text is sent in pieces of up to 100 characters. If a piece fails, the error keeps its code and the message ends with `; <n> of <total> characters were typed before this`.
- Plus `INPUT_BLOCKED`, the [device selection](../device-selection.md) errors and the adb errors.

**Notes**

- Characters typed right after a field appears can be lost. Waiting about 2 s after the field shows up fixed it in testing.
- 100 characters take about 0.9 s. Pasted text takes about 3 s, whatever its length.
- Android 12 and newer show "<app> pasted from your clipboard" after a paste.
- A keyboard that keeps clipboard history (Gboard with history on, Samsung Keyboard) keeps pasted text there; type secrets this way only on a device whose keyboard keeps none.
- A call killed while pasting (cable pulled, process killed) can leave the text on the clipboard instead of the previous clip. A cancelled or timed-out call can still type the whole text.

## On an iOS simulator

Any Unicode text is typed exactly, at the cursor; iOS's auto-capitalization and smart quotes and dashes are not applied.

```json
{"device":"27024DC1-EDB0-4BF2-8010-08FE3936BAB6","text":"çğş it's -- ok"}
```

- Control characters other than newline and tab fail before anything is typed: `cannot type 'U+0001' on an iOS simulator: control characters other than newline and tab; nothing was typed` (`TEXT_UNSUPPORTED`).
- An unpaired surrogate, which only MCP's JSON can carry, fails the same way: `cannot type 'U+D800' on an iOS simulator: an unpaired surrogate; nothing was typed`.
- With no focused field nothing is typed, and the call still exits `0`.
- It types 120 characters a second after about 1 s of setup: 300 characters took 3.5 s.
- A cancelled or timed-out call can still type the whole text: the simulator gets it in one piece.
- An app opened while the call ends can read as an empty tree until it is opened again ([Requirements](../requirements.md)).
- It needs Xcode 27 or newer and a simulator on iOS 27 or newer: Xcode 26 grants no automation session, and Xcode 27 none to an older runtime. Either fails at once with `NOT_SUPPORTED`: `'text' on iOS simulators needs Xcode 27 or later`, or `'text' on an iOS 26.2 simulator needs an iOS 27 or later simulator with Xcode 27 or later; tap, swipe, key and ui-tree work on it`.
- On a Mac that never had Xcode 27, the text goes through karagoz's runner instead, as [`tap`](tap.md#on-an-ios-simulator) does: any Unicode, exactly, at the same speed, on any runtime.
- Errors: `AUTOMATION_BUSY` when a UI test holds the simulator, `HELPER_FAILED` when the session is not granted or the typing fails.

## On an iPhone

Any Unicode text is typed exactly through karagoz's runner, as on the simulator (measured with Turkish letters and an emoji).

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","text":"karagoz çğıİş 😀"}
```

- Control characters other than newline and tab fail before anything is sent: `cannot type 'U+0001' on an iPhone: ...` (`TEXT_UNSUPPORTED`).
- So does an unpaired surrogate: `cannot type 'U+D800' on an iPhone: an unpaired surrogate; nothing was typed`.
- A newline acts as Return: in a single-line field it ends editing, and what follows it is not typed. A tab is typed as a tab.
- With no focused field nothing is typed, and the call still exits `0`.
- 120 characters a second: 20 characters took 0.6 s, 300 took 2.9 s.
- Errors: those of [`tap` on an iPhone](tap.md#on-an-iphone).
