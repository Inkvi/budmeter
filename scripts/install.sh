#!/bin/bash
# Build a release copy of BudMeter, install it to /Applications and start it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project BudMeter.xcodeproj -scheme BudMeter -configuration Release \
  -derivedDataPath build -quiet build

pkill -x BudMeter 2>/dev/null || true
rm -rf /Applications/BudMeter.app
cp -R build/Build/Products/Release/BudMeter.app /Applications/
open /Applications/BudMeter.app
echo "BudMeter installed to /Applications and running in the menu bar."
