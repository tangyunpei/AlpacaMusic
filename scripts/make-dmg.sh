#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

# Builds a release AlpacaMusic and packages it as a DMG in build/release.XXXXXX/,
# Developer ID signed when signing.local.plist exists.
#
#   scripts/make-dmg.sh               build (bumps the version), then package
#   scripts/make-dmg.sh --skip-build  package the existing build/AlpacaMusic.app
#
# Environment:
#   ENABLE_MUSICKIT=1  build with Apple Music; with --skip-build, require it
#   NOTARY_PROFILE     notarytool keychain profile: notarize and staple the DMG
#
# SIGN_IDENTITY and TEAM_ID are ignored, so signing.local.plist decides the
# identity and an inherited override cannot change it.
fail() { print -u2 -r -- "make-dmg: $*"; exit 1; }

skip_build=0
for argument in "$@"; do
  case "$argument" in
    --skip-build) skip_build=1 ;;
    -h|--help) sed -n '5,16p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) fail "Unknown option: $argument (see --help)." ;;
  esac
done
musickit="${ENABLE_MUSICKIT:-0}"
[[ "$musickit" == 0 || "$musickit" == 1 ]] || fail "ENABLE_MUSICKIT must be 0 or 1."
notary_profile="${NOTARY_PROFILE:-}"
identity="" team=""
if [[ -f signing.local.plist ]]; then
  identity="$(/usr/libexec/PlistBuddy -c 'Print :SigningIdentity' signing.local.plist)" \
    || fail "Cannot read SigningIdentity in signing.local.plist."
  team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier' signing.local.plist)" \
    || fail "Cannot read TeamIdentifier in signing.local.plist."
fi
[[ -z "$notary_profile" || -n "$identity" ]] \
  || fail "NOTARY_PROFILE needs a Developer ID identity in signing.local.plist."

if (( ! skip_build )); then
  env -u SIGN_IDENTITY -u TEAM_ID CONFIGURATION=release ENABLE_MUSICKIT="$musickit" ./scripts/build-app.sh
fi

app="$PWD/build/AlpacaMusic.app"
info="$app/Contents/Info.plist"
[[ -d "$app" ]] || fail "No build/AlpacaMusic.app; run without --skip-build."
app_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$info" 2>/dev/null || true; }
/usr/bin/codesign --verify --strict "$app" || fail "build/AlpacaMusic.app has an invalid signature."
version="$(app_value CFBundleShortVersionString)"
[[ -n "$version" ]] || fail "Cannot read the app version."
if [[ "$(app_value AlpacaMusicMusicKitConfigured)" == true ]]; then
  [[ -z "$team" || "$(app_value AlpacaMusicMusicKitTeamIdentifier)" == "$team" ]] \
    || fail "The app's MusicKit team does not match TeamIdentifier in signing.local.plist."
  apple_music="configured"
else
  # A build without ENABLE_MUSICKIT=1 shows Apple Music as unconfigured.
  [[ "$musickit" == 0 ]] || fail "build/AlpacaMusic.app was built without ENABLE_MUSICKIT=1; run without --skip-build."
  apple_music="not configured (set ENABLE_MUSICKIT=1 for an Apple Music build)"
fi

release="$(mktemp -d "$PWD/build/release.XXXXXX")"
payload="$release/payload"
dmg="$release/AlpacaMusic-${version}-macOS-arm64.dmg"
mkdir "$payload"
ditto "$app" "$payload/AlpacaMusic.app"
ln -s /Applications "$payload/Applications"
cp LICENSE DISCLAIMER.md THIRD_PARTY_NOTICES.md "$payload/"
ditto LICENSES "$payload/LICENSES"
diskutil image create from --format UDZO --volumeName "AlpacaMusic" "$payload" "$dmg"

if [[ -n "$identity" ]]; then
  /usr/bin/codesign --sign "$identity" --timestamp --identifier "dev.byalpaca.music.dmg" "$dmg"
  /usr/bin/codesign --verify --strict "$dmg"
fi

if [[ -n "$notary_profile" ]]; then
  # `notarytool submit --wait` can exit 0 for a rejected submission, so read
  # the final status rather than trusting the exit code.
  print -r -- "Submitting to Apple notarization with profile $notary_profile…"
  result="$(xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait --output-format json)" \
    || fail "notarytool could not submit $dmg."
  submission="$(print -r -- "$result" | xcrun python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))')"
  notary_status="$(print -r -- "$result" | xcrun python3 -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))')"
  [[ "$notary_status" == Accepted ]] \
    || fail "Notarization ended as '$notary_status'. Details: xcrun notarytool log $submission --keychain-profile $notary_profile"
  print -r -- "Notarization accepted ($submission)."
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  /usr/bin/codesign --verify --strict "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  signing="Developer ID signed, notarized and stapled"
elif [[ -n "$identity" ]]; then
  signing="Developer ID signed, not notarized (set NOTARY_PROFILE to notarize)"
else
  signing="unsigned (no signing.local.plist)"
fi

shasum -a 256 "$dmg"
print -r -- "AlpacaMusic $version: $signing; Apple Music $apple_music."
print -r -- "$dmg"
