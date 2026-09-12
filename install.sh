#!/bin/bash
set -euo pipefail

REPO="akhil-gautam/bloat"
API_URL="${BLOAT_INSTALL_API_URL:-https://api.github.com/repos/$REPO/releases?per_page=100}"
MODE=cli
DOWNLOAD_ONLY=0
OUTPUT_DIR=

die() { echo "Error: $*" >&2; exit 1; }
usage() {
  echo "Usage: install.sh [--app] [--download-only] [--output DIRECTORY]"
  echo "Defaults to the latest stable bloat CLI; --app selects BloatMac."
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) MODE=app ;;
    --download-only) DOWNLOAD_ONLY=1 ;;
    --output) shift; [ "$#" -gt 0 ] || die "--output requires a directory"; OUTPUT_DIR="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = Darwin ] || die "bloat supports macOS only"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PLATFORM=macos-arm64 ;;
  x86_64) PLATFORM=macos-x86_64 ;;
  *) die "Unsupported Mac architecture: $ARCH" ;;
esac
version_ge() {
  awk -F. -v a="$1" -v b="$2" 'BEGIN {
    split(a,x,"."); split(b,y,".")
    for(i=1;i<=3;i++){x[i]+=0;y[i]+=0;if(x[i]>y[i])exit 0;if(x[i]<y[i])exit 1}
    exit 0
  }'
}
if [ "$MODE" = app ]; then
  HOST_VERSION="$(sw_vers -productVersion)"
  version_ge "$HOST_VERSION" 26.2 || die "BloatMac requires macOS 26.2 or later (found $HOST_VERSION)"
fi

WORK_DIR="$(mktemp -d /tmp/bloat-install.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
RELEASES="$WORK_DIR/releases.json"
curl -fsSL --retry 3 "$API_URL" -o "$RELEASES"

matches_mode() {
  case "$MODE:$1" in cli:v[0-9]*|app:bloatmac-v[0-9]*) return 0;; *) return 1;; esac
}
RELEASE_INDEX= TAG=
i=0
while [ "$i" -lt 100 ]; do
  tag="$(plutil -extract "$i.tag_name" raw -o - "$RELEASES" 2>/dev/null)" || break
  draft="$(plutil -extract "$i.draft" raw -o - "$RELEASES" 2>/dev/null || echo true)"
  pre="$(plutil -extract "$i.prerelease" raw -o - "$RELEASES" 2>/dev/null || echo true)"
  if [ "$draft" = false ] && [ "$pre" = false ] && matches_mode "$tag"; then
    RELEASE_INDEX="$i"; TAG="$tag"; break
  fi
  i=$((i + 1))
done
[ -n "$TAG" ] || die "Could not find a stable $MODE release"

if [ "$MODE" = cli ]; then
  ARCHIVE="bloat-$TAG-$PLATFORM.tar.gz"; SUMS=checksums.txt
else
  VERSION="${TAG#bloatmac-}"
  ARCHIVE="BloatMac-$VERSION-macos.zip"; SUMS="BloatMac-$VERSION-checksums.txt"
fi
asset_url() {
  local wanted="$1" n=0 name
  while [ "$n" -lt 100 ]; do
    name="$(plutil -extract "$RELEASE_INDEX.assets.$n.name" raw -o - "$RELEASES" 2>/dev/null)" || break
    if [ "$name" = "$wanted" ]; then
      plutil -extract "$RELEASE_INDEX.assets.$n.browser_download_url" raw -o - "$RELEASES" 2>/dev/null
      return
    fi
    n=$((n + 1))
  done
  return 1
}
ARCHIVE_URL="$(asset_url "$ARCHIVE")" || die "$TAG is missing $ARCHIVE"
SUMS_URL="$(asset_url "$SUMS")" || die "$TAG is missing $SUMS"
curl -fsSL --retry 3 "$ARCHIVE_URL" -o "$WORK_DIR/$ARCHIVE"
curl -fsSL --retry 3 "$SUMS_URL" -o "$WORK_DIR/$SUMS"
EXPECTED="$(awk -v f="$ARCHIVE" '$2==f||$2=="*"f{print $1;exit}' "$WORK_DIR/$SUMS")"
case "$EXPECTED" in ""|*[!0-9a-fA-F]*) die "No valid SHA-256 for $ARCHIVE";; esac
[ "${#EXPECTED}" -eq 64 ] || die "Invalid SHA-256 for $ARCHIVE"
ACTUAL="$(shasum -a 256 "$WORK_DIR/$ARCHIVE" | awk '{print $1}')"
[ "$(echo "$ACTUAL" | tr A-F a-f)" = "$(echo "$EXPECTED" | tr A-F a-f)" ] || die "SHA-256 verification failed"
echo "Selected $TAG; verified SHA-256 $ACTUAL"

if [ "$DOWNLOAD_ONLY" -eq 1 ]; then
  [ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="$(mktemp -d /tmp/bloat-download.XXXXXX)"
  mkdir -p "$OUTPUT_DIR"
  cp "$WORK_DIR/$ARCHIVE" "$OUTPUT_DIR/$ARCHIVE"
  cp "$WORK_DIR/$SUMS" "$OUTPUT_DIR/$SUMS"
  echo "Saved verified release to $OUTPUT_DIR/$ARCHIVE"
  exit
fi

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
has_arch() { lipo -archs "$1" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$ARCH"; }

if [ "$MODE" = cli ]; then
  mkdir "$WORK_DIR/extract"
  tar -xzf "$WORK_DIR/$ARCHIVE" -C "$WORK_DIR/extract"
  BIN="$WORK_DIR/extract/bloat"
  [ -x "$BIN" ] || die "Archive does not contain an executable bloat binary"
  has_arch "$BIN" || die "Downloaded CLI does not support $ARCH"
  as_root mkdir -p /usr/local/bin
  STAGE="/usr/local/bin/.bloat.install.$$"
  as_root install -m 0755 "$BIN" "$STAGE"
  as_root mv -f "$STAGE" /usr/local/bin/bloat || { as_root rm -f "$STAGE"; die "Install failed; existing bloat was preserved"; }
  echo "bloat $TAG installed at /usr/local/bin/bloat"
  exit
fi

mkdir "$WORK_DIR/extract"
ditto -x -k "$WORK_DIR/$ARCHIVE" "$WORK_DIR/extract"
APP="$WORK_DIR/extract/BloatMac.app"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || die "Archive does not contain BloatMac.app"
MIN="$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")"
version_ge "$MIN" 26.2 || die "Unexpected deployment target: $MIN"
version_ge "$HOST_VERSION" "$MIN" || die "BloatMac requires macOS $MIN"
EXE="$(plutil -extract CFBundleExecutable raw -o - "$PLIST")"
has_arch "$APP/Contents/MacOS/$EXE" || die "BloatMac does not support $ARCH"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
SIG="$(codesign --display --verbose=4 "$APP" 2>&1)"
echo "$SIG" | grep -Fxq "Identifier=akhilgautam123.bloatmac" || die "Unexpected BloatMac bundle identifier"
echo "$SIG" | grep -Fxq "TeamIdentifier=NCLSWS8Y8K" || die "Unexpected Developer ID team"

DEST=/Applications/BloatMac.app
STAGE="/Applications/.BloatMac.install.$$"
BACKUP="/Applications/.BloatMac.backup.$$"
[ ! -e "$STAGE" ] && [ ! -e "$BACKUP" ] || die "Temporary install path exists; retry"
as_root ditto "$APP" "$STAGE"
as_root codesign --verify --deep --strict "$STAGE" || { as_root rm -rf "$STAGE"; die "Staged signature check failed"; }
[ ! -e "$DEST" ] || as_root mv "$DEST" "$BACKUP"
if ! as_root mv "$STAGE" "$DEST"; then
  [ ! -e "$BACKUP" ] || as_root mv "$BACKUP" "$DEST"
  die "Install failed; the previous app was restored"
fi
[ ! -e "$BACKUP" ] || as_root rm -rf "$BACKUP"
echo "BloatMac $TAG installed at $DEST"
