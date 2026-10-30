// How the compact pass reads and rebuilds one platform's nodes. build gets the node's kept children and its nearest
// kept ancestor (undefined for the root), so a driver can compare a field against what the kept tree inherits.
type Shape<T> = {
  bounds: (node: T) => number[];
  children: (node: T) => T[];
  keep: (node: T) => boolean;
  build: (node: T, children: T[], kept: T | undefined) => T;
};

// The compact tree (K54): a node with no area, one wholly outside the root's bounds, or one keep refuses is left out,
// and its children are judged in its place. The root always stays.
export function prune<T>(root: T, shape: Shape<T>): T {
  const [left = 0, top = 0, right = 0, bottom = 0] = shape.bounds(root);
  const shown = (node: T) => {
    const [l = 0, t = 0, r = 0, b = 0] = shape.bounds(node);
    return r > l && b > t && r > left && b > top && l < right && t < bottom;
  };
  // A kept node is the nearest kept ancestor of everything below it.
  const below = (node: T, kept: T): T[] => shape.children(node).flatMap((child) => walk(child, kept));
  const walk = (node: T, kept: T): T[] =>
    shown(node) && shape.keep(node) ? [shape.build(node, below(node, node), kept)] : below(node, kept);
  return shape.build(root, below(root, root), undefined);
}
