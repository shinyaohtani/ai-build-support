#!/bin/bash
# Usage:
#   ./fetch_log.sh                       実機からデバッグログ取得
#   ./fetch_log.sh --sim                 起動中シミュレータ (booted) からデバッグログ取得
#   ./fetch_log.sh --backup-docs         実機の Documents をバックアップ
#   ./fetch_log.sh --restore-docs [PATH] バックアップから復元 (PATH省略時は最新)

set -e

# Read project config from .build_config in the calling project's root
CONFIG_FILE="${PWD}/.build_config"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: .build_config not found in ${PWD}" >&2
  exit 1
fi
. "$CONFIG_FILE"

# Validate required variables
if [ -z "${BUNDLE_ID:-}" ]; then
  echo "Error: BUNDLE_ID not set in .build_config" >&2
  exit 1
fi
if [ -z "${LOG_NAME:-}" ]; then
  echo "Error: LOG_NAME not set in .build_config" >&2
  exit 1
fi

DEVICE_NAME="${DEVICE_NAME:-iPhone 16 2024}"
BACKUP_ROOT="${BACKUP_ROOT:-backups}"

case "$1" in
  --backup-docs)
    TS=$(date +%Y%m%d-%H%M%S)
    BACKUP_DIR="${BACKUP_ROOT}/${TS}"
    mkdir -p "$BACKUP_DIR"

    echo "==> Backing up Documents/ from device..."
    xcrun devicectl device copy from \
      --device "$DEVICE_NAME" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" \
      --source Documents \
      --destination "$BACKUP_DIR/Documents"

    DOC_COUNT=$(find "$BACKUP_DIR/Documents" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "==> Backup complete: $BACKUP_DIR"
    echo "  Documents: $DOC_COUNT files"
    exit 0
    ;;

  --restore-docs)
    if [ -n "$2" ]; then
      BACKUP_DIR="$2"
    else
      BACKUP_DIR=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name '20??????-??????' 2>/dev/null | sort | tail -1)
    fi

    if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
      echo "No backup found. Run './fetch_log.sh --backup-docs' first."
      exit 1
    fi

    if [ ! -d "$BACKUP_DIR/Documents" ]; then
      echo "Documents backup not found: $BACKUP_DIR/Documents"
      exit 1
    fi

    echo "==> Restoring from: $BACKUP_DIR"
    echo "    Make sure the app is NOT running on the device (force quit first)."
    echo -n "    Continue? [y/N]: "
    read -r ANSWER
    if [ "$ANSWER" != "y" ] && [ "$ANSWER" != "Y" ]; then
      echo "Aborted."
      exit 1
    fi

    echo "==> Restoring Documents/ to device..."
    xcrun devicectl device copy to \
      --device "$DEVICE_NAME" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" \
      --source "$BACKUP_DIR/Documents" \
      --destination Documents

    echo "==> Restore complete."
    echo "    Launch the app on the device to verify."
    exit 0
    ;;

  --sim)
    # devicectl はシミュレータには使えないため simctl で取得する
    TMP=$(mktemp)
    CONTAINER=$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)
    if [ -z "$CONTAINER" ] || [ ! -d "$CONTAINER" ]; then
      echo "No booted simulator with $BUNDLE_ID installed"
      rm "$TMP"
      exit 1
    fi
    SRC="$CONTAINER/Documents/$LOG_NAME"
    if [ ! -f "$SRC" ]; then
      echo "Log not found: $SRC"
      rm "$TMP"
      exit 1
    fi
    cp "$SRC" "$TMP"
    ;;

  "")
    TMP=$(mktemp)
    xcrun devicectl device copy from \
      --device "$DEVICE_NAME" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" \
      --source "Documents/$LOG_NAME" \
      --destination "$TMP" 2>/dev/null
    ;;

  *)
    echo "Unknown option: $1"
    sed -n '2,6p' "$0"
    exit 1
    ;;
esac

# --- ログ取得モード共通の後処理 ---
SESSION=$(head -1 "$TMP" | sed 's/=== session \(.*\) ===/\1/')
if [ -z "$SESSION" ]; then
  echo "No session found"
  rm "$TMP"
  exit 1
fi

mkdir -p logs/debug
DEST="logs/debug/${SESSION}.log"
mv "$TMP" "$DEST"
echo "$DEST ($(wc -l < "$DEST") lines)"
