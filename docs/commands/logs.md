# logs

```
karagoz logs [--package <package>] [--since <seconds>] [--lines <n>] [--device <id>]
```

Reads the device log once and prints the newest records as JSON. Each record is whole: a stack trace is one record with newlines in its message, not one entry per line.

| Option | Default | Meaning |
| --- | --- | --- |
| `--package <package>` | all records | Keep only this app's records. On Android, those written under its Linux user id (uid) in the main Android user; on a simulator, see [On an iOS simulator](#on-an-ios-simulator); on an iPhone, see [On an iPhone](#on-an-iphone). |
| `--since <seconds>` | Android: the whole log. iOS: the last minute, or the last hour with `--package` | Unix time in seconds on the device clock, up to 9 decimals and at most 4294967295. Only records stamped later are read. |
| `--lines <n>` | `30` | How many of the newest matching records to return, 1 to 999999999. |
| `--device <id>` | see [Device selection](../device-selection.md) | |

**Output**

```json
{"device":"emulator-5554","package":"com.android.shell","uid":2000,"records":[{"time":1790521762.474251,"pid":24931,"tid":24931,"level":"I","tag":"KaragozManual","message":"hello from karagoz"}],"omitted":0}
```

That record was written with `adb shell log -t KaragozManual "hello from karagoz"`; `adb shell` runs as `com.android.shell`.

| Field | Type | Meaning |
| --- | --- | --- |
| `device` | string | The adb serial, or the simulator's or iPhone's UDID. |
| `package` | string | Only with `--package`: the package as given. |
| `uid` | number | Only with `--package`, on Android: the uid the records were matched on. `com.android.settings` has 1000, which it shares with the system server. |
| `records` | array | The matching records, at most `--lines`, oldest first: on Android in the order the device's log daemon received them, on iOS by time. |
| `records[].time` | number | When the record was written: seconds since the Unix epoch on the device clock, to the microsecond. Rounded up on Android; on iOS as `log` prints it. |
| `records[].pid` | number | Id of the process that wrote it. |
| `records[].tid` | number | Id of the thread that wrote it. |
| `records[].level` | string | `V`, `D`, `I`, `W`, `E` or `F`; `?` for any other priority. On iOS, `D`, `I`, `E`, `F` or `?` (see [On an iOS simulator](#on-an-ios-simulator)). |
| `records[].tag` | string | On Android the log tag; on iOS the name of the process that wrote it. |
| `records[].subsystem` | string | Only on iOS: the record's `os_log` subsystem, `""` when it has none. |
| `records[].category` | string | Only on iOS: the record's `os_log` category, `""` when it has none. |
| `records[].message` | string | The message, newlines kept. |
| `omitted` | number | How many older matching records `--lines` left out. `0` when `records` holds every match. |

An empty `records` with `omitted` `0` means nothing matched. It is not an error.

**Reading since your last call.** Pass the largest `time` of one result as the next `--since` to get only newer records. The rounding up makes this exact: no record comes back in the next call. After the call above:

```
karagoz logs --package com.android.shell --since 1790521762.474251
```

```json
{"device":"emulator-5554","package":"com.android.shell","uid":2000,"records":[],"omitted":0}
```

Take the largest `time`, not the last record's: records are in arrival order, and times can step back by a few milliseconds.

**Errors**

- `INVALID_ARGS`: `'<value>' is not a package name`, as for [`launch`](launch.md); `--since must be Unix time in seconds (got '<value>')`; `--lines must be a whole number from 1 to 999999999 (got '<value>')`. Checked before any device call.
- `APP_NOT_FOUND`: `package 'dev.karagoz.missing' is not installed on emulator-5554`.
- `ADB_FAILED`: logcat printed its own error instead of records, such as `Failed to wait for logd.ready to become true. logd not running?`; the output was not whole log records; or `pm list packages` printed an error while karagoz looked up the uid. The message is that output, cut at 300 characters. A log larger than the 64 MB karagoz reads at once is `ADB_FAILED` too, with a message that says to pass `--since`.
- `ADB_TIMEOUT` after 10 s.
- Plus the [device selection](../device-selection.md) errors and the adb errors.

**Notes on Android**

- Logs read: main, system and crash, plus kernel from Android 11, logcat's defaults. The events log is not read.
- The log is never cleared, resized or reconfigured, so other tools and the user keep their history. A call reads what is there and exits; nothing streams. To wait for a line, call again with `--since`.
- The whole window is read from the device and filtered on the host, because logcat counts records before it filters by uid. A full log on the test emulator was 26 MB, about 133,000 records: `logs --lines 1` took 0.7 s, 0.8 s with `--package`. The default 30 records come to about 7 KB of JSON on average; over every 30-record window of a 141,000-record log, the largest was 47 KB.
- `--package` matches the uid, not a process: every process of the app, every restart, and its Java and native crash lines. Lines the system server writes about the app, such as `Start proc` and `ANR in`, have uid 1000 and are not included. A package that shares a system uid, such as Settings, gets the other processes of that uid as well.
- `--package` reads the app in the main Android user. Its copies in Secure Folder, a work profile or a second instance (Dual Messenger, Dual Apps) run under another uid and are not included.
- A record stamped at or before `--since` that the log daemon receives after the previous read is returned by neither call. Records arrived up to 54 ms late in testing.
- `--since` is on the device clock, which can differ from the computer's: a phone ran 10 s behind with automatic time on, so a computer timestamp skipped every new record. Pass a `time` from an earlier result.
- A missing line does not prove the app did not write it: some phones drop lines before they reach the log. A `log.tag` property of `I` (`adb shell getprop log.tag`) drops `D` and `V` lines, Developer options' "Logger buffer sizes: Off" drops nearly all, and Huawei and Honor phones keep app logs off until "AP Log" is turned on in a hidden menu.
- Android cuts a record's tag and message at 4068 bytes together when it is written. Bytes that are not valid UTF-8 become U+FFFD.
- From Android 15 the device ends a read after 5 s without data and still exits `0`, so a read cut short looks complete.

## On an iOS simulator

Runs `simctl spawn <udid> log show --style ndjson --info --debug` once, bounded in time and filtered, and reads its output as it streams.

```
karagoz logs --package dev.karagoz.probe --lines 1
```

```json
{"device":"2EC769C1-2EF2-47EB-A441-E6843968F039","package":"dev.karagoz.probe","records":[{"time":1792054562.937849,"pid":43961,"tid":5236136,"level":"I","tag":"Probe","subsystem":"com.apple.Accessibility","category":"AXAppAccessibility","message":"Presentation controller doesn't modalize: <_UIRootPresentationController: 0x10536f350>"}],"omitted":297}
```

- `log show` has no record count, so the window is a time span: without `--since`, the last minute; with `--package`, the last hour. On an idle simulator a minute took under 1 s and an hour 8 s; a read that passes 30 s fails with `SIMCTL_TIMEOUT`.
- `--package` keeps the records of every process that runs the installed build of the app: the app and its extensions, with the lines of the frameworks they load, from this install and from earlier installs of the same build. It also keeps the `exited ...` line `launchd_sim` writes when such a process ends, the only trace of a crash by signal. Records of other builds of the app, other processes' lines about the app, and `print` and stderr output are not included. Two apps whose executables are byte for byte the same, such as two Flutter apps made from the template with the same plugins, are not told apart.
- `level`: Debug is `D`, Info and Default are `I`, Error is `E`, Fault is `F`, anything else `?`. `Logger.notice` and `NSLog` write Default.
- The simulator keeps Info records in memory only for a few minutes (gone after 213 s in testing) and does not store Debug records by default.
- `time` comes from the computer's clock. Pass the largest `time` of one result as the next `--since`: `log` takes whole seconds, and karagoz drops records at or before the exact value, so nothing comes back twice. Of two records in the same microsecond, the second can be lost.
- Each `log show` writes a record of its own run; karagoz leaves it out. The log is never cleared or reconfigured. There is no `uid`.
- Errors: `APP_NOT_FOUND` (`app 'dev.karagoz.nope' is not installed on <udid>`) before the read. `SIMCTL_FAILED` with `log`'s own error, such as `log: Bad predicate ...`, or for output that is not `log show`'s records: `unexpected log output: <line>`, `log show ended without its summary line`. `SIMCTL_TIMEOUT` after 30 s: `log show did not finish within 30s. Pass a later --since, or --package, to read less of the simulator log.`, without `, or --package,` when it was given. `DEVICE_NOT_READY` for a simulator that is not booted.

## On an iPhone

Reads a paired iPhone attached by USB cable, with no `sudo` and nothing installed on the Mac or the phone. karagoz takes this Mac's pairing record for the phone from usbmuxd (it stays in memory), opens a session with the phone over TLS, and asks the phone's log service for an archive of its records from a start time. `tar` unpacks it into a temporary folder, macOS's own `log show` reads it as on a simulator, and the folder is removed afterwards, also when the call is cancelled.

```
karagoz logs --package dev.karagoz.probe --since 1792446423
```

One record of that result, written by the test app with `Logger.notice` (the device id was `XXXXXXXX-XXXXXXXXXXXXXXXX`):

```json
{"time":1792446425.836977,"pid":6801,"tid":2186877,"level":"I","tag":"Probe","subsystem":"dev.karagoz.probe","category":"smoke","message":"hello-from-probe"}
```

- Every read moves about 230 MB from the phone before any record: the symbol files a log archive carries. Records from the start time on come on top: the last minute or hour took 8 to 10 s. A `--since` older than the phone's first record moves the whole log: 1.1 GB and 30 s for five weeks on the test phone. The temporary folder needs that much free space for the length of the call.
- Without `--since`: the last minute, or the last hour with `--package`. Older records are there: Default and above went back five weeks on the test phone, Info two weeks. The phone stores Info records, unlike a simulator, and some Debug records.
- `--package` keeps the records of the app's install folders that are proven to be this app: the folder it is installed in now, and any folder one of whose processes launchd started under the app's id in the archive read. A build changed since the last install always logs under its current folder. A build installed again unchanged logs under the folder of its first install and is proven once it starts or stops within the read. When nothing is proven, every folder with the app's folder name is kept, so another app with the same name, such as a second Flutter app's `Runner.app`, can mix in. The phone gives no way to read a build's identity, which a simulator does. Exit lines come from `launchd`.
- `<private>` stands where the app or the system marked a value private: the phone masks it before karagoz reads it, about 4 records in 10 on the test phone. karagoz does not change the phone's log settings.
- `time` is the phone's clock, 0.1 s behind the Mac on the test phone. Chain reads with the largest `time`, as on a simulator: 14 chained reads lost and repeated nothing.
- A locked phone reads the same. Two reads of one phone at once both work; the second took 14 s.
- Errors: `APP_NOT_FOUND` before the read. `DEVICE_NOT_READY` for a phone not connected by USB cable, one this Mac holds no pairing record for (unplug it, plug it in, tap Trust), or one that refuses the session. `HELPER_FAILED` when the phone's log service or the stream fails, nothing comes for 30 s, or `tar` or `log` fail, with their own message; `log show did not finish within 30 s. Pass a later --since, or --package, to read less of the iPhone log.`, without `, or --package,` when it was given. `WRITE_FAILED` when the temporary folder cannot be created.
