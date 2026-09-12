#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/bloat-installer-check.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT INT TERM

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PLATFORM="macos-arm64" ;;
  x86_64) PLATFORM="macos-x86_64" ;;
  *) echo "unsupported fixture architecture: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$FIXTURE/assets" "$FIXTURE/cli" "$FIXTURE/out-cli" "$FIXTURE/out-app"
printf '#!/bin/sh\necho fixture\n' > "$FIXTURE/cli/bloat"
chmod +x "$FIXTURE/cli/bloat"
CLI_NAME="bloat-v0.2.1-${PLATFORM}.tar.gz"
tar -czf "$FIXTURE/assets/$CLI_NAME" -C "$FIXTURE/cli" bloat
CLI_SHA="$(shasum -a 256 "$FIXTURE/assets/$CLI_NAME" | awk '{print $1}')"
printf '%s  %s\n' "$CLI_SHA" "$CLI_NAME" > "$FIXTURE/assets/checksums.txt"

APP_NAME="BloatMac-v1.1.0-macos.zip"
printf 'fixture app archive\n' > "$FIXTURE/assets/$APP_NAME"
APP_SHA="$(shasum -a 256 "$FIXTURE/assets/$APP_NAME" | awk '{print $1}')"
printf '%s  %s\n' "$APP_SHA" "$APP_NAME" > "$FIXTURE/assets/BloatMac-v1.1.0-checksums.txt"

cat > "$FIXTURE/releases.json" <<EOF
[
  {
    "tag_name": "bloatmac-v1.1.0",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "$APP_NAME", "browser_download_url": "file://$FIXTURE/assets/$APP_NAME"},
      {"name": "BloatMac-v1.1.0-checksums.txt", "browser_download_url": "file://$FIXTURE/assets/BloatMac-v1.1.0-checksums.txt"}
    ]
  },
  {
    "tag_name": "v9.0.0-beta.1",
    "draft": false,
    "prerelease": true,
    "assets": []
  },
  {
    "tag_name": "v0.2.1",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "$CLI_NAME", "browser_download_url": "file://$FIXTURE/assets/$CLI_NAME"},
      {"name": "checksums.txt", "browser_download_url": "file://$FIXTURE/assets/checksums.txt"}
    ]
  }
]
EOF

BLOAT_INSTALL_API_URL="file://$FIXTURE/releases.json" \
  "$ROOT/install.sh" --download-only --output "$FIXTURE/out-cli"
test -f "$FIXTURE/out-cli/$CLI_NAME"
test ! -e "$FIXTURE/out-cli/$APP_NAME"

BLOAT_INSTALL_API_URL="file://$FIXTURE/releases.json" \
  "$ROOT/install.sh" --app --download-only --output "$FIXTURE/out-app"
test -f "$FIXTURE/out-app/$APP_NAME"
test ! -e "$FIXTURE/out-app/$CLI_NAME"

printf '%064d  %s\n' 0 "$CLI_NAME" > "$FIXTURE/assets/checksums.txt"
if BLOAT_INSTALL_API_URL="file://$FIXTURE/releases.json" \
  "$ROOT/install.sh" --download-only --output "$FIXTURE/out-bad" >"$FIXTURE/bad.log" 2>&1; then
  echo "corrupted checksum unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$FIXTURE/out-bad/$CLI_NAME"
grep -q "SHA-256 verification failed" "$FIXTURE/bad.log"

cat > "$FIXTURE/no-cli.json" <<EOF
[{"tag_name":"bloatmac-v1.1.0","draft":false,"prerelease":false,"assets":[]}]
EOF
if BLOAT_INSTALL_API_URL="file://$FIXTURE/no-cli.json" \
  "$ROOT/install.sh" --download-only --output "$FIXTURE/out-none" >"$FIXTURE/none.log" 2>&1; then
  echo "missing CLI release unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$FIXTURE/out-none/$CLI_NAME"
grep -q "Could not find a stable cli release" "$FIXTURE/none.log"

printf 'installer checks passed\n'
