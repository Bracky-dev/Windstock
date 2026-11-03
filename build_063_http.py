"""
Build the http-login 0.63.4 iOS client from the decrypted stock IPA.

Same strategy as work/v035/build_ios_selfhost.py: the only gameplay-relevant
change is global-metadata.dat, where the 6 PTC login URLs are rewritten to
plain http:// on pgorelease (via 2017/patch_sso_http.py, metadata v22).
_CodeSignature/ is dropped -> UNSIGNED, sideload with SideStore / LiveContainer.

    python3 build_063_http.py <stock.ipa> <patched-metadata.dat> <out.ipa>
"""
import sys
import zipfile

src, meta, dst = sys.argv[1:4]
APP = "Payload/pokemongo.app/"
new_meta = open(meta, "rb").read()
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for it in zin.infolist():
        name = it.filename
        if name.startswith(APP + "_CodeSignature/"):
            continue
        data = new_meta if name == APP + "Data/Managed/Metadata/global-metadata.dat" else zin.read(name)
        zi = zipfile.ZipInfo(name, date_time=it.date_time)
        zi.external_attr = it.external_attr
        zi.compress_type = zipfile.ZIP_STORED if name.endswith("/") else zipfile.ZIP_DEFLATED
        zout.writestr(zi, data)
print("wrote", dst)
