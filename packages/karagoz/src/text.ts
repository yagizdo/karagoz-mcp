import { KaragozError } from './errors.js';

// Only what no target types: control characters (C0, DEL, C1) other than newline and tab, and unpaired surrogates,
// which have no UTF-8 form (an iOS simulator types U+FFFD for one and reports success). where names the target.
export function typable(value: string, where: string): void {
  // for…of walks code points: an emoji is one U+ value, and an unpaired surrogate comes out alone.
  const control = new Set<string>();
  const lone = new Set<string>();
  for (const char of value) {
    if (/^\p{Cc}$/u.test(char) && char !== '\n' && char !== '\t') control.add(char);
    else if (/^\p{Cs}$/u.test(char)) lone.add(char);
  }
  const named = (chars: Set<string>) =>
    Array.from(chars, (char) => `'U+${(char.codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, '0')}'`).join(
      ', ',
    );
  if (control.size)
    throw new KaragozError(
      'TEXT_UNSUPPORTED',
      `cannot type ${named(control)} on ${where}: control characters other than newline and tab; nothing was typed`,
    );
  if (lone.size)
    throw new KaragozError(
      'TEXT_UNSUPPORTED',
      `cannot type ${named(lone)} on ${where}: an unpaired surrogate; nothing was typed`,
    );
}
