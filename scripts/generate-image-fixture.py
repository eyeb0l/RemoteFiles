#!/usr/bin/env python3
"""Create disposable SFTP image acceptance files without allocating a giant pixel buffer."""
from pathlib import Path
import struct
import zlib

root = Path(__file__).resolve().parents[1] / '.test-server' / 'remote-images'
(root / 'images').mkdir(parents=True, exist_ok=True)

def chunk(out, kind, data):
    out.write(struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff))

def png(path, width, height, compression):
    with path.open('wb') as out:
        out.write(b'\x89PNG\r\n\x1a\n')
        chunk(out, b'IHDR', struct.pack('!IIBBBBB', width, height, 8, 2, 0, 0, 0))
        compressor = zlib.compressobj(compression)
        row = b'\x00' + bytes([42, 125, 190]) * width
        for _ in range(height):
            data = compressor.compress(row)
            if data:
                chunk(out, b'IDAT', data)
        chunk(out, b'IDAT', compressor.flush())
        chunk(out, b'IEND', b'')

png(root / 'large-70mb.png', 7000, 3500, 0)
png(root / 'images' / 'small.png', 600, 400, 6)
(root / 'images.md').write_text('# Remote image acceptance\n\n![Nested](./images/small.png)\n\n![Duplicate](images/small.png)\n\n![Missing](missing.png)\n\n![Large](large-70mb.png)\n\n![Blocked](../../private.png)\n')
print(root)
print('Large image bytes:', (root / 'large-70mb.png').stat().st_size)
