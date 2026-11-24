#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/build/WinBridge.app"

cd "$ROOT_DIR"
EXTRA_ARGS=()
if [[ "${1:-}" == "--disable-sandbox" ]]; then
    EXTRA_ARGS+=(--disable-sandbox)
fi
swift build -c release ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/.build/release/WinBridgeClient" "$APP_DIR/Contents/MacOS/WinBridge"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>WinBridge</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.winbridge.client</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>WinBridge</string>
    <key>CFBundleDisplayName</key>
    <string>WinBridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.5.4</string>
    <key>CFBundleVersion</key>
    <string>7</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>WinBridge 需要访问局域网以发现并连接您的 Windows 主机，投射应用窗口。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_winbridge._tcp</string>
    </array>
</dict>
</plist>
EOF

# Sign with a stable local certificate when available so macOS 15/26 preserves Local Network &
# Keychain permissions across rebuilds (preventing CDHash resets on ad-hoc binaries).
SIGN_IDENTITY="${WINBRIDGE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"WinBridge Local Dev"'; then
        SIGN_IDENTITY="WinBridge Local Dev"
    fi
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Signing $APP_DIR with persistent identity: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "com.winbridge.client" "$APP_DIR"
else
    echo "No persistent code-signing identity found; applying ad-hoc signature."
    echo "Tip: run ./scripts/setup_codesign.sh once to keep macOS Local Network permissions across rebuilds."
    codesign --force --deep --sign - --identifier "com.winbridge.client" "$APP_DIR"
fi

touch "$APP_DIR"
echo "Built app bundle at: $APP_DIR"
echo "Run with: open \"$APP_DIR\""
