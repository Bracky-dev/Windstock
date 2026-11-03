"""
Build the self-host 0.63.4 iOS client from the decrypted stock IPA.

  1. global-metadata.dat -- the 6 PTC login URLs -> plain http:// on pgorelease
     (patch_sso_http.py, metadata v22).
  2. pokemongo (optional) -- the pin-patched binary (pin/patch_pin_063.py) so the
     RPC TLS accepts our private-CA cert. RPC host is left as pgorelease; the
     phone's DNS redirect points it at the server.
  3. _CodeSignature/ dropped -> UNSIGNED, sideload with SideStore / LiveContainer.

    python3 build_063_http.py <stock.ipa> <patched-metadata.dat> <out.ipa> [patched-binary]
"""
import sys
import zipfile

src, meta, dst = sys.argv[1:4]
binary = sys.argv[4] if len(sys.argv) > 4 else None
APP = "Payload/pokemongo.app/"
replace = {APP + "Data/Managed/Metadata/global-metadata.dat": open(meta, "rb").read()}
if binary:
    replace[APP + "pokemongo"] = open(binary, "rb").read()
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for it in zin.infolist():
        name = it.filename
        if name.startswith(APP + "_CodeSignature/"):
            continue
        data = replace.get(name) or zin.read(name)
        zi = zipfile.ZipInfo(name, date_time=it.date_time)
        zi.external_attr = it.external_attr
        zi.compress_type = zipfile.ZIP_STORED if name.endswith("/") else zipfile.ZIP_DEFLATED
        zout.writestr(zi, data)
print("wrote", dst, "(binary: " + ("pin-patched" if binary else "stock") + ")")
