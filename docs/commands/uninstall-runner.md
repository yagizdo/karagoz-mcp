# uninstall-runner

```
karagoz uninstall-runner [--device <id>]
```

Removes every karagoz runner app from the iPhone (`com.karagozmcp.runner.*.xctrunner`, any team) and the provisioning profiles made for those ids. A team wildcard profile is left: other apps share it. macOS only; a simulator or an Android device is refused with `NOT_SUPPORTED`.

**Output**

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","apps":["com.karagozmcp.runner.xxxxxxxxxx.xctrunner"],"profiles":[]}
```

`apps` are the bundle ids removed, `profiles` the UUIDs of the profiles removed. Nothing to remove is not an error: both lists are empty. A running runner stops with its app. The build cache on the Mac, the certificate in your keychain and the iPhone's registration on your developer account stay. The MCP tool is `uninstall_runner`.

**Errors:** `UNINSTALL_FAILED`, `DEVICE_NOT_READY`, `NOT_SUPPORTED`, the devicectl errors and the [device selection](../device-selection.md) errors.
