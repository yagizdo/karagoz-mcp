# install-runner

```
karagoz install-runner [--device <id>] [--team <ID>]
```

Builds karagoz's runner, the small XCUITest bundle that [`ui-tree`](ui-tree.md#on-an-iphone), `tap`, `long-press`, `swipe`, `text` and `key` use on an iPhone, with your Apple team, and installs it on a paired iPhone. It is the one command that puts something of karagoz's on an iPhone; no other command installs the runner there. A simulator needs no install step: on a Mac that never had Xcode 27, the first `tap`, `long-press`, `swipe`, `text` or `key` installs the runner on it ([Requirements](../requirements.md)). macOS only.

| Option | Default | Meaning |
| --- | --- | --- |
| `--device <id>` | see [Device selection](../device-selection.md) | An iPhone's UDID or model. A simulator or an Android device is refused with `NOT_SUPPORTED`. |
| `--team <ID>` | the only team in Xcode, else the only paid one | The 10-character Apple team ID to sign with. |

**Output**

```json
{"device":"XXXXXXXX-XXXXXXXXXXXXXXXX","bundleId":"com.karagozmcp.runner.xxxxxxxxxx.xctrunner","team":"XXXXXXXXXX"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | The iPhone's UDID. |
| `bundleId` | string | The runner app on the phone: `com.karagozmcp.runner.<team, lowercased>.xctrunner`. The team keeps the id unique, which a free account needs. |
| `team` | string | The team it was signed with. |

What it does:

1. Picks the team: `--team`, else the teams Xcode saved for the Apple accounts in Xcode > Settings > Accounts.
2. Builds with `xcodebuild build-for-testing` and automatic signing (`-allowProvisioningUpdates`, `-allowProvisioningDeviceRegistration`) into `~/Library/Caches/karagoz/runner/`. Xcode creates a development certificate in your keychain when there is none, registers the iPhone on your developer account and signs with a team profile; with a paid team it used the team's wildcard profile. These stay on your Mac and account.
3. Installs the app with `devicectl device install app`.

Run it again after updating karagoz or Xcode, for another iPhone, and every 7 days with a free account. The MCP tool is `install_runner`.

**Errors:** `HELPER_FAILED` (no Xcode, no Apple account or team in Xcode, a failed build with xcodebuild's error lines and the log path), `INVALID_ARGS` (a malformed `--team`, or several teams and none chosen), `INSTALL_FAILED`, `DEVICE_NOT_READY` (not paired, Developer Mode off, locked), `NOT_SUPPORTED`, the devicectl errors and the [device selection](../device-selection.md) errors.

**Notes**

- Took 17 s the first time (build, certificate and profile, install) and 3 s again with the build cached.
- The build needs the network the first time: Xcode talks to Apple's developer service.
