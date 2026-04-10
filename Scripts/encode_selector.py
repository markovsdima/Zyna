#!/usr/bin/env python3
"""Encode a selector string into a masked byte array for DynamicAction."""

import sys

def encode(selector: str, mask: int = 0xA7) -> list[int]:
    return [b ^ mask for b in selector.encode("ascii")]

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <selector> [mask_hex]")
        sys.exit(1)

    sel = sys.argv[1]
    mask = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0xA7

    encoded = encode(sel, mask)
    swift = ", ".join(f"0x{b:02X}" for b in encoded)
    print(f"[{swift}]")
