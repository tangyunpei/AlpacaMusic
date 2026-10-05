#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

# Deprecations introduced above the shipping deployment target need a separate audit.
alpaca_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
alpaca_sdk_major="${alpaca_sdk_version%%.*}"
if (( alpaca_sdk_major < 27 )); then
  echo "API audit requires macOS SDK 27 or newer." >&2
  exit 1
fi
alpaca_audit_dir="$(mktemp -d "${TMPDIR:-/tmp}/alpacamusic-api-audit.XXXXXX")"
trap 'rm -rf "$alpaca_audit_dir"' EXIT
sed "s/\.macOS(\"26.0\")/\.macOS(\"$alpaca_sdk_major.0\")/" Package.swift > "$alpaca_audit_dir/Package.swift"
cp -R Sources Tests "$alpaca_audit_dir/"
swift build --package-path "$alpaca_audit_dir"
echo "SDK $alpaca_sdk_version API audit passed; shipping deployment target is unchanged."
