#!/usr/bin/env python3
"""
Add LC_LOAD_DYLIB commands to a thin arm64 Mach-O, in place.

The game-only IPA (make_game_ipa.sh) has no launcher to dlopen the windstock tweak,
so the game binary itself has to name its dylibs. Each command goes into the padding
between the last load command and the first section -- the 0.35 binary has ~19 KB
there (see patch_macho.py) -- so no offsets move.

    python3 tools/insert_dylib.py <binary> @executable_path/Frameworks/A.dylib [...]

A path that is already loaded is left alone, so running it twice is harmless.
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_CODE_SIGNATURE = 0x1D


def load_commands(data):
    magic, _cpu, _sub, _ft, ncmds, sizeofcmds, _flags, _res = struct.unpack_from("<8I", data, 0)
    if magic != MH_MAGIC_64:
        sys.exit("not a thin 64-bit Mach-O (lipo -thin arm64 first)")
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<2I", data, off)
        yield off, cmd, size
        off += size


def first_section_offset(data):
    lowest = None
    for off, cmd, _size in load_commands(data):
        if cmd != LC_SEGMENT_64:
            continue
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        for i in range(nsects):
            s = off + 72 + i * 80
            sect_off = struct.unpack_from("<I", data, s + 48)[0]
            if sect_off and (lowest is None or sect_off < lowest):
                lowest = sect_off
    return lowest


def loaded_paths(data):
    out = []
    for off, cmd, _size in load_commands(data):
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            end = data.index(b"\0", off + name_off)
            out.append(data[off + name_off:end].decode())
    return out


def insert(path, dylibs):
    data = bytearray(open(path, "rb").read())
    have = loaded_paths(data)
    for dylib in dylibs:
        if dylib in have:
            print(f"    already loads {dylib}")
            continue
        name = dylib.encode() + b"\0"
        size = (24 + len(name) + 7) & ~7
        cmd = struct.pack("<6I", LC_LOAD_DYLIB, size, 24, 2, 0x10000, 0x10000)
        cmd += name + b"\0" * (size - 24 - len(name))

        ncmds, sizeofcmds = struct.unpack_from("<2I", data, 16)
        end = 32 + sizeofcmds
        room = first_section_offset(data) - end
        if room < size:
            sys.exit(f"no room for {dylib}: {room} bytes free, {size} needed")
        if any(data[end:end + size]):
            sys.exit("the padding after the load commands is not empty -- refusing to overwrite")
        data[end:end + size] = cmd
        struct.pack_into("<2I", data, 16, ncmds + 1, sizeofcmds + size)
        print(f"    + LC_LOAD_DYLIB {dylib} ({room - size} bytes of padding left)")
    open(path, "wb").write(data)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    insert(sys.argv[1], sys.argv[2:])
