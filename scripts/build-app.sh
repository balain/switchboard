#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_version="${APP_VERSION:-1.0.0}"
app_build="${APP_BUILD_NUMBER:-1}"
if [[ ! "$app_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! "$app_build" =~ '^[0-9]+$' ]]; then
    print -u2 "APP_VERSION must be MAJOR.MINOR.PATCH and APP_BUILD_NUMBER must be numeric."
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang"
export SWIFT_MODULECACHE_PATH="$PWD/.build-cache/swift"
swift build -c release --disable-sandbox --cache-path .build-cache -debug-info-format none
APP="$PWD/dist/Switchboard.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Switchboard "$APP/Contents/MacOS/Switchboard"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Switchboard</string>
<key>CFBundleDisplayName</key><string>Switchboard</string>
<key>CFBundleIdentifier</key><string>local.switchboard.app</string>
<key>CFBundleExecutable</key><string>Switchboard</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_build" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
print "Built $APP"
