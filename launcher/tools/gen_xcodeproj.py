#!/usr/bin/env python3
"""
Generate WindstockLauncher.xcodeproj.

Written rather than committed because the project has to stay in step with
whatever the staging scripts produce, and because a generated pbxproj is a file
you can read a diff of. Run it again after adding a source file:

    python3 tools/gen_xcodeproj.py

Everything that is not a source file -- the guest app, the Python runtime, the
tweak -- is copied in by a single "Stage bundle payload" run-script phase from
Staging/, so adding 68 Python extension frameworks does not mean 68 more lines
in here.
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = "WindstockLauncher"
BUNDLE_ID = "com.windstock.launcher"
DEPLOYMENT_TARGET = "16.0"


def _signing():
    """Your Apple team (and optionally a bundle id), from signing.local next to
    this project -- or WS_TEAM / WS_BUNDLE_ID in the environment.

    This script rewrites project.pbxproj wholesale, so a team picked in
    Xcode's Signing & Capabilities tab is wiped on every regenerate. Keeping it
    in a file of its own is what makes it stick:

        TEAM=ABCDE12345
        BUNDLE_ID=com.yourname.windstock      # only if the default is taken
    """
    vals = {}
    path = os.path.join(ROOT, "signing.local")
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    vals[k.strip().upper()] = v.strip()
    except OSError:
        pass
    team = os.environ.get("WS_TEAM") or vals.get("TEAM", "")
    bundle = os.environ.get("WS_BUNDLE_ID") or vals.get("BUNDLE_ID", "")
    return team, bundle


def uid(*parts):
    """A stable 24-hex object id derived from what the object is."""
    digest = hashlib.sha1("::".join(parts).encode()).hexdigest()
    return digest[:24].upper()


SOURCES = {
    "Container": [
        "WindstockLauncher/Container/fishhook.c",
        "WindstockLauncher/Container/WSContainer.m",
        "WindstockLauncher/Container/WSPaths.m",
        "WindstockLauncher/Container/WSLog.m",
        "WindstockLauncher/Container/WSNetRedirect.m",
        "WindstockLauncher/Container/WSURLProtocol.m",
        "WindstockLauncher/Container/WSGuestLoader.m",
    ],
    "Server": [
        "WindstockLauncher/Server/WSPythonServer.m",
    ],
    "Signing": [
        "WindstockLauncher/Signing/DER.swift",
        "WindstockLauncher/Signing/DERReader.swift",
        "WindstockLauncher/Signing/PKCS12.swift",
        "WindstockLauncher/Signing/CMS.swift",
        "WindstockLauncher/Signing/CertificateInfo.swift",
        "WindstockLauncher/Signing/CertificateChain.swift",
        "WindstockLauncher/Signing/SigningIdentity.swift",
        "WindstockLauncher/Signing/IdentityStore.swift",
        "WindstockLauncher/Signing/HostSignature.swift",
        "WindstockLauncher/Signing/MachOSigner.swift",
        "WindstockLauncher/Signing/MachOPatcher.swift",
        "WindstockLauncher/Signing/Zip.swift",
        "WindstockLauncher/Signing/AppLibrary.swift",
        "WindstockLauncher/Signing/LoadTest.swift",
    ],
    "App": [
        "WindstockLauncher/App/AppDelegate.swift",
        "WindstockLauncher/App/SceneDelegate.swift",
        "WindstockLauncher/App/Logging.swift",
        "WindstockLauncher/App/LauncherPrefs.swift",
        "WindstockLauncher/App/LauncherModel.swift",
        "WindstockLauncher/App/ModsCatalog.swift",
        "WindstockLauncher/App/ModsConfig.swift",
        "WindstockLauncher/App/Notifier.swift",
        "WindstockLauncher/App/Theme.swift",
        "WindstockLauncher/App/RootView.swift",
        "WindstockLauncher/App/PlayView.swift",
        "WindstockLauncher/App/ModsView.swift",
        "WindstockLauncher/App/ServerView.swift",
        "WindstockLauncher/App/SettingsView.swift",
        "WindstockLauncher/App/GameEditorView.swift",
        "WindstockLauncher/App/WorldPacks.swift",
        "WindstockLauncher/App/WorldDataView.swift",
        "WindstockLauncher/App/OSMLinksView.swift",
        "WindstockLauncher/App/OSMImport.swift",
        "WindstockLauncher/App/WindstockProfile.swift",
        "WindstockLauncher/App/ProfileSection.swift",
        "WindstockLauncher/App/LogExport.swift",
        "WindstockLauncher/App/GameSettings.swift",
        "WindstockLauncher/App/GameSettingsView.swift",
        "WindstockLauncher/App/TutorialView.swift",
        "WindstockLauncher/App/AppsSection.swift",
        "WindstockLauncher/App/SigningView.swift",
        "WindstockLauncher/App/CustomDylibs.swift",
    ],
    "Support": [
        "WindstockLauncher/Support/main.m",
    ],
}

HEADERS = [
    "WindstockLauncher/Container/fishhook.h",
    "WindstockLauncher/Container/WSContainer.h",
    "WindstockLauncher/Container/WSPaths.h",
    "WindstockLauncher/Container/WSLog.h",
    "WindstockLauncher/Container/WSNetRedirect.h",
    "WindstockLauncher/Container/WSURLProtocol.h",
    "WindstockLauncher/Container/WSGuestLoader.h",
    "WindstockLauncher/Server/WSPythonServer.h",
    "WindstockLauncher/Support/WindstockLauncher-Bridging-Header.h",
]

RESOURCES = [
    "WindstockLauncher/Resources/LaunchScreen.storyboard",
    "WindstockLauncher/Resources/Assets.xcassets",
    # Apple's WWDR intermediate. Signatures have to carry it or the device
    # cannot chain a development certificate to a trusted root.
    "WindstockLauncher/Resources/AppleWWDRCAG3.cer",
]

XCFRAMEWORK = "Vendor/Python.xcframework"

STAGE_SCRIPT = r'''set -e
"$SRCROOT/tools/stage_payload.sh"
'''

FILE_TYPES = {
    ".c": "sourcecode.c.c",
    ".m": "sourcecode.c.objc",
    ".mm": "sourcecode.cpp.objcpp",
    ".swift": "sourcecode.swift",
    ".h": "sourcecode.c.h",
    ".plist": "text.plist.xml",
    ".storyboard": "file.storyboard",
    ".xcassets": "folder.assetcatalog",
    ".xcframework": "wrapper.xcframework",
    ".entitlements": "text.plist.entitlements",
}


def file_type(path):
    return FILE_TYPES.get(os.path.splitext(path)[1], "text")


def main():
    lines = []
    out = lines.append

    # ---- object ids
    def fref(path):
        return uid("fileref", path)

    def bfile(path, phase):
        return uid("buildfile", phase, path)

    all_sources = [p for group in SOURCES.values() for p in group]
    all_files = all_sources + HEADERS + RESOURCES + [
        XCFRAMEWORK,
        "WindstockLauncher/Support/Info.plist",
        "WindstockLauncher/Support/WindstockLauncher.entitlements",
    ]

    ids = {
        "project": uid("project"),
        "target": uid("target"),
        "product": uid("product"),
        "mainGroup": uid("group", "main"),
        "productsGroup": uid("group", "Products"),
        "sources": uid("phase", "sources"),
        "frameworks": uid("phase", "frameworks"),
        "resources": uid("phase", "resources"),
        "embed": uid("phase", "embed"),
        "stage": uid("phase", "stage"),
        "projectConfigList": uid("configlist", "project"),
        "targetConfigList": uid("configlist", "target"),
    }

    out("// !$*UTF8*$!")
    out("{")
    out("\tarchiveVersion = 1;")
    out("\tclasses = {")
    out("\t};")
    out("\tobjectVersion = 56;")
    out("\tobjects = {")

    # ---- PBXBuildFile
    out("\n/* Begin PBXBuildFile section */")
    for path in all_sources:
        out("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
            % (bfile(path, "sources"), os.path.basename(path), fref(path), os.path.basename(path)))
    for path in RESOURCES:
        out("\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
            % (bfile(path, "resources"), os.path.basename(path), fref(path), os.path.basename(path)))
    out("\t\t%s /* Python.xcframework in Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* Python.xcframework */; };"
        % (bfile(XCFRAMEWORK, "frameworks"), fref(XCFRAMEWORK)))
    out("\t\t%s /* Python.xcframework in Embed Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* Python.xcframework */; "
        "settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };"
        % (bfile(XCFRAMEWORK, "embed"), fref(XCFRAMEWORK)))
    out("/* End PBXBuildFile section */")

    # ---- PBXFileReference
    out("\n/* Begin PBXFileReference section */")
    for path in all_files:
        out('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; name = "%s"; path = "%s"; sourceTree = "<group>"; };'
            % (fref(path), os.path.basename(path), file_type(path),
               os.path.basename(path), path))
    out('\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; '
        'includeInIndex = 0; path = "%s.app"; sourceTree = BUILT_PRODUCTS_DIR; };'
        % (ids["product"], PROJECT, PROJECT))
    out("/* End PBXFileReference section */")

    # ---- groups
    out("\n/* Begin PBXGroup section */")
    group_ids = {}
    for name in list(SOURCES) + ["Resources", "Vendor"]:
        group_ids[name] = uid("group", name)

    def group(gid, name, children):
        out("\t\t%s /* %s */ = {" % (gid, name))
        out("\t\t\tisa = PBXGroup;")
        out("\t\t\tchildren = (")
        for child_id, label in children:
            out("\t\t\t\t%s /* %s */," % (child_id, label))
        out("\t\t\t);")
        out('\t\t\tname = "%s";' % name)
        out("\t\t\tsourceTree = \"<group>\";")
        out("\t\t};")

    for name, paths in SOURCES.items():
        children = [(fref(p), os.path.basename(p)) for p in paths]
        children += [(fref(h), os.path.basename(h)) for h in HEADERS
                     if h.startswith("WindstockLauncher/%s/" % name)]
        if name == "Support":
            children.append((fref("WindstockLauncher/Support/Info.plist"), "Info.plist"))
            children.append((fref("WindstockLauncher/Support/WindstockLauncher.entitlements"),
                             "WindstockLauncher.entitlements"))
        group(group_ids[name], name, children)

    group(group_ids["Resources"], "Resources",
          [(fref(p), os.path.basename(p)) for p in RESOURCES])
    group(group_ids["Vendor"], "Vendor", [(fref(XCFRAMEWORK), "Python.xcframework")])
    group(ids["productsGroup"], "Products", [(ids["product"], PROJECT + ".app")])
    group(ids["mainGroup"], PROJECT,
          [(group_ids[n], n) for n in list(SOURCES) + ["Resources", "Vendor"]]
          + [(ids["productsGroup"], "Products")])
    out("/* End PBXGroup section */")

    # ---- native target
    out("\n/* Begin PBXNativeTarget section */")
    out("\t\t%s /* %s */ = {" % (ids["target"], PROJECT))
    out("\t\t\tisa = PBXNativeTarget;")
    out("\t\t\tbuildConfigurationList = %s;" % ids["targetConfigList"])
    out("\t\t\tbuildPhases = (")
    for key, label in [("sources", "Sources"), ("frameworks", "Frameworks"),
                       ("resources", "Resources"), ("embed", "Embed Frameworks"),
                       ("stage", "Stage bundle payload")]:
        out("\t\t\t\t%s /* %s */," % (ids[key], label))
    out("\t\t\t);")
    out("\t\t\tbuildRules = (")
    out("\t\t\t);")
    out("\t\t\tdependencies = (")
    out("\t\t\t);")
    out('\t\t\tname = "%s";' % PROJECT)
    out('\t\t\tproductName = "%s";' % PROJECT)
    out("\t\t\tproductReference = %s;" % ids["product"])
    out('\t\t\tproductType = "com.apple.product-type.application";')
    out("\t\t};")
    out("/* End PBXNativeTarget section */")

    # ---- project
    out("\n/* Begin PBXProject section */")
    out("\t\t%s /* Project object */ = {" % ids["project"])
    out("\t\t\tisa = PBXProject;")
    out("\t\t\tattributes = {")
    out("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    out("\t\t\t\tLastUpgradeCheck = 2700;")
    out("\t\t\t\tTargetAttributes = {")
    out("\t\t\t\t\t%s = {CreatedOnToolsVersion = 27.0; };" % ids["target"])
    out("\t\t\t\t};")
    out("\t\t\t};")
    out("\t\t\tbuildConfigurationList = %s;" % ids["projectConfigList"])
    out('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    out("\t\t\tdevelopmentRegion = en;")
    out("\t\t\thasScannedForEncodings = 0;")
    out("\t\t\tknownRegions = (en, Base, );")
    out("\t\t\tmainGroup = %s;" % ids["mainGroup"])
    out("\t\t\tproductRefGroup = %s;" % ids["productsGroup"])
    out('\t\t\tprojectDirPath = "";')
    out('\t\t\tprojectRoot = "";')
    out("\t\t\ttargets = (%s, );" % ids["target"])
    out("\t\t};")
    out("/* End PBXProject section */")

    # ---- phases
    out("\n/* Begin PBXSourcesBuildPhase section */")
    out("\t\t%s /* Sources */ = {" % ids["sources"])
    out("\t\t\tisa = PBXSourcesBuildPhase;")
    out("\t\t\tbuildActionMask = 2147483647;")
    out("\t\t\tfiles = (")
    for path in all_sources:
        out("\t\t\t\t%s /* %s in Sources */," % (bfile(path, "sources"), os.path.basename(path)))
    out("\t\t\t);")
    out("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out("\t\t};")
    out("/* End PBXSourcesBuildPhase section */")

    out("\n/* Begin PBXFrameworksBuildPhase section */")
    out("\t\t%s /* Frameworks */ = {" % ids["frameworks"])
    out("\t\t\tisa = PBXFrameworksBuildPhase;")
    out("\t\t\tbuildActionMask = 2147483647;")
    out("\t\t\tfiles = (")
    out("\t\t\t\t%s /* Python.xcframework in Frameworks */," % bfile(XCFRAMEWORK, "frameworks"))
    out("\t\t\t);")
    out("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out("\t\t};")
    out("/* End PBXFrameworksBuildPhase section */")

    out("\n/* Begin PBXResourcesBuildPhase section */")
    out("\t\t%s /* Resources */ = {" % ids["resources"])
    out("\t\t\tisa = PBXResourcesBuildPhase;")
    out("\t\t\tbuildActionMask = 2147483647;")
    out("\t\t\tfiles = (")
    for path in RESOURCES:
        out("\t\t\t\t%s /* %s in Resources */," % (bfile(path, "resources"), os.path.basename(path)))
    out("\t\t\t);")
    out("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out("\t\t};")
    out("/* End PBXResourcesBuildPhase section */")

    out("\n/* Begin PBXCopyFilesBuildPhase section */")
    out("\t\t%s /* Embed Frameworks */ = {" % ids["embed"])
    out("\t\t\tisa = PBXCopyFilesBuildPhase;")
    out("\t\t\tbuildActionMask = 2147483647;")
    out('\t\t\tdstPath = "";')
    out("\t\t\tdstSubfolderSpec = 10;")
    out("\t\t\tfiles = (")
    out("\t\t\t\t%s /* Python.xcframework in Embed Frameworks */," % bfile(XCFRAMEWORK, "embed"))
    out("\t\t\t);")
    out('\t\t\tname = "Embed Frameworks";')
    out("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out("\t\t};")
    out("/* End PBXCopyFilesBuildPhase section */")

    out("\n/* Begin PBXShellScriptBuildPhase section */")
    out("\t\t%s /* Stage bundle payload */ = {" % ids["stage"])
    out("\t\t\tisa = PBXShellScriptBuildPhase;")
    out("\t\t\talwaysOutOfDate = 1;")
    out("\t\t\tbuildActionMask = 2147483647;")
    out("\t\t\tfiles = (")
    out("\t\t\t);")
    out("\t\t\tinputPaths = (")
    out("\t\t\t);")
    out('\t\t\tname = "Stage bundle payload";')
    out("\t\t\toutputPaths = (")
    out("\t\t\t);")
    out("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out('\t\t\tshellPath = "/bin/sh";')
    out('\t\t\tshellScript = "%s";' % STAGE_SCRIPT.replace('"', '\\"').replace("\n", "\\n"))
    out("\t\t};")
    out("/* End PBXShellScriptBuildPhase section */")

    # ---- build configurations
    base_debug = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": '("DEBUG=1", "$(inherited)", )',
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    }
    base_release = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
        "VALIDATE_PRODUCT": "YES",
    }
    shared = {
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "iphoneos",
        "TARGETED_DEVICE_FAMILY": '"1"',
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "NO",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "NO",
        "SWIFT_VERSION": "5.0",
    }
    for key, value in shared.items():
        base_debug[key] = value
        base_release[key] = value

    target_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_ENTITLEMENTS": '"WindstockLauncher/Support/WindstockLauncher.entitlements"',
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "FRAMEWORK_SEARCH_PATHS": '("$(inherited)", "$(PROJECT_DIR)/Vendor", )',
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": '"WindstockLauncher/Support/Info.plist"',
        "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks", )',
        "MARKETING_VERSION": "1.4",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_OBJC_BRIDGING_HEADER":
            '"WindstockLauncher/Support/WindstockLauncher-Bridging-Header.h"',
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        # The container loads a Mach-O out of the bundle by hand; nothing here
        # should be stripped or reordered on the way in.
        "STRIP_INSTALLED_PRODUCT": "NO",
        "ENABLE_BITCODE": "NO",
        "OTHER_LDFLAGS": '("$(inherited)", )',
    }
    team, bundle = _signing()
    if team:
        target_common["DEVELOPMENT_TEAM"] = team
    if bundle:
        target_common["PRODUCT_BUNDLE_IDENTIFIER"] = bundle

    def config(cfg_id, name, settings):
        out("\t\t%s /* %s */ = {" % (cfg_id, name))
        out("\t\t\tisa = XCBuildConfiguration;")
        out("\t\t\tbuildSettings = {")
        for key in sorted(settings):
            out("\t\t\t\t%s = %s;" % (key, settings[key]))
        out("\t\t\t};")
        out('\t\t\tname = "%s";' % name)
        out("\t\t};")

    out("\n/* Begin XCBuildConfiguration section */")
    config(uid("config", "project", "Debug"), "Debug", base_debug)
    config(uid("config", "project", "Release"), "Release", base_release)
    config(uid("config", "target", "Debug"), "Debug", target_common)
    config(uid("config", "target", "Release"), "Release", target_common)
    out("/* End XCBuildConfiguration section */")

    out("\n/* Begin XCConfigurationList section */")
    for scope, list_id in (("project", ids["projectConfigList"]),
                           ("target", ids["targetConfigList"])):
        out("\t\t%s = {" % list_id)
        out("\t\t\tisa = XCConfigurationList;")
        out("\t\t\tbuildConfigurations = (")
        out("\t\t\t\t%s /* Debug */," % uid("config", scope, "Debug"))
        out("\t\t\t\t%s /* Release */," % uid("config", scope, "Release"))
        out("\t\t\t);")
        out("\t\t\tdefaultConfigurationIsVisible = 0;")
        out("\t\t\tdefaultConfigurationName = Release;")
        out("\t\t};")
    out("/* End XCConfigurationList section */")

    out("\t};")
    out("\trootObject = %s /* Project object */;" % ids["project"])
    out("}")

    proj_dir = os.path.join(ROOT, PROJECT + ".xcodeproj")
    os.makedirs(proj_dir, exist_ok=True)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as fh:
        fh.write("\n".join(lines) + "\n")

    scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    with open(os.path.join(scheme_dir, PROJECT + ".xcscheme"), "w") as fh:
        fh.write(SCHEME % {"target": ids["target"], "project": PROJECT,
                           "blueprint": PROJECT})

    print("wrote", os.path.relpath(proj_dir, ROOT))
    return 0


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%(target)s" BuildableName="%(project)s.app" BlueprintName="%(blueprint)s" ReferencedContainer="container:%(project)s.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%(target)s" BuildableName="%(project)s.app" BlueprintName="%(blueprint)s" ReferencedContainer="container:%(project)s.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%(target)s" BuildableName="%(project)s.app" BlueprintName="%(blueprint)s" ReferencedContainer="container:%(project)s.xcodeproj"/>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
"""


if __name__ == "__main__":
    sys.exit(main())
