#!/bin/zsh
set -euo pipefail

# Builds an isolated, ad-hoc QA app. It NEVER launches the GUI, uses production
# signing configuration, or writes into the production package/build directory.
case "${1:-}" in
  --help|-h)
    print -r -- "Usage: scripts/preview-experience.sh [--prepare-only]"
    print -r -- "Creates a fresh temporary QA app with fixture lyrics and synthetic spectrum."
    print -r -- "Default: build and ad-hoc sign only; no GUI launch. CONFIGURATION=debug|release."
    exit 0 ;;
  ""|--prepare-only) ;;
  *) print -u2 -r -- "Unknown option: $1"; exit 1 ;;
esac
[[ $# -le 1 ]] || { print -u2 -r -- "Too many arguments."; exit 1; }
alpaca_qa_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
alpaca_qa_configuration="${CONFIGURATION:-release}"
[[ "$alpaca_qa_configuration" == release || "$alpaca_qa_configuration" == debug ]] || {
  print -u2 -r -- "CONFIGURATION must be release or debug."; exit 1
}
[[ -f "$alpaca_qa_root/Sources/AlpacaMusic/AlpacaMusicApp.swift" && -f "$alpaca_qa_root/scripts/qa-experience.swift" ]] || {
  print -u2 -r -- "Production sources or QA entry are missing."; exit 1
}
alpaca_qa_workspace="$(mktemp -d "${TMPDIR:-/private/tmp}/AlpacaExperienceQA.XXXXXX")"
alpaca_qa_project="$alpaca_qa_workspace/project"
alpaca_qa_target="$alpaca_qa_project/Sources/AlpacaExperienceQA"
mkdir -p "$alpaca_qa_target" "$alpaca_qa_workspace/data"
/usr/bin/ditto "$alpaca_qa_root/Sources/AlpacaMusic" "$alpaca_qa_target"
# The only removed entry is inside the newly-created temporary copy.
rm -- "$alpaca_qa_target/AlpacaMusicApp.swift"
cp "$alpaca_qa_root/scripts/qa-experience.swift" "$alpaca_qa_target/ExperienceQAApp.swift"
cat > "$alpaca_qa_project/Package.swift" <<'SWIFT'
// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "AlpacaExperienceQA",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "AlpacaExperienceQA", targets: ["AlpacaExperienceQA"])],
    targets: [.executableTarget(name: "AlpacaExperienceQA", resources: [.copy("Resources"), .process("Localization")],
                               swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])],
    swiftLanguageModes: [.v6]
)
SWIFT
if [[ "${1:-}" == --prepare-only ]]; then
  print -r -- "Prepared isolated QA sources (not built or launched): $alpaca_qa_project"
  exit 0
fi
alpaca_qa_sdk="$(xcrun --sdk macosx --show-sdk-path)"
alpaca_qa_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
(( ${alpaca_qa_sdk_version%%.*} >= 27 )) || { print -u2 -r -- "macOS SDK 27 or newer is required."; exit 1; }
alpaca_qa_flags=(--package-path "$alpaca_qa_project" -c "$alpaca_qa_configuration" --sdk "$alpaca_qa_sdk"
  -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$alpaca_qa_sdk_version")
print -r -- "Building an isolated QA copy in $alpaca_qa_workspace"
swift build "${alpaca_qa_flags[@]}" --product AlpacaExperienceQA
alpaca_qa_binary_dir="$(swift build "${alpaca_qa_flags[@]}" --show-bin-path)"
alpaca_qa_app="$alpaca_qa_workspace/AlpacaMusic Experience QA.app"
mkdir -p "$alpaca_qa_app/Contents/MacOS" "$alpaca_qa_app/Contents/Resources"
cp "$alpaca_qa_binary_dir/AlpacaExperienceQA" "$alpaca_qa_app/Contents/MacOS/AlpacaExperienceQA"
/usr/bin/ditto "$alpaca_qa_binary_dir/AlpacaExperienceQA_AlpacaExperienceQA.bundle" \
  "$alpaca_qa_app/Contents/Resources/AlpacaExperienceQA_AlpacaExperienceQA.bundle"
xcrun python3 - "$alpaca_qa_app" "$alpaca_qa_workspace" <<'PY'
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
workspace = pathlib.Path(sys.argv[2])
info = {
    "CFBundleIdentifier": "dev.byalpaca.AlpacaMusicExperienceQA",
    "CFBundleName": "AlpacaMusic Experience QA",
    "CFBundleDisplayName": "AlpacaMusic Experience QA",
    "CFBundleExecutable": "AlpacaExperienceQA",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "26.0",
    "NSHighResolutionCapable": True,
    "AlpacaMusicMusicKitConfigured": False,
    "LSEnvironment": {
        "ALPACA_DATA_DIR": str(workspace / "data"),
        "ALPACA_PREFERENCES_DOMAIN": "dev.byalpaca.AlpacaMusicExperienceQA." + workspace.name,
        "ALPACA_EPHEMERAL_ACCOUNTS": "1",
    },
}
with (app / "Contents/Info.plist").open("wb") as output:
    plistlib.dump(info, output)
PY
/usr/bin/codesign --force --sign - --identifier dev.byalpaca.AlpacaMusicExperienceQA "$alpaca_qa_app"
/usr/bin/codesign --verify --strict "$alpaca_qa_app"
xcrun vtool -show-build "$alpaca_qa_app/Contents/MacOS/AlpacaExperienceQA"
print -r -- "QA app built and ad-hoc verified. It has NOT been launched."
print -r -- "$alpaca_qa_app"
