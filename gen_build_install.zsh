#!/bin/zsh
set -euo pipefail

# ======================================================================
# Read project config from .build_config in the calling project's root.
#
# Minimal .build_config example (iOS app):
#   BUNDLE_ID="com.aabce.myapp"
#
# Minimal .build_config example (macOS app with notarization):
#   NOTARY_PROFILE="my-app-notary"
#
# All variables and their defaults:
#   SCHEME          — auto-detected from *.xcodeproj (override if needed)
#   BUNDLE_ID=""    — iOS: "com.aabce.xxx" / macOS: leave empty
#   NOTARY_PROFILE=""  — macOS release signing profile; empty disables --release
#   RELEASE_DIR="release"
# ======================================================================

BUNDLE_ID=""
NOTARY_PROFILE=""
RELEASE_DIR="release"

CONFIG_FILE="${PWD}/.build_config"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  echo "Error: .build_config not found in ${PWD}" >&2
  echo "       Create one with at minimum: BUNDLE_ID=\"com.aabce.xxx\" (iOS)" >&2
  echo "       or leave it empty for a macOS app." >&2
  exit 1
fi

# Auto-detect SCHEME from *.xcodeproj directory unless already set in .build_config
if [[ -z "${SCHEME:-}" ]]; then
  local -a _projs=( *.xcodeproj(N/) )
  if [[ ${#_projs} -eq 0 ]]; then
    echo "Error: no *.xcodeproj found in ${PWD} and SCHEME not set in .build_config" >&2
    exit 1
  fi
  SCHEME="${_projs[1]%.xcodeproj}"
fi

CONFIG="${CONFIG:-Release}"
PROJECT="${SCHEME}.xcodeproj"

[[ -n "$BUNDLE_ID" ]] && PLATFORM="ios" || PLATFORM="macos"

# ------------------------------------------------------------------
# usage
# ------------------------------------------------------------------
usage() {
  if [[ "$PLATFORM" == "ios" ]]; then
    cat <<EOF
Usage:
  ./gen_build_install.zsh --list              List connected iOS devices
  ./gen_build_install.zsh -n <device-name>    Build & install by device name
  ./gen_build_install.zsh -i <device-id>      Build & install by device ID
  ./gen_build_install.zsh --sim [name]        Build & launch on Simulator (default: iPhone 17 Pro)
  ./gen_build_install.zsh --archive           Archive + export .ipa for App Store
  ./gen_build_install.zsh --build-check[=configs]
                                              Build-only check (no install/launch)
                                              configs: comma-separated Debug,Release (default: Release)
EOF
  else
    cat <<EOF
Usage:
  ./gen_build_install.zsh --mac               Build & install to /Applications
  ./gen_build_install.zsh --build-check[=configs]
                                              Build-only check (no install)
                                              configs: comma-separated Debug,Release (default: Release)
EOF
    if [[ -n "$NOTARY_PROFILE" ]]; then
      cat <<EOF
  ./gen_build_install.zsh --release [version] Sign (Developer ID), notarize, staple, zip
                                              Output: $RELEASE_DIR/${SCHEME}-<version>.zip
EOF
    fi
  fi
  exit 1
}

# ------------------------------------------------------------------
# iOS helpers
# ------------------------------------------------------------------
list_devices() {
  echo "Connected iOS devices:"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'platform=iOS' -showdestinations 2>/dev/null \
    | grep 'platform:iOS,' | grep -v Simulator | grep -v placeholder \
    | sed 's/.*{ /  /' | sed 's/ }$//'
}

resolve_device_id() {
  local name="$1"
  local id
  id=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
       -destination 'platform=iOS' -showdestinations 2>/dev/null \
     | grep 'platform:iOS,' | grep -v Simulator | grep -v placeholder \
     | grep "name:${name}" | head -1 \
     | sed 's/.*id:\([^,}]*\).*/\1/' | tr -d ' ')
  if [[ -z "$id" ]]; then
    echo "Error: device '$name' not found." >&2
    echo "Run './gen_build_install.zsh --list' to see available devices." >&2
    exit 1
  fi
  echo "$id"
}

# Resolve BUILT_PRODUCTS_DIR for the given xcodebuild args (passed as "$@")
resolve_app_path() {
  xcodebuild "$@" -showBuildSettings 2>/dev/null \
    | grep -m1 ' BUILT_PRODUCTS_DIR' | awk '{print $3}'
}

# ------------------------------------------------------------------
# iOS: Archive + export .ipa for App Store
# ------------------------------------------------------------------
archive_for_app_store() {
  local archive_path="build/${SCHEME}.xcarchive"
  local export_dir="build/export"
  local export_opts="build/ExportOptions.plist"

  echo "==> xcodegen generate"
  xcodegen generate

  rm -rf "$archive_path" "$export_dir"
  mkdir -p "build"

  cat > "$export_opts" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>PNKEK75AK4</string>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

  echo "==> Archiving $SCHEME (Release) for iOS ..."
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive_path" \
    archive

  echo "==> Exporting .ipa to $export_dir ..."
  xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_opts"

  echo "==> Archive: $archive_path"
  echo "==> IPA:     $export_dir/$SCHEME.ipa"
  echo ""
  echo "次のステップ: Transporter.app または"
  echo "  xcrun altool --upload-app -f $export_dir/$SCHEME.ipa -t ios -u <Apple ID> -p <app-specific-password>"
}

# ------------------------------------------------------------------
# macOS: Sign, notarize, staple, zip for distribution
# ------------------------------------------------------------------
release_macos() {
  local version="${1:-}"

  echo "==> Verifying HEAD == origin/main ..."
  git rev-parse --git-dir > /dev/null 2>&1 || { echo "Error: not a git repository" >&2; exit 1; }
  git fetch origin main --quiet || { echo "Error: failed to fetch origin/main" >&2; exit 1; }

  local local_head remote_main
  local_head="$(git rev-parse HEAD)"
  remote_main="$(git rev-parse origin/main)"

  if [[ "$local_head" != "$remote_main" ]]; then
    echo "Error: HEAD ($local_head) does not match origin/main ($remote_main)." >&2
    echo "       Commit, push, and merge to main before releasing." >&2
    exit 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: working tree has uncommitted changes:" >&2
    git status --short >&2
    exit 1
  fi
  echo "    HEAD: $local_head (matches origin/main, clean)"

  echo "==> xcodegen generate"
  xcodegen generate

  if [[ -z "$version" ]]; then
    version="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
      -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
      | grep -m1 ' MARKETING_VERSION' | awk '{print $3}')"
  fi
  echo "==> Release version: $version"

  echo "==> Building $SCHEME ($CONFIG) with Developer ID signing ..."
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build

  local app_path
  app_path="$(resolve_app_path -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG")/$SCHEME.app"

  echo "==> Verifying signature ..."
  codesign -dv --verbose=2 "$app_path" 2>&1 | grep -E '(Authority|TeamIdentifier|Identifier)' || true
  codesign --verify --strict --verbose=2 "$app_path"

  mkdir -p "$RELEASE_DIR"
  local notarize_zip="$RELEASE_DIR/$SCHEME-notarize-tmp.zip"
  local final_zip="$RELEASE_DIR/$SCHEME-$version.zip"

  echo "==> Zipping for notarization ..."
  rm -f "$notarize_zip"
  /usr/bin/ditto -c -k --keepParent "$app_path" "$notarize_zip"

  echo "==> Submitting to Apple notary service (profile: $NOTARY_PROFILE) ..."
  local submit_log="$RELEASE_DIR/notarize-submit.log"
  set +e
  xcrun notarytool submit "$notarize_zip" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1 | tee "$submit_log"
  local notary_rc=$?
  set -e

  local submission_id status
  submission_id="$(grep -m1 -E '^[[:space:]]+id:' "$submit_log" | awk '{print $2}')"
  status="$(grep -m1 -E '^[[:space:]]+status:' "$submit_log" | awk '{print $2}')"

  if [[ "$status" != "Accepted" ]]; then
    echo "==> Notarization failed (status: $status). Fetching log ..." >&2
    [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi

  echo "==> Stapling notary ticket to .app ..."
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"

  echo "==> Creating final release zip ..."
  rm -f "$final_zip" "$notarize_zip"
  /usr/bin/ditto -c -k --keepParent "$app_path" "$final_zip"

  echo ""
  echo "==> Release ready: $final_zip"
  echo "    Upload: gh release create v$version $final_zip --title 'v$version' --notes '...'"
}

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  usage
fi

DEVICE_ID=""

case "$1" in
  # ---- --build-check -----------------------------------------------
  --build-check*)
    BC_ARG="${1#--build-check}"
    BC_ARG="${BC_ARG#=}"
    if [[ -z "$BC_ARG" ]]; then
      BC_CONFIGS=("Release")
    else
      BC_CONFIGS=("${(@s/,/)BC_ARG}")
    fi

    echo "==> xcodegen generate"
    xcodegen generate

    BC_FAILED=0
    for BC_CFG in "${BC_CONFIGS[@]}"; do
      if [[ "$PLATFORM" == "ios" ]]; then
        if [[ "$BC_CFG" == "Debug" ]]; then
          BC_DEST="platform=iOS Simulator,name=iPhone 17 Pro"
        else
          BC_DEST="generic/platform=iOS"
        fi
        BC_DEST_ARGS=(-destination "$BC_DEST")
      else
        BC_DEST_ARGS=()
      fi

      echo "==> Build check: $SCHEME ($BC_CFG) ..."
      set +e
      xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -configuration "$BC_CFG" \
        "${BC_DEST_ARGS[@]}" \
        build
      BC_RC=$?
      set -e
      if [[ $BC_RC -eq 0 ]]; then
        echo "==> $BC_CFG: BUILD SUCCEEDED"
      else
        echo "==> $BC_CFG: BUILD FAILED" >&2
        BC_FAILED=1
      fi
    done

    if [[ $BC_FAILED -ne 0 ]]; then
      echo "==> Build check FAILED" >&2
      exit 1
    fi
    echo "==> All build checks passed!"
    exit 0
    ;;

  # ---- iOS: simulator ----------------------------------------------
  --sim|-s)
    [[ "$PLATFORM" != "ios" ]] && { echo "Error: --sim is only for iOS apps (set BUNDLE_ID in .build_config)" >&2; exit 1; }
    SIM_NAME="${2:-iPhone 17 Pro}"

    echo "==> xcodegen generate"
    xcodegen generate

    echo "==> Building $SCHEME (Debug) for Simulator '$SIM_NAME' ..."
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
      -configuration Debug \
      -destination "platform=iOS Simulator,name=$SIM_NAME" \
      build

    APP_PATH="$(resolve_app_path \
      -project "$PROJECT" -scheme "$SCHEME" \
      -configuration Debug -destination "platform=iOS Simulator,name=$SIM_NAME")/$SCHEME.app"

    echo "==> Booting Simulator '$SIM_NAME' ..."
    xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
    open -a Simulator

    echo "==> Installing $APP_PATH"
    xcrun simctl install "$SIM_NAME" "$APP_PATH"

    echo "==> Launching $SCHEME on Simulator ..."
    xcrun simctl launch "$SIM_NAME" "$BUNDLE_ID"

    echo "==> Done!"
    exit 0
    ;;

  # ---- iOS: list devices -------------------------------------------
  --list|-l)
    [[ "$PLATFORM" != "ios" ]] && { echo "Error: --list is only for iOS apps" >&2; exit 1; }
    list_devices
    exit 0
    ;;

  # ---- iOS: device by name ----------------------------------------
  -n)
    [[ "$PLATFORM" != "ios" ]] && { echo "Error: -n is only for iOS apps" >&2; exit 1; }
    [[ $# -lt 2 ]] && { echo "Error: -n requires a device name." >&2; exit 1; }
    DEVICE_ID=$(resolve_device_id "$2")
    ;;

  # ---- iOS: device by ID ------------------------------------------
  -i)
    [[ "$PLATFORM" != "ios" ]] && { echo "Error: -i is only for iOS apps" >&2; exit 1; }
    [[ $# -lt 2 ]] && { echo "Error: -i requires a device ID." >&2; exit 1; }
    DEVICE_ID="$2"
    ;;

  # ---- iOS: archive for App Store ---------------------------------
  --archive)
    [[ "$PLATFORM" != "ios" ]] && { echo "Error: --archive is only for iOS apps" >&2; exit 1; }
    archive_for_app_store
    exit 0
    ;;

  # ---- macOS: build & install to /Applications -------------------
  --mac|-m)
    [[ "$PLATFORM" != "macos" ]] && { echo "Error: --mac is only for macOS apps (leave BUNDLE_ID empty in .build_config)" >&2; exit 1; }

    echo "==> xcodegen generate"
    xcodegen generate

    echo "==> Building $SCHEME ($CONFIG) ..."
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      build

    APP_PATH="$(resolve_app_path \
      -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG")/$SCHEME.app"

    echo "==> Installing $APP_PATH to /Applications ..."
    rm -rf "/Applications/$SCHEME.app"
    /usr/bin/ditto "$APP_PATH" "/Applications/$SCHEME.app"

    echo "==> Done!"
    exit 0
    ;;

  # ---- macOS: sign, notarize, zip ---------------------------------
  --release)
    [[ "$PLATFORM" != "macos" ]] && { echo "Error: --release is only for macOS apps" >&2; exit 1; }
    [[ -z "$NOTARY_PROFILE" ]] && { echo "Error: set NOTARY_PROFILE in .build_config to use --release" >&2; exit 1; }
    release_macos "${2:-}"
    exit 0
    ;;

  -*)
    echo "Error: unknown option '$1'" >&2
    usage
    ;;
  *)
    echo "Error: unknown argument '$1'" >&2
    usage
    ;;
esac

# ------------------------------------------------------------------
# iOS: build & install to physical device (after -n / -i resolved)
# ------------------------------------------------------------------
echo "==> Target device: $DEVICE_ID"

echo "==> xcodegen generate"
xcodegen generate

echo "==> Building $SCHEME ($CONFIG) ..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "id=$DEVICE_ID" \
  build

APP_PATH="$(resolve_app_path \
  -project "$PROJECT" -scheme "$SCHEME" \
  -configuration "$CONFIG" -destination "id=$DEVICE_ID")/$SCHEME.app"

echo "==> Installing $APP_PATH"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" \
  2>&1 | grep -v "Failed to load provisioning"

echo "==> Done!"
