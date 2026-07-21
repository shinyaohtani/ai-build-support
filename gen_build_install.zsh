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
# Verbosity: verbose | normal | quiet
#   --verbose  全出力表示 (xcodebuild 生ログ含む)
#   (default)  ==> 進捗 + warnings/errors + BUILD 結果のみ
#   --quiet    warnings/errors のみ (==> 進捗も非表示)
#
# 使い方: 他のフラグの前後どちらでも指定可
#   ./gen_build_install.zsh --quiet -n 'iPhone 16'
#   ./gen_build_install.zsh -n 'iPhone 16' --verbose
# ------------------------------------------------------------------
VERBOSITY="normal"
_remaining_args=()
for _a in "$@"; do
  case "$_a" in
    --verbose) VERBOSITY="verbose" ;;
    --quiet)   VERBOSITY="quiet"   ;;
    *)         _remaining_args+=("$_a") ;;
  esac
done
if (( ${#_remaining_args[@]} )); then
  set -- "${_remaining_args[@]}"
else
  set --
fi

# ------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------
log_info() {
  [[ "$VERBOSITY" != "quiet" ]] && print -- "$*" || true
}

# Run xcodegen; in normal/quiet mode suppress informational output.
# On failure, always show full output regardless of verbosity.
run_xcode_gen() {
  if [[ "$VERBOSITY" == "verbose" ]]; then
    xcodegen generate
    return
  fi
  local _log _rc=0
  _log=$(mktemp)
  xcodegen generate > "$_log" 2>&1 || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    cat "$_log" >&2
  fi
  rm -f "$_log"
  return $_rc
}

# Run xcodebuild with verbosity-filtered output.
# Captures exit code correctly even with set -e.
run_xcode_build() {
  if [[ "$VERBOSITY" == "verbose" ]]; then
    xcodebuild "$@"
    return
  fi
  local _log _rc=0
  _log=$(mktemp)
  xcodebuild "$@" > "$_log" 2>&1 || _rc=$?
  if [[ "$VERBOSITY" == "normal" ]]; then
    grep -E '(: warning:|: error:|\*\* BUILD )' "$_log" || true
  else  # quiet: warnings/errors to stderr
    grep -E '(: warning:|: error:)' "$_log" >&2 || true
    # Always show build failure in quiet mode
    if [[ $_rc -ne 0 ]]; then
      grep '\*\* BUILD FAILED \*\*' "$_log" >&2 || true
    fi
  fi
  rm -f "$_log"
  return $_rc
}

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

Options:
  --verbose   Show full xcodebuild output
  --quiet     Show only warnings and errors
EOF
  else
    cat <<EOF
Usage:
  ./gen_build_install.zsh --mac               Build & install to /Applications
  ./gen_build_install.zsh --build-check[=configs]
                                              Build-only check (no install)
                                              configs: comma-separated Debug,Release (default: Release)

Options:
  --verbose   Show full xcodebuild output
  --quiet     Show only warnings and errors
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

  log_info "==> xcodegen generate"
  run_xcode_gen

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

  log_info "==> Archiving $SCHEME (Release) for iOS ..."
  run_xcode_build -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive_path" \
    archive

  log_info "==> Exporting .ipa to $export_dir ..."
  run_xcode_build -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_opts"

  log_info "==> Archive: $archive_path"
  log_info "==> IPA:     $export_dir/$SCHEME.ipa"
  log_info ""
  log_info "次のステップ: Transporter.app または"
  log_info "  xcrun altool --upload-app -f $export_dir/$SCHEME.ipa -t ios -u <Apple ID> -p <app-specific-password>"
}

# ------------------------------------------------------------------
# macOS: Sign, notarize, staple, zip for distribution
# ------------------------------------------------------------------
release_macos() {
  local version="${1:-}"

  log_info "==> Verifying HEAD == origin/main ..."
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
  log_info "    HEAD: $local_head (matches origin/main, clean)"

  log_info "==> xcodegen generate"
  run_xcode_gen

  if [[ -z "$version" ]]; then
    version="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
      -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
      | grep -m1 ' MARKETING_VERSION' | awk '{print $3}')"
  fi
  log_info "==> Release version: $version"

  log_info "==> Building $SCHEME ($CONFIG) with Developer ID signing ..."
  run_xcode_build -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build

  local app_path
  app_path="$(resolve_app_path -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG")/$SCHEME.app"

  log_info "==> Verifying signature ..."
  codesign -dv --verbose=2 "$app_path" 2>&1 | grep -E '(Authority|TeamIdentifier|Identifier)' || true
  codesign --verify --strict --verbose=2 "$app_path"

  mkdir -p "$RELEASE_DIR"
  local notarize_zip="$RELEASE_DIR/$SCHEME-notarize-tmp.zip"
  local final_zip="$RELEASE_DIR/$SCHEME-$version.zip"

  log_info "==> Zipping for notarization ..."
  rm -f "$notarize_zip"
  /usr/bin/ditto -c -k --keepParent "$app_path" "$notarize_zip"

  log_info "==> Submitting to Apple notary service (profile: $NOTARY_PROFILE) ..."
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

  log_info "==> Stapling notary ticket to .app ..."
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"

  log_info "==> Creating final release zip ..."
  rm -f "$final_zip" "$notarize_zip"
  /usr/bin/ditto -c -k --keepParent "$app_path" "$final_zip"

  log_info ""
  log_info "==> Release ready: $final_zip"
  log_info "    Upload: gh release create v$version $final_zip --title 'v$version' --notes '...'"
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

    log_info "==> xcodegen generate"
    run_xcode_gen

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

      log_info "==> Build check: $SCHEME ($BC_CFG) ..."
      set +e
      run_xcode_build -project "$PROJECT" -scheme "$SCHEME" \
        -configuration "$BC_CFG" \
        "${BC_DEST_ARGS[@]}" \
        build
      BC_RC=$?
      set -e
      if [[ $BC_RC -eq 0 ]]; then
        log_info "==> $BC_CFG: BUILD SUCCEEDED"
      else
        echo "==> $BC_CFG: BUILD FAILED" >&2
        BC_FAILED=1
      fi
    done

    if [[ $BC_FAILED -ne 0 ]]; then
      echo "==> Build check FAILED" >&2
      exit 1
    fi
    log_info "==> All build checks passed!"
    exit 0
    ;;

  # ---- iOS: simulator ----------------------------------------------
  --sim|-s)
    [[ "$PLATFORM" != "ios" ]] && { echo "Error: --sim is only for iOS apps (set BUNDLE_ID in .build_config)" >&2; exit 1; }
    SIM_NAME="${2:-iPhone 17 Pro}"

    log_info "==> xcodegen generate"
    run_xcode_gen

    log_info "==> Building $SCHEME (Debug) for Simulator '$SIM_NAME' ..."
    run_xcode_build -project "$PROJECT" -scheme "$SCHEME" \
      -configuration Debug \
      -destination "platform=iOS Simulator,name=$SIM_NAME" \
      build

    APP_PATH="$(resolve_app_path \
      -project "$PROJECT" -scheme "$SCHEME" \
      -configuration Debug -destination "platform=iOS Simulator,name=$SIM_NAME")/$SCHEME.app"

    log_info "==> Booting Simulator '$SIM_NAME' ..."
    xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
    open -a Simulator

    log_info "==> Installing $APP_PATH"
    xcrun simctl install "$SIM_NAME" "$APP_PATH"

    log_info "==> Launching $SCHEME on Simulator ..."
    xcrun simctl launch "$SIM_NAME" "$BUNDLE_ID"

    log_info "==> Done!"
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

    log_info "==> xcodegen generate"
    run_xcode_gen

    log_info "==> Building $SCHEME ($CONFIG) ..."
    run_xcode_build -project "$PROJECT" -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      build

    APP_PATH="$(resolve_app_path \
      -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG")/$SCHEME.app"

    log_info "==> Installing $APP_PATH to /Applications ..."
    rm -rf "/Applications/$SCHEME.app"
    /usr/bin/ditto "$APP_PATH" "/Applications/$SCHEME.app"

    log_info "==> Done!"
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
log_info "==> Target device: $DEVICE_ID"

log_info "==> xcodegen generate"
run_xcode_gen

log_info "==> Building $SCHEME ($CONFIG) ..."
run_xcode_build -project "$PROJECT" -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "id=$DEVICE_ID" \
  build

APP_PATH="$(resolve_app_path \
  -project "$PROJECT" -scheme "$SCHEME" \
  -configuration "$CONFIG" -destination "id=$DEVICE_ID")/$SCHEME.app"

log_info "==> Installing $APP_PATH"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" \
  2>&1 | grep -v "Failed to load provisioning"

log_info "==> Done!"
