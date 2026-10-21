# key

```
karagoz key <key> [--device <id>]
```

Presses one key.

`<key>` is an Android [KeyEvent](https://developer.android.com/reference/android/view/KeyEvent) name or code:

- A name, case-insensitive, with or without `KEYCODE_`: `HOME`, `back`, `KEYCODE_ENTER`, `VOLUME_UP`.
- A number from 1 to 340 is a key code: `key 3` is `HOME`. To press the digit 7, use `KEYCODE_7`, because `key 7` is code 7, which is `KEYCODE_0`.

**Output**

```json
{"device":"emulator-5554","key":"KEYCODE_HOME","code":3}
```

`key` is the resolved name and `code` its number.

**Errors**

- `INVALID_ARGS`: `unknown key 'FOO'; use a KeyEvent name such as HOME, BACK or ENTER, or a code from 1 to 340`. Checked before any device call.
- Plus `INPUT_BLOCKED`, the [device selection](../device-selection.md) errors and the adb errors.

**Notes**

- A device knows the key codes of its Android version only (12: up to 288, 13: 304, 14: 316, 15: 318, 16: 337); a higher code is sent as `KEYCODE_UNKNOWN`, still with exit `0`.
- Some keys act on the whole device: code 312 opens Recents, 318 saves a screenshot.
- Exit `0` means Android accepted the key, not that the app reacted to it.

## On an iOS simulator

The same names and codes, and the same output. Only these have an iOS key:

| Name | On the simulator |
| --- | --- |
| `HOME` | The Home button |
| `POWER` | The side button: locks the screen |
| `VOLUME_UP`, `VOLUME_DOWN` | The volume buttons |
| `A`-`Z`, `0`-`9`, `ENTER`, `DEL` (backspace), `FORWARD_DEL`, `TAB`, `SPACE`, `ESCAPE`, `DPAD_UP`, `DPAD_DOWN`, `DPAD_LEFT`, `DPAD_RIGHT`, `MOVE_HOME`, `MOVE_END`, `PAGE_UP`, `PAGE_DOWN`, `F1`-`F24`, `COMMA`, `PERIOD`, `MINUS`, `EQUALS`, `LEFT_BRACKET`, `RIGHT_BRACKET`, `BACKSLASH`, `SEMICOLON`, `APOSTROPHE`, `SLASH`, `GRAVE`, `SHIFT_*`, `CTRL_*`, `ALT_*`, `META_*`, `CAPS_LOCK` | The hardware keyboard key |

Any other name fails before anything is sent:

```json
{"error":{"code":"INVALID_ARGS","message":"'BACK' has no iOS simulator key; iOS takes HOME, POWER, VOLUME_UP, VOLUME_DOWN and keyboard keys (letters, digits, ENTER, DEL, TAB, ESCAPE, DPAD_*, F1-F24); tap the app's back button or swipe from the left edge"}}
```

- Each key is pressed alone, with no modifier held.
- Keyboard keys act only where iOS uses them: in a focused field, or with Full Keyboard Access. A letter goes through iOS's typing, so auto-capitalization applies: `key A` in an empty field typed `A`.
- Errors: `NOT_SUPPORTED`, `DEVICE_NOT_READY` and `HELPER_FAILED` as for [`tap`](tap.md#on-an-ios-simulator).

## On an iPhone

The same names, codes and output, through karagoz's runner. Fewer keys have an iPhone counterpart:

| Name | On an iPhone |
| --- | --- |
| `HOME` | Brings the Home screen to the front; when it is already in front nothing changes (the page, an open folder). |
| `POWER` | The side button: locks the screen. Unlocking is yours, and the next runner start asks for the passcode on the phone. |
| `VOLUME_UP`, `VOLUME_DOWN` | The volume buttons |
| `A`-`Z` (typed lowercase), `0`-`9`, `SPACE`, `ENTER` (Return), `TAB`, `DEL` (backspace), `ESCAPE`, `MINUS`, `EQUALS`, `LEFT_BRACKET`, `RIGHT_BRACKET`, `BACKSLASH`, `SEMICOLON`, `APOSTROPHE`, `GRAVE`, `COMMA`, `PERIOD`, `SLASH` | The character, typed as [`text`](text.md#on-an-iphone) types it |

A key that types no character (`DPAD_*`, `F1`-`F24`, `PAGE_UP`, `MOVE_HOME`, `FORWARD_DEL`, modifiers) fails before anything is sent:

```json
{"error":{"code":"INVALID_ARGS","message":"'DPAD_UP' has no iPhone key; an iPhone takes HOME, POWER, VOLUME_UP, VOLUME_DOWN and keys that type a character (letters, digits, SPACE, ENTER, TAB, DEL, ESCAPE, punctuation)"}}
```

A volume key takes about 0.4 s, `POWER` about 0.9 s. Errors: those of [`tap` on an iPhone](tap.md#on-an-iphone).
