#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c release --build-system native --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
MX_NOTI_BIN_DIR=$(swift build -c release --build-system native --show-bin-path --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)
MX_NOTI_APP="$PWD/dist/MX Noti.app"
mkdir -p "$MX_NOTI_APP/Contents/MacOS" "$MX_NOTI_APP/Contents/Resources"
cp "$MX_NOTI_BIN_DIR/MXNoti" "$MX_NOTI_APP/Contents/MacOS/MXNoti"
cp Resources/Info.plist "$MX_NOTI_APP/Contents/Info.plist"
swift scripts/icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$MX_NOTI_APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$MX_NOTI_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --sign - --identifier local.mx-noti "$MX_NOTI_APP"
codesign --verify --strict "$MX_NOTI_APP"
print "앱 생성 완료: $MX_NOTI_APP"
