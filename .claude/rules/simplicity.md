---
paths:
  - "packages/karagoz/src/**/*.ts"
---

# Simplicity

karagoz grows one command at a time. Structure arrives when a second real case needs it, not before. Paths are relative to `packages/karagoz/src/`.

- No interface, abstract class or registry with one implementation. Three backends did not earn a driver interface either: the platform branch is one line per function and the call shapes differ (`AGENTS.md`, `## Code layout`).
- A class only when it holds state or extends a built-in (`KaragozError extends Error` in `errors.ts`). Otherwise export functions from the module. No class with only static members.
- No generic, overload, mapped or conditional type unless two call sites need it today. Some repetition costs less than a type someone has to decode.
- No parameter, flag or config value for something that never varies. The adb timeout is a constant, not a flag (K19: 10 s covers a measured 3.2 s cold server start; a call that needs longer, such as a gesture, passes its own value).
- No wrapper that only renames a Node API. Call `execFile`, `spawn`, `parseArgs` or `fetch` directly.
- A value whose meaning is not obvious gets a named constant in the module that uses it, with a comment on where the value comes from (`TIMEOUT_MS` in `drivers/android/adb.ts`). No shared constants file until two modules need the same value; a value two platforms need goes to a shared module (`AGENTS.md`, `## Code layout`).
- A shortcut with a known limit gets a `ponytail:` comment that names the limit and when to lift it (the one above `isEmulator` in `drivers/android/devices.ts`).
- When a change replaces a pattern, grep `src/` for the old one and change every site in the same commit.

## Comments

- A comment says why: a constraint, a measured number, a surprise, a decision number with its reason. What the code does, the code says.
- Most code needs no comment. Write one where a careful reader would still get it wrong: a platform quirk, a measured limit, a workaround, code that looks wrong but is right (the `hasOwn` line in `cli.ts`). A clearer name or a named constant comes first.
- One or two lines, above the function, constant or line it explains; no running commentary inside a body. The reason goes in the comment; measurements, alternatives and the debugging story go in the commit message or the maintainers' journal.
- A comment longer than the code it explains, or one that is hard to write, means the code needs work first.
- Update or delete a comment in the same change that makes it wrong.
