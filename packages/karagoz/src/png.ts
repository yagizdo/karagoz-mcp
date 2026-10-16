// PNG layout (https://www.w3.org/TR/png/): the 8-byte signature, then the IHDR chunk header (length 13, type IHDR)
// with width and height as big-endian uint32 at bytes 16 and 20, and the 12-byte IEND chunk last.
const SIGNATURE = Buffer.from('89504e470d0a1a0a', 'hex');
const IHDR = Buffer.from('0000000d49484452', 'hex');
const IEND = Buffer.from('0000000049454e44ae426082', 'hex');

// The size of a whole PNG, or null when the bytes are not one. Both capture tools exit 0 or print text in place of
// an image in some failures, so the bytes are the only reliable signal (K22).
export function pngSize(png: Buffer): { width: number; height: number } | null {
  const whole =
    png.subarray(0, 8).equals(SIGNATURE) && png.subarray(8, 16).equals(IHDR) && png.subarray(-12).equals(IEND);
  return whole ? { width: png.readUInt32BE(16), height: png.readUInt32BE(20) } : null;
}
