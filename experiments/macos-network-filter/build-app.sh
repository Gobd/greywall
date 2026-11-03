#!/bin/bash
# Build only: no installation, activation, sudo, routes or network-settings writes.
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "This experiment builds/runs on Apple Silicon macOS only (no Intel or Rosetta build)." >&2
    exit 1
fi
mode=signed
provision=false
for argument in "$@"; do
    case "$argument" in
        --unsigned) mode=unsigned ;;
        --provision) provision=true ;;
        --help|-h)
            echo "Compile only: bash build-app.sh --unsigned"
            echo "Signed: DEVELOPMENT_TEAM=YOUR_TEAM BUNDLE_ID=YOUR_UNIQUE_ID bash build-app.sh"
            echo "Add --provision to explicitly allow Xcode to register app IDs/download provisioning profiles."
            echo "Build does not install or activate the app/extension."
            exit 0 ;;
        *) echo "Unknown option: $argument" >&2; exit 1 ;;
    esac
done
if [ "$mode" = unsigned ] && [ "$provision" = true ]; then
    echo "--provision cannot be combined with --unsigned" >&2; exit 1
fi
if [ "$mode" = signed ]; then
    : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}"
    : "${BUNDLE_ID:?Set BUNDLE_ID to a unique reverse-DNS app identifier you own}"
fi
mkdir -p .build/tmp .build/cache .build/module-cache
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
python3 App/generate-project.py
options=(-project "$PWD/.build/xcode/GreywallNetworkExperiment.xcodeproj"
    -scheme GreywallNetworkExperiment -configuration Debug
    -destination "platform=macOS,arch=arm64" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
    -derivedDataPath "$PWD/.build/app" -clonedSourcePackagesDirPath "$PWD/.build/packages"
    -disableAutomaticPackageResolution -skipPackageUpdates)
if [ "$mode" = unsigned ]; then
    options+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
else
    options+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" "GREYWALL_BUNDLE_ID=$BUNDLE_ID")
    if [ "$provision" = true ]; then options+=(-allowProvisioningUpdates); fi
fi
xcodebuild "${options[@]}" build
app="$PWD/.build/app/Build/Products/Debug/Greywall Network Experiment.app"
if [ "$(lipo -archs "$app/Contents/MacOS/Greywall Network Experiment")" != arm64 ]; then
    echo "Unexpected app architecture; refusing to report a successful ARM-only build." >&2; exit 1
fi
extension=$(find "$app/Contents/Library/SystemExtensions" -maxdepth 1 -name '*.systemextension' -type d)
if [ -z "$extension" ]; then echo "Embedded extension missing" >&2; exit 1; fi
extension_executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$extension/Contents/Info.plist")
if [ "$(lipo -archs "$extension/Contents/MacOS/$extension_executable")" != arm64 ]; then
    echo "Unexpected extension architecture; refusing to report a successful ARM-only build." >&2; exit 1
fi
if [ "$mode" = signed ]; then
    codesign --verify --deep --strict --verbose=2 "$app"
    echo "Signed app built and signature verified. OS activation/provisioning validation is still required."
else
    echo "UNSIGNED app: compile check only; it cannot be used for live extension testing."
fi
printf '\nBuild output: %s\n' "$app"
echo "Nothing was installed or activated. See App/README.md for deliberate next steps."
