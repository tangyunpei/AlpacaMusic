#!/bin/zsh
# Runs every check before a pull request, on this Mac: build script tests,
# translations, the full Swift suite, compiler-extracted translations and the
# SDK API audit. GitHub only runs the quick build script tests on pull
# requests; the macOS checks run here (or by hand with the CI workflow's
# "Run workflow" button). Requires Swift 6.4+ and the macOS 27 SDK.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { print -P "\n%B==> $1%b" }

step "Toolchain"
swift_version="$(xcrun swift --version 2>&1 | head -1)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
print -r -- "$swift_version"
print -r -- "macOS SDK $sdk_version"
[[ "$swift_version" =~ 'Swift version ([0-9]+)\.([0-9]+)' ]] || { print -u2 "Cannot read the Swift version."; exit 1 }
(( match[1] > 6 || (match[1] == 6 && match[2] >= 4) )) || { print -u2 "Swift 6.4 or newer is required."; exit 1 }
(( ${sdk_version%%.*} >= 27 )) || { print -u2 "The macOS 27 SDK or newer is required."; exit 1 }

step "Build script tests"
python3 -m unittest discover -s scripts/tests -p 'test_*.py'

step "Translations"
python3 scripts/check-localizations.py

step "Swift tests: audio analysis"
swift test --filter 'AudioAnalyzerTests|AudioWaveformTests' -Xswiftc -emit-localized-strings

step "Swift tests: everything else"
swift test --skip 'AudioAnalyzerTests|AudioWaveformTests' -Xswiftc -emit-localized-strings

step "Compiler-extracted translations"
# Read this debug build's extracted strings, not stale ones a release build left in .build.
extracted=".build/out/Intermediates.noindex/AlpacaMusic.build/Debug"
[[ -d "$extracted" ]] || extracted=".build"
python3 scripts/check-localizations.py --extracted-dir "$extracted"

step "SDK API audit"
./scripts/check-sdk-apis.sh

print -P "\n%BAll checks passed.%b"
