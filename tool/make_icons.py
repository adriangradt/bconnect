#!/usr/bin/env python3
"""Draws the BedrockBridge pixel icon (grass block with relay arrows) and
writes every Android and iOS launcher size. Pure stdlib, no Pillow."""
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

G = [(0x5d, 0x9c, 0x3c), (0x4a, 0x84, 0x2e), (0x6f, 0xb2, 0x47)]   # grass
D = [(0x86, 0x5b, 0x3a), (0x6e, 0x48, 0x2c), (0x97, 0x6a, 0x47)]   # dirt
W = (0xff, 0xff, 0xff)
S = (0x2b, 0x2b, 0x2b)  # arrow shadow

# 16x16 grid: g = grass, d = dirt, digits pick a shade.
GRID = [
    "0102010201020102",
    "2010120102101201",
    "0121010210120101",
    "1010201012010210",
    "d1d0d1d2d0d1d0d1",
    "dddddddddddddddd",
    "dddddddddddddddd",
    "dddddddddddddddd",
    "dddddddddddddddd",
    "dddddddddddddddd",
    "dddddddddddddddd",
    "dddddddddddddddd",
    "dddddddddddddddd",
    "dddddddddddddddd",
    "dddddddddddddddd",
    "dddddddddddddddd",
]
# Arrows: right arrow on rows 6-7, left arrow on rows 11-12, 3 px heads.
ARROWS = {}
for c in range(2, 11):
    ARROWS[(6, c)] = ARROWS[(7, c)] = W
for c, (r0, r1) in {10: (4, 9), 11: (5, 8), 12: (6, 7)}.items():
    for r in range(r0, r1 + 1):
        ARROWS[(r, c)] = W
for c in range(5, 14):
    ARROWS[(11, c)] = ARROWS[(12, c)] = W
for c, (r0, r1) in {5: (9, 14), 4: (10, 13), 3: (11, 12)}.items():
    for r in range(r0, r1 + 1):
        ARROWS[(r, c)] = W


def pixel(r, c):
    if (r, c) in ARROWS:
        return ARROWS[(r, c)]
    # one-pixel drop shadow below and right of the arrows
    if (r - 1, c - 1) in ARROWS:
        return S
    ch = GRID[r][c]
    if ch == "d":
        # deterministic speckle
        return D[(r * 7 + c * 13) % 5 % 3]
    return G[int(ch)]


def png(size):
    rows = []
    for y in range(size):
        r = y * 16 // size
        row = bytearray([0])
        for x in range(size):
            row += bytes(pixel(r, x * 16 // size))
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", raw) + chunk(b"IEND", b"")


def main():
    for d, s in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        (ROOT / f"android/app/src/main/res/mipmap-{d}/ic_launcher.png").write_bytes(png(s))
    ios = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for f in ios.glob("Icon-App-*.png"):
        dims = f.stem.removeprefix("Icon-App-")          # e.g. 83.5x83.5@2x
        base, scale = dims.split("@")
        size = round(float(base.split("x")[0]) * int(scale.rstrip("x")))
        f.write_bytes(png(size))
    (ROOT / "deploy/site/icon.png").write_bytes(png(512))


if __name__ == "__main__":
    main()
