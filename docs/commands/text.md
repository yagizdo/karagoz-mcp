# text

```
karagoz text <text> [--device <id>]
karagoz text [--device <id>] -- <text starting with ->
```

Types into whatever has focus, as Android's `input text` does.

**Output**

```json
{"device":"emulator-5554","text":"hello"}
```

**Characters.** Printable ASCII, newline (sent as Enter), tab (sent as Tab), `ç`, `Ç` and `ß`. Anything else fails before anything is typed:

```json
{"error":{"code":"TEXT_UNSUPPORTED","message":"cannot type 'ü' (U+00FC): Android's input text types only printable ASCII, newline, tab, ç, Ç and ß; nothing was typed"}}
```

Quotes, spaces and `%s` are typed as they are; karagoz handles the escaping.

**Errors**

- `INVALID_ARGS`: empty text.
- `TEXT_UNSUPPORTED`: see above.
- Long text is sent in pieces of up to 100 characters. If a piece fails, the error keeps its code and the message ends with `; <n> of <total> characters were typed before this`.
- Plus `INPUT_BLOCKED`, the [device selection](../device-selection.md) errors and the adb errors.

**Notes**

- Characters typed right after a field appears can be lost. Waiting about 2 s after the field shows up fixed it in testing.
- 100 characters take about 0.9 s.

## On an iOS simulator

Any Unicode text is typed exactly, at the cursor; iOS's auto-capitalization and smart quotes and dashes are not applied.

```json
{"device":"27024DC1-EDB0-4BF2-8010-08FE3936BAB6","text":"çğş it's -- ok"}
```

- Control characters other than newline and tab fail before anything is typed: `cannot type 'U+0001' on an iOS simulator: control characters other than newline and tab; nothing was typed` (`TEXT_UNSUPPORTED`).
- With no focused field nothing is typed, and the call still exits `0`.
- It types 120 characters a second after about 1 s of setup: 300 characters took 3.5 s.
- A cancelled or timed-out call can still type the whole text: the simulator gets it in one piece.
- An app opened while the call ends can read as an empty tree until it is opened again ([Requirements](../requirements.md)).
- Errors: `AUTOMATION_BUSY` when a UI test holds the simulator, `HELPER_FAILED` when the session is not granted or the typing fails.

## On an iPhone

Any Unicode text is typed exactly through karagoz's runner, as on the simulator (measured with Turkish letters and an emoji).

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","text":"karagoz çğıİş 😀"}
```

- Control characters other than newline and tab fail before anything is sent: `cannot type 'U+0001' on an iPhone: ...` (`TEXT_UNSUPPORTED`).
- A newline acts as Return: in a single-line field it ends editing, and what follows it is not typed. A tab is typed as a tab.
- With no focused field nothing is typed, and the call still exits `0`.
- 120 characters a second: 20 characters took 0.6 s, 300 took 2.9 s.
- Errors: those of [`tap` on an iPhone](tap.md#on-an-iphone).
