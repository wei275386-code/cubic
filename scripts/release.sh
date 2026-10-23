#!/bin/sh
# Archive and export a signed Cubic build into release-output/.
#
#   scripts/release.sh mac         Developer ID Mac app (Cubic.zip)
#   scripts/release.sh ios-adhoc   Ad Hoc iOS app (Cubic.ipa) for registered devices
#
# Optional environment:
#   CUBIC_TEAM_ID         signing team (default: DEVELOPMENT_TEAM in project.yml)
#   CUBIC_VERSION         overrides MARKETING_VERSION
#   CUBIC_BUILD           overrides CURRENT_PROJECT_VERSION
#   CUBIC_NOTARY_PROFILE  mac only: notarytool Keychain profile; notarizes and staples when set
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "${1:-}" in
  mac) scheme=CubicMac; destination='generic/platform=macOS'; method=developer-id ;;
  ios-adhoc) scheme=Cubic; destination='generic/platform=iOS'; method=release-testing ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

team=${CUBIC_TEAM_ID:-$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' "$root/project.yml" | head -n 1)}
output="$root/release-output/$1-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$output"

set -- -project "$root/Cubic.xcodeproj" -scheme "$scheme" -configuration Release \
  -destination "$destination" -archivePath "$output/Cubic.xcarchive" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$team"
[ -n "${CUBIC_VERSION:-}" ] && set -- "$@" MARKETING_VERSION="$CUBIC_VERSION"
[ -n "${CUBIC_BUILD:-}" ] && set -- "$@" CURRENT_PROJECT_VERSION="$CUBIC_BUILD"
xcodebuild "$@" archive

cat > "$output/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>$method</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$team</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$output/Cubic.xcarchive" \
  -exportOptionsPlist "$output/ExportOptions.plist" -exportPath "$output/export" -allowProvisioningUpdates

if [ "$scheme" = CubicMac ]; then
  app="$output/export/Cubic.app"
  if [ -n "${CUBIC_NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$app" "$output/notary-upload.zip"
    xcrun notarytool submit "$output/notary-upload.zip" --keychain-profile "$CUBIC_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    rm "$output/notary-upload.zip"
  fi
  ditto -c -k --keepParent "$app" "$output/Cubic.zip"
  echo "Done: $output/Cubic.zip"
else
  echo "Done: $(ls "$output"/export/*.ipa)"
fi
