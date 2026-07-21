#!/bin/zsh
# new_project.zsh — Bootstrap a new XcodeGen iOS/macOS project
#
# Usage (from the directory where you keep your projects):
#   /path/to/ai-build-support/new_project.zsh <AppName> [ios|macos] [bundle-suffix]
#
# Example:
#   cd ~/unix/cloned
#   ./ai-build-support/new_project.zsh GardenLog ios gardenlog
#   ./ai-build-support/new_project.zsh LinkHelper macos linkhelper
#
# After the script finishes:
#   cd <AppName>
#   gh repo create shinyaohtani/<AppName> --private --source=. --remote=origin
#   git push -u origin main
#   ./ai-build-support/gen_build_install.zsh --build-check

set -euo pipefail

SCRIPT_DIR="${0:A:h}"   # absolute path of ai-build-support/

# ── arguments ────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  print -u2 "Usage: $(basename $0) <AppName> [ios|macos] [bundle-suffix]"
  print -u2 "  AppName:       PascalCase  (e.g. GardenLog)"
  print -u2 "  ios|macos:     platform    (default: ios)"
  print -u2 "  bundle-suffix: lowercase   (default: lowercase of AppName)"
  exit 1
fi

APP_NAME="$1"
PLATFORM="${2:-ios}"
BUNDLE_SUFFIX="${3:-${(L)APP_NAME}}"
BUNDLE_ID="com.aabce.${BUNDLE_SUFFIX}"
LOG_NAME="${BUNDLE_SUFFIX}_debug.log"

if [[ "$PLATFORM" != "ios" && "$PLATFORM" != "macos" ]]; then
  print -u2 "Error: platform must be 'ios' or 'macos'"; exit 1
fi

PROJECT_DIR="${PWD}/${APP_NAME}"
if [[ -e "$PROJECT_DIR" ]]; then
  print -u2 "Error: ${PROJECT_DIR} already exists"; exit 1
fi

# ── confirm ───────────────────────────────────────────────────────────────────
echo "==> New ${PLATFORM} project"
echo "    Name:      ${APP_NAME}"
echo "    Bundle ID: ${BUNDLE_ID}"
echo "    Log name:  ${LOG_NAME}"
echo "    Directory: ${PROJECT_DIR}"
echo -n "    Continue? [Y/n]: "
read -r ANSWER
[[ "${ANSWER}" == "n" || "${ANSWER}" == "N" ]] && { echo "Aborted."; exit 1; }

# ── git init ─────────────────────────────────────────────────────────────────
mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}"
git init

# ── submodule ─────────────────────────────────────────────────────────────────
echo "==> Adding ai-build-support submodule..."
git submodule add git@github.com:shinyaohtani/ai-build-support.git ai-build-support

# ── .build_config ─────────────────────────────────────────────────────────────
echo "==> Creating .build_config..."
if [[ "$PLATFORM" == "ios" ]]; then
  cat > .build_config <<EOF
BUNDLE_ID="${BUNDLE_ID}"
LOG_NAME="${LOG_NAME}"
EOF
else
  cat > .build_config <<EOF
BUNDLE_ID=""
NOTARY_PROFILE=""
LOG_NAME="${LOG_NAME}"
EOF
fi

# ── project.yml ───────────────────────────────────────────────────────────────
echo "==> Creating project.yml from template..."
sed \
  -e "s/MyApp/${APP_NAME}/g" \
  -e "s/com\.aabce\.MyApp/com.aabce.${BUNDLE_SUFFIX}/g" \
  -e "s/com\.aabce\.myapp/com.aabce.${BUNDLE_SUFFIX}/g" \
  "${SCRIPT_DIR}/project_template_${PLATFORM}.yml" > project.yml

# ── source structure ──────────────────────────────────────────────────────────
echo "==> Creating source structure..."
mkdir -p "${APP_NAME}"

# App entry point
cat > "${APP_NAME}/${APP_NAME}App.swift" <<EOF
import SwiftUI

@main
struct ${APP_NAME}App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
EOF

# ContentView
cat > "${APP_NAME}/ContentView.swift" <<EOF
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Hello, ${APP_NAME}!")
    }
}
EOF

# Assets.xcassets (minimal — add icons later)
mkdir -p "${APP_NAME}/Assets.xcassets/AppIcon.appiconset"
cat > "${APP_NAME}/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "${APP_NAME}/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# PrivacyInfo.xcprivacy (iOS 17+ App Store requirement)
if [[ "$PLATFORM" == "ios" ]]; then
  cat > "${APP_NAME}/PrivacyInfo.xcprivacy" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <!-- UserDefaults (設定保存) -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>CA92.1</string></array>
        </dict>
    </array>
</dict>
</plist>
XML
fi

# UITest target (iOS only; macOS template has no test target)
if [[ "$PLATFORM" == "ios" ]]; then
  mkdir -p "${APP_NAME}UITests"
  cat > "${APP_NAME}UITests/${APP_NAME}UITests.swift" <<EOF
import XCTest

final class ${APP_NAME}UITests: XCTestCase {
    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }
}
EOF
fi

# ── .gitignore ────────────────────────────────────────────────────────────────
cat > .gitignore <<'GITIGNORE'
# Generated by XcodeGen — never edit manually
*.xcodeproj/
*.xcworkspace/xcuserdata/
xcuserdata/
*.xcuserstate

# Build artifacts
build/
DerivedData/
release/
*.xcarchive
*.ipa

# Debug / tool output
logs/
backups/
tmp/

# macOS
.DS_Store

# Swift Package Manager
.swiftpm/
.build/
Package.resolved

# SQLite runtime files
*.sqlite
*.sqlite-shm
*.sqlite-wal
GITIGNORE

# ── xcodegen ─────────────────────────────────────────────────────────────────
echo "==> Running xcodegen generate..."
if ! command -v xcodegen &>/dev/null; then
  print -u2 "Error: xcodegen not found in PATH. Install with: brew install xcodegen"
  exit 1
fi
xcodegen generate

# ── initial commit ────────────────────────────────────────────────────────────
echo "==> Initial commit..."
git add .
git commit -m "$(cat <<MSG
chore: initial ${PLATFORM} project setup

- ai-build-support submodule added
- XcodeGen project.yml from template
- Minimal SwiftUI scaffold

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
MSG
)"

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> Done!  ${PROJECT_DIR}"
echo ""
echo "Next steps:"
echo "  cd ${APP_NAME}"
echo "  gh repo create shinyaohtani/${APP_NAME} --private --source=. --remote=origin"
echo "  git push -u origin main"
echo "  ./ai-build-support/gen_build_install.zsh --build-check"
