# devices

```
karagoz devices
```

Lists what `adb devices` lists and, on macOS, the iOS simulators that are running and the iPhones connected to the Mac. Takes no options.

**Output**

```json
{"devices":[{"id":"emulator-5554","platform":"android","kind":"emulator","state":"device","name":"Medium_Phone_API_36.1"}]}
```

A phone on USB next to the emulator (serial masked):

```json
{"devices":[{"id":"XXXXXXXXXXX","platform":"android","kind":"physical","state":"device","name":"SM-S908N"},{"id":"emulator-5554","platform":"android","kind":"emulator","state":"device","name":"Medium_Phone_API_36.1"}]}
```

An iOS simulator running next to the emulator (macOS):

```json
{"devices":[{"id":"emulator-5554","platform":"android","kind":"emulator","state":"device","name":"Medium_Phone_API_36.1"},{"id":"4E70BFCA-5FC6-49B5-92EC-48E265B2D50F","platform":"ios","kind":"simulator","state":"Booted","name":"iPhone 17 Pro"}]}
```

An iPhone on USB next to the emulator (macOS, UDID masked, simulator rows left out):

```json
{"devices":[{"id":"emulator-5554","platform":"android","kind":"emulator","state":"device","name":"Medium_Phone_API_37.0"},{"id":"XXXXXXXX-XXXXXXXXXXXXXXXX","platform":"ios","kind":"physical","state":"paired","name":"iPhone 14 Pro Max","runner":"installed"}]}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | The adb serial, or the simulator's or iPhone's UDID. Pass it to `--device`. |
| `platform` | `"android"` or `"ios"` | |
| `kind` | `"emulator"`, `"physical"` or `"simulator"` | `simulator` for iOS simulators, `physical` for iPhones. `emulator` when the id is `emulator-<port>`, or when the device reports `ro.boot.qemu` or `ro.kernel.qemu` as `1`, or `ro.hardware` as `ranchu` or `goldfish` (an emulator attached with `adb connect`). Genymotion, and other ids not in state `device`, read as `physical`. |
| `state` | string | adb's state, unchanged: `device`, `offline`, `unauthorized`, ... Only `device` can be used. For simulators, simctl's state: `Booted`, `Booting`, `Shutting Down`; only `Booted` is usable. For iPhones, devicectl's pairing state: `paired`, `unpaired` (unlock the phone and tap Trust when it asks), `pairingInProgress`. |
| `name` | string or `null` | The AVD name for emulators, the model (`ro.product.model`) for phones, the simulator's name for simulators, the model (`iPhone 14 Pro Max`) for iPhones, `null` for an unpaired iPhone and for a paired one devicectl is not connected to (right after pairing, or when the connection went idle; pick it by UDID then). `null` when the device does not answer, or when it is not in state `device` and its id is not `emulator-<port>`. |
| `runner` | string or `null` | iPhones only: karagoz's runner ([`install-runner`](install-runner.md)) on the phone. `running` when it answers, `installed` or `not installed` from the phone's app list, `null` for an iPhone that is not paired or whose app list could not be read. |

No devices is not an error: `{"devices":[]}`, exit `0`. Android devices come first in adb's order, then simulators in simctl's order, then iPhones in devicectl's order.

If adb, simctl or devicectl is missing, fails or hangs, the other listings are still printed, `errors` holds one `{"platform","code","message"}` per failed listing (two `ios` entries when simctl and devicectl both fail), and the exit is `0`. When every listing tried fails, Android's error is printed as the usual envelope and the exit is `1`. On Linux and Windows simulators and iPhones are not looked for.

**Errors:** `INVALID_ARGS`, `ADB_NOT_FOUND`, `ADB_TIMEOUT`, `ADB_FAILED`; `SIMCTL_NOT_FOUND`, `SIMCTL_TIMEOUT`, `SIMCTL_FAILED`, `DEVICECTL_NOT_FOUND`, `DEVICECTL_TIMEOUT`, `DEVICECTL_FAILED` inside `errors` only.

**Notes**

- About 55 ms, plus about 50 ms per emulator for its name, asked in parallel. A device whose id is not `emulator-<port>` costs one more call in parallel, a chained `getprop` of about 135 ms. With a phone on USB and one emulator, the whole `karagoz devices` run took 257 to 289 ms (three runs, macOS).
- On macOS the simulator listing runs in parallel with adb and takes about 0.12 s once the simulator service runs. The first call after login can take several seconds while macOS starts that service (30 s limit).
- Shut-down simulators, and watchOS, tvOS and visionOS simulators, are not listed.
- For each paired iPhone, `runner` costs one connection to the runner over USB, and when it does not answer one `devicectl device info apps` call: about 0.21 s for the whole run with the runner up, 0.36 s with it down (measured on one iPhone). Other commands do not pay for it.
- The iPhone listing is one `devicectl list devices` call, also in parallel, about 0.06 s. devicectl also knows simulators, phones paired before but not connected now, and nearby devices that could be paired: none of them is listed. iPhones on iOS 16 and older are not listed either. An iPad is listed the way an iPhone is.
- A device listed as `(no serial number)`, or two devices that share one serial, cannot be targeted: adb's `-s` cannot tell them apart.
- karagoz does not pair or connect over Wi-Fi. Use `adb pair` and `adb connect`; a paired Android 11+ phone reconnects by itself.
- If an emulator's name comes back `null`, check that `HOME` points to your home directory; the emulator console reads a token from there.
