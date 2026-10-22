# Development

How to build karagoz and run its checks and smoke scripts.

```sh
npm run build       # empty packages/karagoz/dist/, then bundle to dist/cli.js and two chunks
npm run typecheck
npm run lint        # oxlint and the Prettier check; npm run format fixes formatting
```

The repository is an npm workspace. `packages/karagoz` is the CLI and the MCP server, with its smoke scripts in `packages/karagoz/smoke/`; it is the package that gets published. `packages/ios-runner` is the iPhone runner's Xcode project (one Swift file); it is not published on its own: the build copies it into `packages/karagoz/dist/ios-runner/`, and `install-runner` builds it on the user's Mac. Run the npm scripts from the repository root.

Each step has one smoke script in `packages/karagoz/smoke/`, and each builds first. `M-mcp.sh`, `2.1-devices-physical.sh` and the `1.x` smokes other than `1.7` need a running emulator. `0b-version.sh`, `1.7-doctor.sh` and `S-package.sh` need no device. The `2.2` to `2.6` phone smokes need a phone only for their phone step, which they skip when none is listed. The `3.x` simulator and `4.x` iPhone smokes are macOS only (they print `SKIP` elsewhere) and need no emulator: they use fake tools, and a step that drives a booted simulator or a paired iPhone prints `SKIP` when none is there. The header of each script lists its preconditions:

```sh
sh packages/karagoz/smoke/1.4-input.sh
```

`packages/karagoz/smoke/1.5-app-lifecycle.sh` also builds a test APK on every run, and `packages/karagoz/smoke/2.5-app-lifecycle-physical.sh` when a phone is attached, with `packages/karagoz/smoke/fixtures/app-lifecycle/build.sh` from the manifest in that folder, and installs and removes it as `dev.karagoz.smoke`. No APK is kept in the repository. They need a JDK (`java` and `keytool` on `PATH`) and, from the Android SDK, build-tools with `aapt2` and `apksigner` plus one platform. The SDK is the first of `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, `~/Library/Android/sdk` and `~/Android/Sdk` that has both `build-tools/` and `platforms/`. When something is missing the smoke fails and says what, rather than skipping.

The full check, with the emulator running:

```sh
npm run typecheck && npm run lint && for s in packages/karagoz/smoke/*.sh; do sh "$s" || exit 1; done
```
