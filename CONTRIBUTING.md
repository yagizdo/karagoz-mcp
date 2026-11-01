# Contributing to karagoz

Bug reports, fixes and new commands are welcome. karagoz has one maintainer, so small, focused pull requests get merged fastest. This page says what to send and what a pull request needs; the rules for the code itself are in [AGENTS.md](https://github.com/yagizdo/karagoz-mcp/blob/main/AGENTS.md), which applies to people and agents alike.

## Reporting a bug

Open an issue with:

- the command you ran and the JSON line it printed;
- the target: Android emulator, Android phone, iOS simulator or iPhone, with the OS version;
- `karagoz --version` and the output of `karagoz doctor`.

Before you post, take out anything that identifies a real phone or its owner: serial numbers (also inside names like `adb-<serial>-<id>`), the device name you set, IMEI, MAC and IP addresses, accounts, and anything read off a phone's screen, such as screenshots, `ui-tree` output and logs. Replace each value with `XXXXXXXXXXX`. Model, brand and OS version are fine. You can post output from an emulator or a simulator as it is. The full rule is under "Device data" in [AGENTS.md](https://github.com/yagizdo/karagoz-mcp/blob/main/AGENTS.md#hard-boundaries).

## Before you write code

- Read [AGENTS.md](https://github.com/yagizdo/karagoz-mcp/blob/main/AGENTS.md). Its "Scope" rule decides most feature requests: karagoz has primitive verbs only, with no assertions, test runner, recorded flows or retries. For anything larger than a fix, open an issue first.
- Build and run karagoz from a clone as [docs/development.md](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/development.md) describes. AGENTS.md says where code goes, under "Code layout".

## Pull requests

- One change per pull request, with commits in [Conventional Commits](https://www.conventionalcommits.org/) form, as AGENTS.md describes under "Conventions".
- A change to what a command takes, prints or fails with also updates its page in `docs/commands/`. A new command gets its own page and a row in the README's command table.
- A new dependency must be MIT, ISC, BSD, Apache-2.0 or BlueOak licensed. When one is worth adding at all is under "Dependencies" in AGENTS.md.
- A bug fix comes with a smoke test step that fails before the fix and passes after. When a real device cannot produce the failure, a fake `adb` or fake Xcode tool can, as the existing smoke tests do.
- Leave the version fields alone. The maintainer bumps them when cutting a release and writes the release notes, which thank everyone whose pull request was merged.
- Run `npm run typecheck` and `npm run lint` from the repository root; both must pass.

CI runs on a pull request from a fork: on Linux, with Node 22 and 24, it runs the type check, lint, build and the four smoke tests that need no device. It never reaches a device, so run the smoke tests for the code you changed yourself, from `packages/karagoz/smoke/`. Android changes need a running emulator. Simulator changes need macOS and a booted simulator. Steps that need a phone print `SKIP` when none is connected, so no phone is required. In the pull request description, say what problem it solves, what changed, and which smoke tests you ran on which target type. [docs/development.md](https://github.com/yagizdo/karagoz-mcp/blob/main/docs/development.md) lists what each one needs.

## AI tools

Use them if they help. Read and understand every line before you submit it, because you are the one the review talks to. Keep AI out of the git metadata: no "Generated with Claude Code" style lines or session links in commits or pull request descriptions, and no `Co-Authored-By:` trailers naming an AI tool. GitHub turns those trailers into contributor credits, and that list is for people. You may say in the pull request description that you used an AI tool, but you don't have to. [AGENTS.md](https://github.com/yagizdo/karagoz-mcp/blob/main/AGENTS.md) carries the same rule in a form coding agents pick up on their own.

## License

karagoz is MIT licensed. By sending a pull request, you agree that your contribution is released under the same license.
