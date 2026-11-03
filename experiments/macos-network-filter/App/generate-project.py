#!/usr/bin/env python3
"""Generate a dependency-free Xcode project under .build, never install anything."""
import hashlib
import os
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / ".build" / "xcode" / "GreywallNetworkExperiment.xcodeproj"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "dev.greywall.NetworkExperiment")
objects = {}


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(key_name, isa, **properties):
    key = identifier(key_name)
    objects[key] = dict(isa=isa, **properties)
    return key


def configurations(name, settings):
    entries = []
    for kind in ("Debug", "Release"):
        values = dict(settings)
        values["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if kind == "Debug" else "-O"
        entries.append(add(name + kind, "XCBuildConfiguration", name=kind, buildSettings=values))
    return add(name + "Configs", "XCConfigurationList", buildConfigurations=entries,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")


package = add("LocalPackage", "XCLocalSwiftPackageReference", relativePath=str(ROOT))
source_refs = []
products = []
common = dict(SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="15.0", SWIFT_VERSION="5.0",
              CODE_SIGN_STYLE="Automatic", CODE_SIGN_IDENTITY="Apple Development",
              DEVELOPMENT_TEAM="", ENABLE_HARDENED_RUNTIME="YES", GENERATE_INFOPLIST_FILE="NO",
              GREYWALL_BUNDLE_ID=BUNDLE_ID, ENABLE_USER_SCRIPT_SANDBOXING="YES",
              ALWAYS_SEARCH_USER_PATHS="NO", GREYWALL_NE_ENTITLEMENT="content-filter-provider")


def target(name, directory, product_name, product_type, wrapper, package_product, entitlements, bundle_id):
    sources = []
    for path in sorted((ROOT / "App" / directory).glob("*.swift")):
        source = add(name + "Source" + path.name, "PBXFileReference", lastKnownFileType="sourcecode.swift",
                     path=str(path), sourceTree="<absolute>")
        source_refs.append(source)
        sources.append(add(name + "SourceBuild" + path.name, "PBXBuildFile", fileRef=source))
    product = add(name + "Product", "PBXFileReference", explicitFileType=wrapper,
                  path=product_name, sourceTree="BUILT_PRODUCTS_DIR", includeInIndex=0)
    products.append(product)
    product_dependency = add(name + "PackageProduct", "XCSwiftPackageProductDependency",
                             package=package, productName=package_product)
    package_build = add(name + "PackageBuild", "PBXBuildFile", productRef=product_dependency)
    source_phase = add(name + "Sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                       files=sources, runOnlyForDeploymentPostprocessing=0)
    framework_phase = add(name + "Frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                          files=[package_build], runOnlyForDeploymentPostprocessing=0)
    settings = dict(common, PRODUCT_NAME=product_name.rsplit(".", 1)[0],
                    PRODUCT_BUNDLE_IDENTIFIER=bundle_id,
                    INFOPLIST_FILE=str(ROOT / "App" / directory / "Info.plist"),
                    CODE_SIGN_ENTITLEMENTS=str(ROOT / "App" / directory / entitlements),
                    PRODUCT_MODULE_NAME=name, SKIP_INSTALL="YES" if directory == "Extension" else "NO")
    key = add(name, "PBXNativeTarget", name=name, productName=name, productType=product_type,
              productReference=product, buildConfigurationList=configurations(name, settings),
              buildPhases=[source_phase, framework_phase], buildRules=[], dependencies=[],
              packageProductDependencies=[product_dependency])
    return key, product


extension, extension_product = target("FilterExtension", "Extension", BUNDLE_ID + ".filter.systemextension",
    "com.apple.product-type.system-extension", "wrapper.system-extension", "FilterPrototype",
    "Filter.entitlements", "$(GREYWALL_BUNDLE_ID).filter")
host, host_product = target("GreywallNetworkExperiment", "Host", "Greywall Network Experiment.app",
    "com.apple.product-type.application", "wrapper.application", "NativeControl",
    "Host.entitlements", "$(GREYWALL_BUNDLE_ID)")
proxy = add("ExtensionProxy", "PBXContainerItemProxy", containerPortal=identifier("Project"),
            proxyType=1, remoteGlobalIDString=extension, remoteInfo="FilterExtension")
dependency = add("ExtensionDependency", "PBXTargetDependency", target=extension, targetProxy=proxy)
embed_build = add("EmbedExtensionBuild", "PBXBuildFile", fileRef=extension_product,
                  settings={"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]})
embed_phase = add("EmbedExtensionPhase", "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
                  dstPath="$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions", dstSubfolderSpec=16,
                  files=[embed_build], name="Embed System Extension", runOnlyForDeploymentPostprocessing=0)
objects[host]["dependencies"] = [dependency]
objects[host]["buildPhases"].append(embed_phase)
product_group = add("Products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
main_group = add("MainGroup", "PBXGroup", children=source_refs + [product_group], sourceTree="<group>")
project = add("Project", "PBXProject", attributes={"LastUpgradeCheck": "1600", "TargetAttributes": {
    host: {"SystemCapabilities": {"com.apple.SystemExtension": {"enabled": 1},
                                 "com.apple.NetworkExtensions": {"enabled": 1}}},
    extension: {"SystemCapabilities": {"com.apple.NetworkExtensions": {"enabled": 1},
                                      "com.apple.Sandbox": {"enabled": 1}}},
}}, buildConfigurationList=configurations("Project", common), compatibilityVersion="Xcode 14.0",
    developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main_group,
    productRefGroup=product_group, projectDirPath="", projectRoot="", targets=[host, extension],
    packageReferences=[package])
PROJECT.mkdir(parents=True, exist_ok=True)
with (PROJECT / "project.pbxproj").open("wb") as file:
    plistlib.dump(dict(archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject=project), file)

scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
action = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
entries = ET.SubElement(action, "BuildActionEntries")
entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES",
                      buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
ET.SubElement(entry, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=host,
              BuildableName="Greywall Network Experiment.app", BlueprintName="GreywallNetworkExperiment",
              ReferencedContainer="container:GreywallNetworkExperiment.xcodeproj")
scheme_path = PROJECT / "xcshareddata" / "xcschemes" / "GreywallNetworkExperiment.xcscheme"
scheme_path.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(scheme).write(scheme_path, encoding="utf-8", xml_declaration=True)
print(PROJECT)
