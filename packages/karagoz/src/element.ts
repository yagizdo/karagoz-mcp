import { cancellation } from './cancellation.js';
import { KaragozError } from './errors.js';

export type Selector = { kind: 'text'; label: string } | { kind: 'id'; id: string };

// Invisible direction marks, Unicode's Bidi_Control set. One UI's Settings wraps Bluetooth and Wi-Fi Direct names in
// U+200E (Samsung Settings source), which nobody can type from the screen, so --text ignores them on both sides (K26).
export const BIDI = /\p{Bidi_Control}/gu;

// A matching node, the word the ambiguous list names it by, and its bounds.
export type Hit<N> = { node: N; name: string; box: number[] };

// Only "no match" reads again; a failed read, an ambiguous match or a covered center ends it. --timeout waits for the
// element to appear and never repeats the tap (K26, K11 note).
export async function findElement<T, N>(
  what: string,
  timeout: number,
  read: () => Promise<{ tree: T; hits: Hit<N>[]; where: string }>,
) {
  const start = performance.now();
  for (let reads = 1; ; reads++) {
    // Without it a cancelled wait keeps reading for its whole timeout (K31).
    cancellation.getStore()?.throwIfAborted();
    const { tree, hits, where } = await read();
    if (hits.length > 1) {
      const shown = hits.slice(0, 5).map(({ name, box }) => `${name} [${box.join(',')}]`);
      const more = hits.length > shown.length ? `, and ${hits.length - shown.length} more` : '';
      throw new KaragozError(
        'ELEMENT_AMBIGUOUS',
        `${hits.length} nodes match ${what}: ${shown.join(', ')}${more}; tap one by its coordinates`,
      );
    }
    const [hit] = hits;
    if (hit) {
      const [l = 0, t = 0, r = 0, b = 0] = hit.box;
      return { tree, hit, x: (l + r) / 2, y: (t + b) / 2 };
    }
    const elapsed = performance.now() - start;
    if (elapsed >= timeout) {
      throw new KaragozError(
        'ELEMENT_NOT_FOUND',
        `no node with ${what} in ${where} (${reads} read${reads === 1 ? '' : 's'} in ${(elapsed / 1000).toFixed(1)} s)`,
      );
    }
  }
}
