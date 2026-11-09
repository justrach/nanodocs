#!/bin/sh
# Builds nanodocs.app (and optionally installs to /Applications/nanodocs.app).
#
#   sh macos/package.sh [--install]
set -eu
cd "$(dirname "$0")/.."

app=nanodocs
version="${VERSION:-0.2.0}"
out=zig-out/package
bundle="$out/$app.app"
min_macos=13.0

zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos.$min_macos -Dcpu=apple_m1 --fork=../..

rm -rf "$out"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "zig-out/bin/$app" "$bundle/Contents/MacOS/$app"
cp macos/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$app</string>
  <key>CFBundleDisplayName</key><string>$app</string>
  <key>CFBundleIdentifier</key><string>com.justrach.$app</string>
  <key>CFBundleExecutable</key><string>$app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleGetInfoString</key><string>Native GPU Markdown, HTML &amp; Mermaid Studio + Agent MCP</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>$min_macos</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
        <string>public.html</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>md</string>
        <string>markdown</string>
        <string>html</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$bundle"
else
  codesign --force --sign - "$bundle"
fi

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/$app.app"
  cp -R "$bundle" "/Applications/$app.app"
  mkdir -p "$HOME/.local/bin"
  ln -sf "/Applications/$app.app/Contents/MacOS/$app" "$HOME/.local/bin/$app"
  echo "Installed /Applications/$app.app and linked $HOME/.local/bin/$app"
fi
