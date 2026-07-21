#!/bin/zsh
# new_project.zsh — Bootstrap a new XcodeGen iOS/macOS project
#
# Run from inside the already-initialized git repo:
#   git init garden-log && cd garden-log
#   /path/to/ai-build-support/new_project.zsh GardenLog ios gardenlog
#
# Arguments:
#   AppName       PascalCase app name  (e.g. GardenLog)      [required]
#   ios|macos     platform             (default: ios)
#   bundle-suffix lowercase suffix     (default: lowercase of AppName)
#
# After the script finishes:
#   gh repo create shinyaohtani/<AppName> --private --source=. --remote=origin
#   git push -u origin main
#   ./ai-build-support/gen_build_install.zsh --build-check

set -euo pipefail

SCRIPT_DIR="${0:A:h}"   # absolute path of ai-build-support/

# ── arguments ────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage:
  /path/to/ai-build-support/new_project.zsh <AppName> [ios|macos] [bundle-suffix]

Arguments:
  AppName        PascalCase app name (e.g. GardenLog)          [required]
  ios|macos      target platform                                 [default: ios]
  bundle-suffix  lowercase Bundle ID suffix (e.g. gardenlog)    [default: lowercase of AppName]

Examples:
  git init garden-log && cd garden-log
  ~/unix/cloned/ai-build-support/new_project.zsh GardenLog
  ~/unix/cloned/ai-build-support/new_project.zsh GardenLog ios gardenlog

  git init link-helper && cd link-helper
  ~/unix/cloned/ai-build-support/new_project.zsh LinkHelper macos linkhelper

What this script does:
  1. Add ai-build-support as a git submodule
  2. Create .build_config  (BUNDLE_ID, LOG_NAME)
  3. Generate project.yml  from ai-build-support/project_template_{ios,macos}.yml
  4. Scaffold minimal SwiftUI source (App, ContentView, Assets, PrivacyInfo, UITests)
  5. Create .gitignore
  6. Run xcodegen generate
  7. Make the initial commit

After the script finishes:
  gh repo create shinyaohtani/<repo-dir-name> --private --source=. --remote=origin
  git push -u origin main
  ./ai-build-support/gen_build_install.zsh --build-check
EOF
}

if [[ $# -lt 1 || "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  [[ $# -lt 1 ]] && exit 1 || exit 0
fi

APP_NAME="$1"
PLATFORM="${2:-ios}"
BUNDLE_SUFFIX="${3:-${(L)APP_NAME}}"
BUNDLE_ID="com.aabce.${BUNDLE_SUFFIX}"
LOG_NAME="${BUNDLE_SUFFIX}_debug.log"

if [[ "$PLATFORM" != "ios" && "$PLATFORM" != "macos" ]]; then
  print -u2 "Error: platform must be 'ios' or 'macos'"; exit 1
fi

# ── must be run inside a git repo ─────────────────────────────────────────────
if ! git rev-parse --git-dir &>/dev/null; then
  print -u2 "Error: not a git repository. Run 'git init' first."; exit 1
fi

# ── abort if already initialized ──────────────────────────────────────────────
if [[ -f .gitmodules ]] || [[ -d ai-build-support ]]; then
  print -u2 "Error: this repository is already initialized (ai-build-support exists)."
  print -u2 "       new_project.zsh is for fresh repositories only."
  exit 1
fi

# ── confirm ───────────────────────────────────────────────────────────────────
echo "==> New ${PLATFORM} project in $(pwd)"
echo "    Name:      ${APP_NAME}"
echo "    Bundle ID: ${BUNDLE_ID}"
echo "    Log name:  ${LOG_NAME}"
echo -n "    Continue? [Y/n]: "
read -r ANSWER
[[ "${ANSWER}" == "n" || "${ANSWER}" == "N" ]] && { echo "Aborted."; exit 1; }

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
  -e "s/com\.aabce\.MyApp/com.aabce.${BUNDLE_SUFFIX}/g" \
  -e "s/com\.aabce\.myapp/com.aabce.${BUNDLE_SUFFIX}/g" \
  -e "s/MyApp/${APP_NAME}/g" \
  "${SCRIPT_DIR}/project_template_${PLATFORM}.yml" > project.yml

# ── source structure ──────────────────────────────────────────────────────────
echo "==> Creating source structure..."
mkdir -p "${APP_NAME}"

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

cat > "${APP_NAME}/ContentView.swift" <<EOF
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Hello, ${APP_NAME}!")
    }
}
EOF

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
# ── Xcode ─────────────────────────────────────────────────────────────────────
# Generated by XcodeGen — never edit manually
*.xcodeproj/
*.xcworkspace/xcuserdata/
xcuserdata/
*.xcuserstate

# ── Build artifacts ────────────────────────────────────────────────────────────
build/
DerivedData/
release/
*.xcarchive
*.ipa
*.dSYM/
*.dSYM.zip

# ── Swift Package Manager ──────────────────────────────────────────────────────
.swiftpm/
.build/
Package.resolved

# ── Runtime / SQLite (SwiftData) ───────────────────────────────────────────────
*.sqlite
*.sqlite-shm
*.sqlite-wal

# ── Tool output ────────────────────────────────────────────────────────────────
logs/
backups/
tmp/
output/

# ── macOS ──────────────────────────────────────────────────────────────────────
.DS_Store

# ── Editor swap files ──────────────────────────────────────────────────────────
*.swp
*~

# ── Claude Code local settings ─────────────────────────────────────────────────
.claude/

# ── Python helper scripts ──────────────────────────────────────────────────────
__pycache__/

# ── Secrets ────────────────────────────────────────────────────────────────────
.env

# ── Local reference files (not part of this project) ──────────────────────────
refs/
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
echo "==> Done!"
echo ""
REPO_NAME="$(basename $PWD)"
echo "Next steps:"
echo "  gh repo create shinyaohtani/${REPO_NAME} --private --source=. --remote=origin"
echo "  git push -u origin main"
echo "  ./ai-build-support/gen_build_install.zsh --build-check"
