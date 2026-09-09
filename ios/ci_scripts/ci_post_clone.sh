#!/bin/sh
# Xcode Cloud: install Flutter + iOS deps after clone.
set -e

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "=== Install Flutter SDK ==="
FLUTTER_DIR="$HOME/flutter"
if [ ! -d "$FLUTTER_DIR/bin" ]; then
  git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$FLUTTER_DIR"
fi
export PATH="$PATH:$FLUTTER_DIR/bin"

flutter --version

echo "=== Disable SwiftPM (Xcode Cloud + Flutter workaround) ==="
flutter config --no-enable-swift-package-manager

echo "=== Flutter precache + pub get ==="
flutter precache --ios
flutter pub get

echo "=== Install CocoaPods ==="
if ! command -v pod >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install cocoapods
fi

echo "=== pod install ==="
cd ios
pod install
cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "=== Flutter iOS config-only ==="
flutter build ios --config-only --release

echo "=== ci_post_clone complete ==="
