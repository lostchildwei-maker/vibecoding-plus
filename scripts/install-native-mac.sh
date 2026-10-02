#!/usr/bin/env bash
# Publish the local custom build at a stable macOS application path.
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
SRC="${1:-$ROOT_DIR/dist-native/VibeCoding Plus.app}"
DEST="/Applications/VibeCoding Plus.app"
BACKUP_ROOT="$WORKSPACE_DIR/backups/vibecoding-plus"
CONFIG_DIR="$HOME/Library/Application Support/vibecoding-plus"
LOCK="/Applications/.vibecoding-plus-install.lock"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ $# -gt 1 || ! -d "$SRC" ]]; then
  echo "Usage: bash scripts/install-native-mac.sh [path/to/VibeCoding Plus.app]" >&2
  echo "Build first with npm run native:dist:mac." >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd -P)"
if [[ "$SRC" == "$DEST" ]]; then
  echo "The installation source must differ from $DEST." >&2
  exit 1
fi
PLIST="$SRC/Contents/Info.plist"
SOURCE_BINARY="$SRC/Contents/MacOS/VibeCoding Plus"
if [[ ! -x "$SOURCE_BINARY" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" != "com.mac20777.vibecodingplus" ]]; then
  echo "This is not a valid VibeCoding Plus application." >&2
  exit 1
fi
codesign --verify --deep --strict "$SRC"
for resource in qwen_mlx_worker.py qwen_tts_mlx_worker.py local_tts_service.py; do
  if [[ ! -f "$SRC/Contents/Resources/$resource" ]]; then
    echo "The custom application is missing a required voice resource: $resource" >&2
    exit 1
  fi
done

# Existing builds share a public version number; also compare binary build times.
if [[ -f "$DEST/Contents/MacOS/VibeCoding Plus" && "$DEST/Contents/MacOS/VibeCoding Plus" -nt "$SOURCE_BINARY" ]]; then
  echo "Refusing to replace the installed app with an older build: $SRC" >&2
  exit 1
fi
if ! mkdir "$LOCK"; then
  echo "Another installation is in progress. Stop it before retrying." >&2
  exit 1
fi

STAGE_ROOT=""
REPLACED=0
HAD_APP=0
cleanup() {
  local result=$?
  trap - EXIT
  if [[ $result -ne 0 && $REPLACED -eq 1 ]]; then
    pkill -TERM -x 'VibeCoding Plus' 2>/dev/null || true
    rm -rf "$DEST"
    if [[ $HAD_APP -eq 1 ]]; then
      mv "$STAGE_ROOT/previous.app" "$DEST"
      "$LSREGISTER" -f "$DEST" || true
      /usr/bin/open "$DEST" || true
      echo "Installation failed; the previous app was restored." >&2
    fi
  fi
  if [[ -n "$STAGE_ROOT" ]]; then rm -rf "$STAGE_ROOT"; fi
  rmdir "$LOCK"
  exit "$result"
}
trap cleanup EXIT

# Check again while holding the lock so simultaneous installers cannot downgrade.
if [[ -f "$DEST/Contents/MacOS/VibeCoding Plus" && "$DEST/Contents/MacOS/VibeCoding Plus" -nt "$SOURCE_BINARY" ]]; then
  echo "Refusing to replace the installed app with an older build: $SRC" >&2
  exit 1
fi

STAGE_ROOT="$(mktemp -d '/Applications/.vibecoding-plus-stage.XXXXXX')"
ditto "$SRC" "$STAGE_ROOT/VibeCoding Plus.app"
codesign --verify --deep --strict "$STAGE_ROOT/VibeCoding Plus.app"

# Wait for this app to exit before snapshotting its saved configuration.
pkill -TERM -x 'VibeCoding Plus' 2>/dev/null || true
for attempt in {1..10}; do
  if ! pgrep -x 'VibeCoding Plus' >/dev/null; then break; fi
  sleep 1
done
if pgrep -x 'VibeCoding Plus' >/dev/null; then
  echo "The app did not exit; installation cancelled before replacement." >&2
  exit 1
fi

mkdir -p "$BACKUP_ROOT"
STAMP="$(TZ=Asia/Shanghai date '+%Y%m%d-%H%M%S')"
BACKUP_DIR="$(mktemp -d "$BACKUP_ROOT/$STAMP.XXXXXX")"
if [[ -d "$DEST" ]]; then
  ditto "$DEST" "$BACKUP_DIR/VibeCoding Plus.app"
  HAD_APP=1
else
  # Preserve a recovery baseline when there is no installed application yet.
  ditto "$SRC" "$BACKUP_DIR/VibeCoding Plus.app"
fi
if [[ -d "$CONFIG_DIR" ]]; then
  ditto "$CONFIG_DIR" "$BACKUP_DIR/Application Support"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUILD_TIME="$(TZ=Asia/Shanghai stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S %z' "$SOURCE_BINARY")"
cat > "$BACKUP_DIR/installation.txt" <<EOF
Installed source: $SRC
Destination: $DEST
New version: $VERSION ($BUILD)
New binary build time: $BUILD_TIME
Previous installed app existed: $HAD_APP
Backup time: $STAMP (Asia/Shanghai)
EOF

if [[ $HAD_APP -eq 1 ]]; then mv "$DEST" "$STAGE_ROOT/previous.app"; fi
REPLACED=1
mv "$STAGE_ROOT/VibeCoding Plus.app" "$DEST"
"$LSREGISTER" -f "$DEST"
/usr/bin/open "$DEST"
sleep 2
pgrep -x 'VibeCoding Plus' >/dev/null

echo "Installed and launched: $DEST"
echo "Version: $VERSION ($BUILD), built $BUILD_TIME"
echo "Backup: $BACKUP_DIR"
echo "If text injection needs authorization, add this fixed application path in System Settings → Privacy & Security → Accessibility."
