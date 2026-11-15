#!/bin/sh
# Builds a Release Dash.app at a version and zips it as dist/Dash-<version>.zip, the asset the
# in-app updater looks for. With --install, it also replaces /Applications/Dash.app and opens it.
# Publishing stays manual: the script prints the `gh release create` command to run.
#
#   scripts/release.sh 0.2.0 [--install]
set -eu
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/release.sh <version> [--install]}"
install="${2:-}"
build=build/release
app="$build/Build/Products/Release/Dash.app"
zip="dist/Dash-$version.zip"

xcodegen generate --quiet
xcodebuild -project Dash.xcodeproj -scheme Dash -configuration Release -derivedDataPath "$build" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" -quiet build
codesign --verify --deep --strict "$app"

mkdir -p dist
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "Built $zip ($(shasum -a 256 "$zip" | cut -d' ' -f1))"

if [ "$install" = "--install" ]; then
  pkill -x Dash 2>/dev/null && while pgrep -x Dash >/dev/null; do sleep 0.2; done || true
  rm -rf /Applications/Dash.app
  ditto "$app" /Applications/Dash.app
  open /Applications/Dash.app
  echo "Installed /Applications/Dash.app"
fi

echo
echo "To publish it (the updater reads the latest release):"
echo "  git tag v$version && git push origin v$version"
echo "  gh release create v$version $zip --title \"Dash $version\" --generate-notes"
