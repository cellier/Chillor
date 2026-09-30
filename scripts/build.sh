#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p work outputs
swift scripts/make-app-icon.swift Resources/AppIcon.png work/AppIcon.iconset
iconutil -c icns work/AppIcon.iconset -o Resources/AppIcon.icns
swift build -c release
app_path="$PWD/outputs/Chillor.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/Chillor "$app_path/Contents/MacOS/Chillor.next"
mv -f "$app_path/Contents/MacOS/Chillor.next" "$app_path/Contents/MacOS/Chillor"
if [[ ! -x Resources/AgentPython/bin/python3 || ! -d Resources/AgentPython/lib/python3.12/site-packages/agents ]]; then
  print -u2 "Missing Agents SDK runtime. Run scripts/setup-agent-runtime.sh first."
  exit 1
fi
ditto Resources/AgentPython "$app_path/Contents/Resources/AgentPython"
ditto Resources/AgentTools "$app_path/Contents/Resources/AgentTools"
cp Resources/Welcome.png "$app_path/Contents/Resources/Welcome.png"
cp Resources/MenuBarIcon.png "$app_path/Contents/Resources/MenuBarIcon.png"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIconMac.icns"
if [[ ! -x Resources/ModelRuntime/ollama ]]; then
  print -u2 "Missing bundled model runtime: Resources/ModelRuntime/ollama"
  exit 1
fi
ditto Resources/ModelRuntime "$app_path/Contents/Resources/runtime"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Chillor</string>
<key>CFBundleIdentifier</key><string>com.chillor.mac</string>
<key>CFBundleName</key><string>Chillor</string>
<key>CFBundleDisplayName</key><string>Chillor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIconMac.icns</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Chillor reads content near your pointer when you trigger a quick command. Processing stays on this Mac.</string>
</dict></plist>
PLIST
mkdir -p "$app_path/Contents/Resources/ThirdPartyNotices"
cp Vendor/swift-markdown-ui/LICENSE "$app_path/Contents/Resources/ThirdPartyNotices/MarkdownUI.txt"
cp Vendor/NetworkImage/LICENSE "$app_path/Contents/Resources/ThirdPartyNotices/NetworkImage.txt"
cp Vendor/swift-cmark/COPYING "$app_path/Contents/Resources/ThirdPartyNotices/cmark.txt"
# Set this to a stable Apple Development/Developer ID identity when available.
# Ad-hoc builds may require Screen Recording authorization again after updates.
chillor_signing_identity="${CHILLOR_SIGNING_IDENTITY:--}"
python3 scripts/compact-bundle.py "$app_path"
codesign --force --deep --sign "$chillor_signing_identity" "$app_path"
codesign --verify --deep --strict "$app_path"
# Updating files inside a bundle does not update its directory modification date.
# Notify Launch Services after the complete, signed bundle is ready so Finder
# does not retain the placeholder icon from the first incomplete development build.
touch "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"
print "Built: $app_path"
