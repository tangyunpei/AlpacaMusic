#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
fail() { print -u2 -r -- "AlpacaMusic: $*"; exit 1; }
alpaca_identity="${SIGN_IDENTITY:--}"
alpaca_team="${TEAM_ID:-}"
# Keep this Mac's explicitly configured signing identity across rebuilds. Never
# source this file as shell code or silently fall back after a configuration error.
# An explicit SIGN_IDENTITY overrides the local identity/team as a pair.
if [[ -z "${SIGN_IDENTITY+x}" && -f signing.local.plist ]]; then
  [[ -z "$alpaca_team" ]] || fail "Set SIGN_IDENTITY with TEAM_ID, or use signing.local.plist without either override."
  alpaca_identity="$(/usr/libexec/PlistBuddy -c 'Print :SigningIdentity' signing.local.plist)" || fail "Cannot read SigningIdentity in signing.local.plist."
  alpaca_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier' signing.local.plist)" || fail "Cannot read TeamIdentifier in signing.local.plist."
  [[ ${#alpaca_identity} == 40 && "$alpaca_identity" != *[^[:xdigit:]]* ]] || fail "Local SigningIdentity must be a 40-character certificate fingerprint."
  [[ ${#alpaca_team} == 10 && "$alpaca_team" != *[^A-Z0-9]* ]] || fail "Local TeamIdentifier must be a 10-character Apple developer team identifier."
fi
alpaca_profile="${PROVISIONING_PROFILE:-}"
alpaca_musickit="${ENABLE_MUSICKIT:-0}"
alpaca_sandbox="${SANDBOX:-0}"
[[ "$configuration" == release || "$configuration" == debug ]] || fail "CONFIGURATION must be release or debug."
[[ "$alpaca_musickit" == 0 || "$alpaca_musickit" == 1 ]] || fail "ENABLE_MUSICKIT must be 0 or 1."
[[ "$alpaca_sandbox" == 0 || "$alpaca_sandbox" == 1 ]] || fail "SANDBOX must be 0 or 1."
if [[ "$alpaca_identity" == - ]]; then
  [[ "$alpaca_musickit" == 0 ]] || fail "ENABLE_MUSICKIT=1 requires SIGN_IDENTITY and TEAM_ID."
  [[ -z "$alpaca_profile" && -z "$alpaca_team" ]] || fail "A team or provisioning profile requires SIGN_IDENTITY."
else
  [[ -n "$alpaca_team" ]] || fail "Developer signing requires TEAM_ID for verification."
fi
[[ -z "$alpaca_profile" || -f "$alpaca_profile" ]] || fail "PROVISIONING_PROFILE must name an existing macOS profile."
alpaca_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
alpaca_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if (( ${alpaca_sdk_version%%.*} < 27 )); then
  echo "AlpacaMusic requires macOS SDK 27 or newer to build." >&2
  exit 1
fi
# Always assemble a fresh bundle, so an earlier configured build cannot leak its
# profile, entitlements, or MusicKit flag into a later ad-hoc build.
mkdir -p "$PWD/build"
# A kernel-owned lock survives neither normal exit nor a crashed shell; never
# delete the lock file, which would let another process lock a different inode.
zmodload zsh/system
: >> "$PWD/build/.build-app.lock"
zsystem flock -t 0 -f alpaca_lock_fd "$PWD/build/.build-app.lock" || fail "Another app build is running. Try again after it finishes."
for alpaca_pending in "$PWD"/build/.AlpacaMusic.*/install-in-progress(N); do
  fail "An interrupted publication needs recovery; its app and source backups are preserved at ${alpaca_pending:h}."
done
alpaca_staging="$(mktemp -d "$PWD/build/.AlpacaMusic.XXXXXX")"
alpaca_cleanup() {
  if [[ -e "$alpaca_staging/install-in-progress" ]]; then
    print -u2 -r -- "AlpacaMusic: Preserving interrupted publication and backups at $alpaca_staging"
  else
    rm -rf -- "$alpaca_staging"
  fi
}
trap alpaca_cleanup EXIT
alpaca_app="$alpaca_staging/AlpacaMusic.app"
mkdir -p "$alpaca_app/Contents/MacOS" "$alpaca_app/Contents/Resources"
xcrun python3 scripts/build-version.py prepare "$PWD" "$alpaca_staging" "$configuration"
if [[ -n "$alpaca_profile" ]]; then
  # Read only the explicitly supplied profile; never search account/keychain data.
  /usr/bin/security cms -D -i "$alpaca_profile" -o "$alpaca_staging/profile.plist"
  cp "$alpaca_profile" "$alpaca_app/Contents/embedded.provisionprofile"
fi

# These are metadata checks. macOS remains the authority for profile trust and
# device eligibility; portal service enablement is not a MusicKit entitlement.
xcrun python3 - "$alpaca_staging" "$alpaca_team" "${BUNDLE_ID:-}" "$alpaca_musickit" "$alpaca_sandbox" <<'PY'
import datetime
import hashlib
import pathlib
import plistlib
import re
import sys

stage = pathlib.Path(sys.argv[1])
team, override, music, sandbox = sys.argv[2:]
def fail(message):
    raise SystemExit("AlpacaMusic: " + message)
if team and not re.fullmatch(r"[A-Z0-9]{10}", team):
    fail("TEAM_ID must be the 10-character Apple developer team identifier.")
info_path = stage / "AlpacaMusic.app/Contents/Info.plist"
with info_path.open("rb") as source:
    info = plistlib.load(source)
bundle = override or info["CFBundleIdentifier"]
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
    fail("BUNDLE_ID must be an explicit reverse-DNS identifier without wildcards.")
info["CFBundleIdentifier"] = bundle
info["AlpacaMusicMusicKitConfigured"] = music == "1"
info["AlpacaMusicMusicKitTeamIdentifier"] = team if music == "1" else ""
if not str(info.get("NSAppleMusicUsageDescription", "")).strip():
    fail("NSAppleMusicUsageDescription is missing.")
entitlements = {}
if sandbox == "1":
    with open("AlpacaMusic.entitlements", "rb") as source:
        entitlements = plistlib.load(source)
if "com.apple.developer.musickit" in entitlements:
    fail("MusicKit is an App ID service, not a code-signing entitlement.")
profile_path = stage / "profile.plist"
if profile_path.exists():
    with profile_path.open("rb") as source:
        profile = plistlib.load(source)
    platforms = profile.get("Platform", [])
    if not isinstance(platforms, list) or not any(p in ("OSX", "macOS") for p in platforms):
        fail("The provisioning profile is not for macOS.")
    now = datetime.datetime.now(datetime.timezone.utc)
    for key, is_valid in (("CreationDate", lambda date: date <= now),
                          ("ExpirationDate", lambda date: date > now)):
        date = profile.get(key)
        if not isinstance(date, datetime.datetime) or not is_valid(date.replace(tzinfo=datetime.timezone.utc)):
            fail("The provisioning profile has an invalid " + key + ".")
    if team not in profile.get("TeamIdentifier", []):
        fail("The provisioning profile does not belong to TEAM_ID.")
    allowed = profile.get("Entitlements", {})
    app_id = allowed.get("com.apple.application-identifier", "")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if not prefixes or app_id not in [prefix + "." + bundle for prefix in prefixes] or "*" in app_id:
        fail("The profile must authorize this exact macOS App ID (prefix + BUNDLE_ID).")
    profile_team = allowed.get("com.apple.developer.team-identifier")
    if profile_team is not None and profile_team != team:
        fail("The profile team entitlement does not match TEAM_ID.")
    certificates = profile.get("DeveloperCertificates", [])
    if not certificates or not all(isinstance(cert, bytes) and cert for cert in certificates):
        fail("The profile has no usable signing-certificate allowlist.")
    (stage / "allowed-certificates.txt").write_text(
        "\n".join(hashlib.sha256(cert).hexdigest() for cert in certificates) + "\n")
    # Claim only the exact identity values authorized by the supplied profile,
    # not all its optional entitlements or a fabricated MusicKit entitlement.
    entitlements["com.apple.application-identifier"] = app_id
    if profile_team is not None:
        entitlements["com.apple.developer.team-identifier"] = profile_team
with info_path.open("wb") as output:
    plistlib.dump(info, output, sort_keys=False)
with (stage / "signing.entitlements").open("wb") as output:
    plistlib.dump(entitlements, output)
(stage / "bundle-id.txt").write_text(bundle)
PY
alpaca_bundle_id="$(cat "$alpaca_staging/bundle-id.txt")"

# Swift 6.4's SwiftBuild path can stamp sdk=deployment despite compiling with SDK 27.
# Supply the actual SDK version to the linker; do not rewrite a signed Mach-O later.
alpaca_build_flags=(-c "$configuration" --sdk "$alpaca_sdk_path"
  -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$alpaca_sdk_version")
swift build "${alpaca_build_flags[@]}"
binary_dir="$(swift build "${alpaca_build_flags[@]}" --show-bin-path)"
alpaca_build_info="$(xcrun vtool -show-build "$binary_dir/AlpacaMusic")"
if ! print -r -- "$alpaca_build_info" | awk -v sdk="$alpaca_sdk_version" '
  $1 == "minos" && $2 == "26.0" { minimumOK = 1 }
  $1 == "sdk" && $2 == sdk { sdkOK = 1 }
  END { exit !(minimumOK && sdkOK) }
'; then
  echo "Build version check failed: expected minimum 26.0 / SDK $alpaca_sdk_version." >&2
  exit 1
fi
cp "$binary_dir/AlpacaMusic" "$alpaca_app/Contents/MacOS/AlpacaMusic"
ditto "$binary_dir/AlpacaMusic_AlpacaMusic.bundle" "$alpaca_app/Contents/Resources/AlpacaMusic_AlpacaMusic.bundle"
swift scripts/make-icon.swift "$alpaca_staging" "$PWD/Resources/Brand/AppIcon-Bauhaus.png"
iconutil -c icns "$alpaca_staging/AppIcon.iconset" -o "$alpaca_app/Contents/Resources/AppIcon.icns"
alpaca_sign_flags=(--force --sign "$alpaca_identity" --identifier "$alpaca_bundle_id")
if [[ "$alpaca_sandbox" == 1 || -n "$alpaca_profile" ]]; then
  alpaca_sign_flags+=(--entitlements "$alpaca_staging/signing.entitlements")
fi
[[ "$alpaca_identity" == - ]] || alpaca_sign_flags+=(--options runtime)
/usr/bin/codesign "${alpaca_sign_flags[@]}" "$alpaca_app"
/usr/bin/codesign --verify --strict "$alpaca_app"
if [[ "$alpaca_identity" != - ]]; then
  # A matching label is insufficient: require an Apple-anchored signature, the
  # actual signed team, and exact bundle ID before publishing the bundle.
  /usr/bin/codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$alpaca_team\" and identifier \"$alpaca_bundle_id\"" "$alpaca_app"
  /usr/bin/codesign --display --verbose=4 "$alpaca_app" 2> "$alpaca_staging/signature.txt"
  if ! awk -F= -v team="$alpaca_team" '$1 == "TeamIdentifier" && $2 == team { found = 1 } END { exit !found }' "$alpaca_staging/signature.txt"; then
    fail "The actual code-signing TeamIdentifier does not match TEAM_ID."
  fi
  if [[ -n "$alpaca_profile" ]]; then
    # Extract public certificates from the finished signature, never private keys.
    /usr/bin/codesign --display --extract-certificates="$alpaca_staging/signer-" "$alpaca_app"
    xcrun python3 - "$alpaca_staging" <<'PY'
import hashlib
import pathlib
import sys
stage = pathlib.Path(sys.argv[1])
actual = hashlib.sha256((stage / "signer-0").read_bytes()).hexdigest()
if actual not in (stage / "allowed-certificates.txt").read_text().splitlines():
    raise SystemExit("AlpacaMusic: The signing certificate is not authorized by the supplied profile.")
PY
  fi
fi

# Publish the app and source version together, only after every check passed.
# On failure the helper restores the previous app; incomplete recovery retains
# its staging directory instead of letting the EXIT trap discard the backup.
app_dir="$PWD/build/AlpacaMusic.app"
xcrun python3 scripts/build-version.py publish "$PWD" "$alpaca_staging"
if [[ "$alpaca_musickit" == 1 ]]; then
  print -r -- "Apple Music build configuration verified; portal enablement, user permission, and subscription are checked when connecting."
else
  print -r -- "Apple Music is unconfigured in this build."
fi
print -r -- "$app_dir"
