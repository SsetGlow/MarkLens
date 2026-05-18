#!/usr/bin/env python3
import os
import struct
import zlib


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def png(path, size):
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            nx = x / (size - 1)
            ny = y / (size - 1)
            radius = 0.22
            inside = (
                radius <= nx <= 1 - radius
                or radius <= ny <= 1 - radius
                or (nx - radius) ** 2 + (ny - radius) ** 2 <= radius ** 2
                or (nx - (1 - radius)) ** 2 + (ny - radius) ** 2 <= radius ** 2
                or (nx - radius) ** 2 + (ny - (1 - radius)) ** 2 <= radius ** 2
                or (nx - (1 - radius)) ** 2 + (ny - (1 - radius)) ** 2 <= radius ** 2
            )
            if not inside:
                row.extend((0, 0, 0, 0))
                continue

            r = g = b = 12
            a = 255
            if 0.22 < nx < 0.78 and 0.20 < ny < 0.80:
                r = g = b = 220
            if 0.27 < nx < 0.73 and 0.27 < ny < 0.73:
                r = g = b = 24
            if 0.30 < nx < 0.68 and 0.35 < ny < 0.66:
                if 0.30 < nx < 0.40 or abs(ny - (0.66 - (nx - 0.40) * 1.35)) < 0.035 or abs(ny - (0.35 + (nx - 0.54) * 1.45)) < 0.035:
                    r = g = b = 242
            if 0.58 < nx < 0.70 and abs(ny - (0.35 + (nx - 0.58) * 2.5)) < 0.04:
                r = g = b = 145
            if 0.58 < nx < 0.70 and abs(ny - (0.65 - (nx - 0.58) * 2.5)) < 0.04:
                r = g = b = 145
            row.extend((r, g, b, a))
        rows.append(bytes(row))

    raw = b"".join(rows)
    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw, 9))
    data += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(data)


def main():
    out = os.path.abspath("build/AppIcon.iconset")
    os.makedirs(out, exist_ok=True)
    specs = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for name, size in specs:
        png(os.path.join(out, name), size)


if __name__ == "__main__":
    main()
