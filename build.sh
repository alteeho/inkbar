#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
xcodebuild -project Inkbar.xcodeproj -scheme Inkbar -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -destination 'platform=macOS,arch=arm64' build
mkdir -p dist
rm -rf dist/Inkbar.app
cp -R build/Build/Products/Release/Inkbar.app dist/Inkbar.app
echo "Built dist/Inkbar.app"
