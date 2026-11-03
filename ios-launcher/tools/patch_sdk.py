#!/usr/bin/env python3
"""
Raise the SDK version a Mach-O claims it was built with.

iOS decides per app whether to run it in a compatibility layout (letterboxed,
scaled) or to give it the whole screen by looking at the SDK the main binary
was linked against. On the iPhone Duo the cut-off is the 27.1 SDK, so an app
that was not rebuilt for it gets the compatibility treatment even though it
has no trouble with the larger screen. Bumping the number in LC_BUILD_VERSION
(or the older LC_VERSION_MIN_IPHONEOS) is enough; nothing else in the binary
changes.

    python3 tools/patch_sdk.py <macho> [--sdk 27.1]

Edits in place, handles thin and fat files, never lowers an SDK.
"""
import argparse
import struct
import sys

LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
MAGICS = {0xFEEDFACF: 4, 0xFEEDFACE: 0}  # thin little-endian: bytes past the 28-byte header


def enc(v: str) -> int:
    p = [int(x) for x in v.split(".")] + [0, 0]
    return (p[0] << 16) | (p[1] << 8) | p[2]


def dec(x: int) -> str:
    return f"{x >> 16}.{(x >> 8) & 255}.{x & 255}"


def patch_thin(data, base, sdk):
    magic, = struct.unpack_from("<I", data, base)
    if magic not in MAGICS:
        return None
    ncmds, = struct.unpack_from("<I", data, base + 16)
    off = base + 28 + MAGICS[magic]
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_BUILD_VERSION:
            plat, minos, cur = struct.unpack_from("<III", data, off + 8)
            if plat == PLATFORM_IOS:
                if cur < sdk:
                    struct.pack_into("<I", data, off + 16, sdk)
                return f"build_version sdk {dec(cur)} -> {dec(max(cur, sdk))}"
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            minos, cur = struct.unpack_from("<II", data, off + 8)
            if cur < sdk:
                struct.pack_into("<I", data, off + 12, sdk)
            return f"version_min sdk {dec(cur)} -> {dec(max(cur, sdk))}"
        off += size
    return "no iOS version command"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--sdk", default="27.1")
    a = ap.parse_args()
    sdk = enc(a.sdk)
    data = bytearray(open(a.file, "rb").read())
    magic_be, = struct.unpack_from(">I", data, 0)
    results = []
    if magic_be == 0xCAFEBABE:
        n, = struct.unpack_from(">I", data, 4)
        for i in range(n):
            _, _, off, _, _ = struct.unpack_from(">5I", data, 8 + 20 * i)
            results.append(patch_thin(data, off, sdk))
    else:
        results.append(patch_thin(data, 0, sdk))
    if not any(results) or results == [None]:
        sys.exit(f"{a.file}: not a Mach-O")
    open(a.file, "wb").write(data)
    print(f"{a.file}: " + "; ".join(r for r in results if r))


if __name__ == "__main__":
    main()
