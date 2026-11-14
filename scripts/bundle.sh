#!/bin/sh
# Builds build/notepanel.app from the release binary and the editor page, signed ad hoc.
set -eu
cd "$(dirname "$0")/.."

version="0.1.4" # The release workflow checks that the tag matches this.

# ARCHS="arm64 x86_64" builds a universal app, as the release workflow does.
# shortcut: Swift Build, the default from Swift 6.4, links with the Command Line Tools recording the
# deployment target (macOS 14) as the SDK version, so the app gets the look from before macOS 26;
# drop --build-system native once Swift Build records the real SDK version.
set --
for arch in ${ARCHS:-$(uname -m)}; do
    swift build -c release --build-system native --product Notepanel --arch "$arch"
    set -- "$@" "$(swift build -c release --build-system native --arch "$arch" --show-bin-path)/Notepanel"
done
app="build/notepanel.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "$@" -output "$app/Contents/MacOS/notepanel"
cp -R web "$app/Contents/Resources/web"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>notepanel</string>
  <key>CFBundleIdentifier</key><string>io.github.kkensuke.notepanel</string>
  <key>CFBundleName</key><string>notepanel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$app"
echo "Built $app"
