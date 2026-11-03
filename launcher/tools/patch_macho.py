#!/usr/bin/env python3
"""
Turn the game's main executable into a dylib the launcher can dlopen.

dyld refuses to dlopen an MH_EXECUTE, and it will not map a 4 GB __PAGEZERO
into a live address space either. So: flip the filetype, and neutralise
__PAGEZERO by zeroing its addresses and sizes.

What it deliberately does NOT do is delete the __PAGEZERO load command. That
was the first attempt, overwriting it in place with LC_ID_DYLIB since the two
are the same size, and it produces a binary that dyld rejects with

    REBASE_OPCODE_DO_REBASE_ULEB_TIMES segment offset 0x000B0000
    beyond segment '__LINKEDIT' size (0x000B0000)

because LC_DYLD_INFO's rebase and bind opcodes name segments by ordinal.
Dropping the first segment shifts every later one down by one, so every fixup
lands in the wrong place. The segment has to stay in the list; it just has to
stop asking for 4 GB.

LC_ID_DYLIB is appended after the last load command instead, into the padding
that sits between the load commands and the first section.

The entry point is untouched -- LC_MAIN keeps pointing at the same file offset,
which is what WSGuestLoader calls once the image is in.

    python3 tools/patch_macho.py <in> <out> [--install-name NAME]
"""
import argparse
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
MH_EXECUTE = 0x2
MH_DYLIB = 0x6
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_MAIN = 0x80000028
LC_ENCRYPTION_INFO_64 = 0x2C


def patch(data: bytearray, install_name: str) -> str:
    magic, = struct.unpack_from("<I", data, 0)
    if magic == FAT_MAGIC or magic == 0xBEBAFECA:
        raise SystemExit("fat binary: thin it first with `lipo -thin arm64`")
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a 64-bit little-endian Mach-O (magic {magic:#x})")

    cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags = struct.unpack_from(
        "<iiIIII", data, 4)
    notes = []
    if filetype == MH_DYLIB:
        notes.append("already a dylib")
    elif filetype != MH_EXECUTE:
        raise SystemExit(f"unexpected filetype {filetype:#x}")

    offset = 32
    pagezero = None
    has_main = False
    has_id = False
    encrypted = False
    first_section = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == LC_SEGMENT_64:
            segname = data[offset + 8:offset + 24].split(b"\0")[0].decode()
            if segname == "__PAGEZERO":
                pagezero = offset
            nsects, = struct.unpack_from("<I", data, offset + 64)
            section = offset + 72
            for _ in range(nsects):
                sect_offset, = struct.unpack_from("<I", data, section + 48)
                if sect_offset and (first_section is None or sect_offset < first_section):
                    first_section = sect_offset
                section += 80
        elif cmd == LC_ID_DYLIB:
            has_id = True
        elif cmd == LC_MAIN:
            has_main = True
        elif cmd == LC_ENCRYPTION_INFO_64:
            cryptid, = struct.unpack_from("<I", data, offset + 20)
            encrypted = cryptid != 0
        offset += cmdsize

    if not has_main:
        notes.append("WARNING: no LC_MAIN -- the loader will not find an entry point")
    if encrypted:
        notes.append("WARNING: LC_ENCRYPTION_INFO cryptid is set -- this binary is "
                     "still FairPlay-encrypted and cannot be loaded. Use a decrypted IPA.")

    # --- header: executable -> dylib
    struct.pack_into("<I", data, 12, MH_DYLIB)

    # --- __PAGEZERO: keep the command, drop the 4 GB reservation
    if pagezero is not None:
        struct.pack_into("<QQQQ", data, pagezero + 24, 0, 0, 0, 0)   # vmaddr/vmsize/fileoff/filesize
        struct.pack_into("<ii", data, pagezero + 56, 0, 0)           # maxprot/initprot
        notes.append("__PAGEZERO neutralised (ordinals preserved)")
    else:
        notes.append("no __PAGEZERO")

    # --- append LC_ID_DYLIB into the header padding
    if has_id:
        notes.append("already had LC_ID_DYLIB")
    else:
        name = install_name.encode() + b"\0"
        cmdsize = (24 + len(name) + 7) & ~7
        end = 32 + sizeofcmds
        room = (first_section or 0) - end
        if room < cmdsize:
            notes.append(f"WARNING: no room for LC_ID_DYLIB ({room} bytes free)")
        else:
            blob = bytearray(cmdsize)
            struct.pack_into("<IIIIII", blob, 0,
                             LC_ID_DYLIB, cmdsize, 24, 1, 0x10000, 0x10000)
            blob[24:24 + len(name)] = name
            data[end:end + cmdsize] = blob
            struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
            notes.append(f"LC_ID_DYLIB appended ({install_name})")

    return "; ".join(notes)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("dest")
    parser.add_argument("--install-name",
                        default="@rpath/pokemongo.framework/pokemongo")
    args = parser.parse_args()

    with open(args.source, "rb") as fh:
        data = bytearray(fh.read())
    notes = patch(data, args.install_name)
    with open(args.dest, "wb") as fh:
        fh.write(data)
    print(f"patched {args.dest}: {notes}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
