// A double tap's two touches, the same on every target. Android's GestureDetector takes the second press only within
// 300 ms of the first press and 40-300 ms after the first lift (API 37); the second press here starts at 150 ms.
// XCTest's own double tap also holds each touch 50 ms (Xcode 27.1).
export const DOUBLE_TAP_HOLD_MS = 50;
export const DOUBLE_TAP_GAP_MS = 100;
