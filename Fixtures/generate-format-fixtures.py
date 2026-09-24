#!/usr/bin/env python3
"""Write tiny standalone preview fixtures to an explicitly chosen SFTP test folder."""
import argparse
import struct
import zlib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
folder = parser.parse_args().output
folder.mkdir(parents=True, exist_ok=True)


def chunk(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


# A 2 × 2 red/blue RGB PNG; ImageIO must decode it through the normal image reader.
pixels = b"\x00\xff\x00\x00\x00\x00\xff" * 2
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
(folder / "sample.png").write_bytes(png)

# A minimal one-page PDF with a visible title and valid byte offsets.
stream = b"BT /F1 24 Tf 60 740 Td (RemoteFiles PDF preview) Tj ET\n"
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream",
]
pdf = bytearray(b"%PDF-1.4\n")
offsets = [0]
for number, body in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf.extend(f"{number} 0 obj\n".encode() + body + b"\nendobj\n")
xref = len(pdf)
pdf.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
for offset in offsets[1:]:
    pdf.extend(f"{offset:010d} 00000 n \n".encode())
pdf.extend(f"trailer\n<< /Root 1 0 R /Size {len(offsets)} >>\nstartxref\n{xref}\n%%EOF\n".encode())
(folder / "sample.pdf").write_bytes(pdf)
(folder / "sample.csv").write_text("name,count\npreview,1\n", encoding="utf-8")
(folder / "sample.json").write_text('{"preview":"available"}\n', encoding="utf-8")
print(f"Generated PNG, PDF, CSV and JSON in {folder}")
