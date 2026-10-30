# Device selection

Every command except `devices`, `doctor` and `mcp` works on one device, picked in this order:

1. `--device <id>`
2. the `KARAGOZ_DEVICE` environment variable
3. the `ANDROID_SERIAL` environment variable
4. the only listed device

A variable is ignored when anything above it is given; an empty one counts as unset. `KARAGOZ_DEVICE` names a device on either platform.

The value is matched against every listed id first, exactly: adb serials (`emulator-5554`) and, on macOS, the UDIDs of booted simulators and connected iPhones. If no id matches, it is matched against every `name` that [`devices`](commands/devices.md) prints: an emulator's AVD name (`Medium_Phone_API_36.1`), a phone's model (`SM-S908N`), a simulator's name (`iPhone 17 Pro`) or an iPhone's model (`iPhone 14 Pro Max`), exactly and case-sensitively. A name matched on both platforms, or by an iPhone and a simulator, is ambiguous; neither wins.

| Situation | Error |
| --- | --- |
| A value is given and nothing matches | `DEVICE_NOT_FOUND`, listing what is connected |
| No value, nothing connected | `NO_DEVICE` |
| No value and two or more devices listed (in any state), or a name that matches two entries: the same AVD listed as `emulator-5554` and `127.0.0.1:5555`, or two phones of the same model | `DEVICE_AMBIGUOUS` |
| `install-runner` or `uninstall-runner` picked a simulator or an Android device (`uninstall-runner` also takes a simulator on a Mac that never had Xcode 27). This comes before any readiness check. | `NOT_SUPPORTED` |
| The picked device is not in state `device` (`offline`, `unauthorized`, ...), a simulator not `Booted` (`Booting`, `Shutting Down`), or an iPhone not `paired` (`unpaired`, `pairingInProgress`; the message says what to do on the phone) | `DEVICE_NOT_READY` |

karagoz never guesses between devices. There is no config file.

On macOS every command that targets a device lists booted simulators and connected iPhones next to adb's devices, in parallel. A missing `adb`, `simctl` or `devicectl` means that listing has no devices. Any other failure of one listing stops the command, unless the value is an id another listing returned: a hung simulator service makes a bare call fail with `SIMCTL_TIMEOUT` after 30 s, a hung CoreDevice service with `DEVICECTL_TIMEOUT` after 10 s. When nothing is listed and `adb` is missing, the error is `ADB_NOT_FOUND`.

A phone connected over Wi-Fi as well as USB is listed twice, once per serial, and its model matches both: pick it by serial then. Quote a `--device` value that contains spaces, as some mDNS serials do.
