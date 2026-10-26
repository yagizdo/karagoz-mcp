# uninstall-runner

```
karagoz uninstall-runner [--device <id>]
```

Removes every karagoz runner app from the iPhone (`com.karagozmcp.runner.*.xctrunner`, any team) and the provisioning profiles made for those ids. A team wildcard profile is left: other apps share it. macOS only.

On a Mac that never had Xcode 27 it also takes a simulator, where the first input installed the runner: it removes `com.karagozmcp.runner.xctrunner`, as `xcrun simctl uninstall <udid> com.karagozmcp.runner.xctrunner` does, and `profiles` is empty. A running runner's `xcodebuild` ends by itself within about half a minute. Elsewhere a simulator, and an Android device on any Mac, is refused with `NOT_SUPPORTED`.

**Output**

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","apps":["com.karagozmcp.runner.xxxxxxxxxx.xctrunner"],"profiles":[]}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | The iPhone's or simulator's UDID. |
| `apps` | array of strings | The bundle ids of the runner apps removed. |
| `profiles` | array of strings | The UUIDs of the provisioning profiles removed. |

Nothing to remove is not an error: both lists are empty. A running runner stops with its app. The build cache on the Mac, the certificate in your keychain and the iPhone's registration on your developer account stay. The MCP tool is `uninstall_runner`.

**Errors:** `UNINSTALL_FAILED`, `DEVICE_NOT_READY`, `NOT_SUPPORTED`, the devicectl errors (the simctl errors on a simulator) and the [device selection](../device-selection.md) errors.
