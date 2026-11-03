"""
Rewrite the 0.71 client's PTC login URLs to plain http:// on a given host.

Port of work/v035/patch_sso_http.py to il2cpp global-metadata **version 22**
(0.71.0). The only format change from v21 (0.35) is the version int in the
header; the string-literal table (litOff, count*8 of <uint32 len, int32 dataIdx>)
and the data blob live in exactly the same header slots, so the repoint trick is
unchanged:

  append the new string at EOF, then rewrite the literal's (length, dataIndex)
  to point past the declared data section. il2cpp loads the whole file and does
  NOT bounds-check dataIndex, so a longer replacement string is fine.

Why this may be needed on 0.71, same as 0.35: if the client's Mono/Unity HTTP
stack refuses every TLS certificate we can serve for sso.pokemon.com, the login
never reaches our server ("unable to authenticate", nothing in the log). Dropping
the SSO hop to http:// on a host that DOES resolve to us (pgorelease.nianticlabs.com)
routes it through server.py's /sso handler. The hop is plaintext, so keep it on a
trusted LAN / tailnet.

Usage:
    py patch_sso_http.py --scan  <in.dat>              # list candidate URLs, no write
    py patch_sso_http.py <in.dat> <out.dat> [host]     # rewrite (host default below)
"""
import struct
import sys

DEFAULT_HOST = "pgorelease.nianticlabs.com"
# hostnames whose URLs we redirect to DEFAULT_HOST over http
SSO_HOSTS = (b"sso.pokemon.com", b"pgorelease.nianticlabs.com", b"bracky.playit.plus")


def load(path):
    d = bytearray(open(path, "rb").read())
    sanity, version = struct.unpack_from("<II", d, 0)
    assert sanity == 0xFAB11BAF, f"bad magic {hex(sanity)}"
    assert version in (21, 22), f"unexpected metadata version {version}"
    lit_off, lit_size, sld_off, sld_size = struct.unpack_from("<iiii", d, 8)
    return d, version, lit_off, lit_size, sld_off, sld_size


def iter_literals(d, lit_off, lit_size, sld_off, sld_size):
    for i in range(lit_size // 8):
        ln, di = struct.unpack_from("<Ii", d, lit_off + i * 8)
        if ln <= 0 or di < 0 or di + ln > sld_size:
            continue
        s = bytes(d[sld_off + di: sld_off + di + ln])
        yield i, ln, di, s


def rewrite(s, host_bytes):
    new = s
    for host in SSO_HOSTS:
        new = new.replace(b"https://" + host, b"http://" + host_bytes)
        new = new.replace(b"http://" + host, b"http://" + host_bytes)
        new = new.replace(b"https%3A%2F%2F" + host, b"http%3A%2F%2F" + host_bytes)
        new = new.replace(b"http%3A%2F%2F" + host, b"http%3A%2F%2F" + host_bytes)
    return new


def main():
    args = sys.argv[1:]
    scan = False
    if args and args[0] == "--scan":
        scan = True
        args = args[1:]
    src = args[0]
    d, version, lit_off, lit_size, sld_off, sld_size = load(src)
    print(f"metadata v{version}: {lit_size // 8} literals, data section {sld_size} bytes")

    if scan:
        n = 0
        for i, ln, di, s in iter_literals(d, lit_off, lit_size, sld_off, sld_size):
            if b"/sso/" in s and s.startswith(b"http"):
                print(f"  [{i}] len={ln} {s.decode(errors='replace')}")
                n += 1
        print(f"\n{n} SSO URL literal(s) found (scan only, nothing written)")
        return

    dst = args[1]
    host = (args[2] if len(args) > 2 else DEFAULT_HOST)
    host_bytes = host.encode()
    patched = 0
    for i, ln, di, s in iter_literals(d, lit_off, lit_size, sld_off, sld_size):
        if b"/sso/" not in s or not s.startswith(b"http"):
            continue
        new = rewrite(s, host_bytes)
        if new == s:
            continue
        new_di = len(d) - sld_off
        d += new
        struct.pack_into("<Ii", d, lit_off + i * 8, len(new), new_di)
        print(f"  [{i}] {s[:74].decode(errors='replace')}")
        print(f"     -> {new[:74].decode(errors='replace')}")
        patched += 1
    assert patched, "no SSO URLs rewritten -- wrong file?"
    open(dst, "wb").write(bytes(d))
    print(f"\npatched {patched} URL(s); wrote {dst} ({len(d)} bytes)")


if __name__ == "__main__":
    main()
