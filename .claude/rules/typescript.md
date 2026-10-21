---
paths:
  - "packages/karagoz/src/**/*.ts"
---

# TypeScript

`npm run typecheck` and `npm run lint` catch the mechanical mistakes: `any`, unchecked `as` and `!`, floating promises, a `switch` that misses a union member, throwing a non-Error. When one reports, fix the cause. The rules below cover what the tools cannot see. Paths are relative to `packages/karagoz/src/`.

- Data from outside the process (tool stdout, `JSON.parse`, env vars, argv) is parsed and narrowed in one function, where it enters. Code past that function trusts the types and does not re-check them. `entries()` in `drivers/android/devices.ts` parses `adb devices` once; `devices.ts` uses its result.
- States that exclude each other are a discriminated union, not optional fields or boolean flags that can combine into a state that cannot happen. The target `resolveTarget()` in `devices.ts` returns is the pattern: `platform: 'android'`, or `platform: 'ios'` with `kind`.
- String literal unions, not `enum` or `namespace`. `ErrorCode` in `errors.ts` is the pattern.
- A failure the caller must tell apart is a `KaragozError` with a code from the closed `ErrorCode` set (K5: callers branch on `error.code`, never on the message). A failure nobody needs to tell apart surfaces as `INTERNAL` and gets no code of its own.
- A caught value is `unknown`. Narrow it with `instanceof` and `in` before reading `message` or `code`: anything can be thrown, and the K5 envelope needs a `message`. `envelope()` in `commands.ts` and the catch in `adbBytes()` in `drivers/android/adb.ts` are the pattern.
- A `catch` rethrows, or drops the error with a comment that says why losing it is safe. The write-back in `typeText()` in `drivers/ios/input.ts` is the pattern.
- A `catch` that drops errors rethrows a cancelled call's abort first, as `adbBytes()` does with `signal?.aborted`. A swallowed abort keeps a cancelled call running (K31: the MCP client can cancel a call).
- Never add `@ts-expect-error`, `oxlint-disable` or `prettier-ignore` without asking first. If one is approved, the comment above it says why it is needed and what would let it go.
