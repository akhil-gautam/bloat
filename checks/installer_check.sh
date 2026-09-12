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

mkdir -p "$FIXTURE/assets" "$FIXTURE/cli" "$FIXTURE/out-cli" "$FIXTURE/out-app" "$FIXTURE/test-applications" "$FIXTURE/bin"
printf '#!/bin/sh\necho fixture\n' > "$FIXTURE/cli/bloat"
chmod +x "$FIXTURE/cli/bloat"
CLI_NAME="bloat-v0.2.1-${PLATFORM}.tar.gz"
tar -czf "$FIXTURE/assets/$CLI_NAME" -C "$FIXTURE/cli" bloat
CLI_SHA="$(shasum -a 256 "$FIXTURE/assets/$CLI_NAME" | awk '{print $1}')"
printf '%s  %s\n' "$CLI_SHA" "$CLI_NAME" > "$FIXTURE/assets/checksums.txt"

APP_NAME="BloatMac-v1.1.1-macos.zip"
APP_FIXTURE="$FIXTURE/app/BloatMac.app"
mkdir -p "$APP_FIXTURE/Contents/MacOS"
cat > "$APP_FIXTURE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>BloatMac</string>
  <key>CFBundleIdentifier</key><string>akhilgautam123.bloatmac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.2</string>
</dict></plist>
EOF
printf 'int main(void) { return 0; }\n' | xcrun clang -arch "$ARCH" -x c - -o "$APP_FIXTURE/Contents/MacOS/BloatMac"
codesign --force --deep --sign - --options runtime "$APP_FIXTURE"
ditto -c -k --keepParent "$APP_FIXTURE" "$FIXTURE/assets/$APP_NAME"
APP_SHA="$(shasum -a 256 "$FIXTURE/assets/$APP_NAME" | awk '{print $1}')"
printf '%s  %s\n' "$APP_SHA" "$APP_NAME" > "$FIXTURE/assets/BloatMac-v1.1.1-checksums.txt"

cat > "$FIXTURE/releases.json" <<EOF
[
  {
    "tag_name": "bloatmac-v1.1.1",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "$APP_NAME", "browser_download_url": "file://$FIXTURE/assets/$APP_NAME"},
      {"name": "BloatMac-v1.1.1-checksums.txt", "browser_download_url": "file://$FIXTURE/assets/BloatMac-v1.1.1-checksums.txt"}
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

cat > "$FIXTURE/bin/spctl" <<'EOF'
#!/bin/sh
exit 3
EOF
chmod +x "$FIXTURE/bin/spctl"
PATH="$FIXTURE/bin:$PATH" \
  BLOAT_INSTALL_API_URL="file://$FIXTURE/releases.json" \
  BLOAT_INSTALL_TEST_APPLICATIONS_DIR="$FIXTURE/test-applications" \
  "$ROOT/install.sh" --app > "$FIXTURE/app-install.log" 2>&1
test -d "$FIXTURE/test-applications/BloatMac.app"
codesign --verify --deep --strict "$FIXTURE/test-applications/BloatMac.app"
grep -q "not approved by Gatekeeper" "$FIXTURE/app-install.log"
grep -q "Privacy & Security > Open Anyway" "$FIXTURE/app-install.log"

mkdir "$FIXTURE/wrong"
cp -R "$APP_FIXTURE" "$FIXTURE/wrong/BloatMac.app"
plutil -replace CFBundleIdentifier -string example.invalid "$FIXTURE/wrong/BloatMac.app/Contents/Info.plist"
codesign --force --deep --sign - "$FIXTURE/wrong/BloatMac.app"
ditto -c -k --keepParent "$FIXTURE/wrong/BloatMac.app" "$FIXTURE/assets/$APP_NAME"
APP_SHA="$(shasum -a 256 "$FIXTURE/assets/$APP_NAME" | awk '{print $1}')"
printf '%s  %s\n' "$APP_SHA" "$APP_NAME" > "$FIXTURE/assets/BloatMac-v1.1.1-checksums.txt"
if BLOAT_INSTALL_API_URL="file://$FIXTURE/releases.json" \
  BLOAT_INSTALL_TEST_APPLICATIONS_DIR="$FIXTURE/test-applications" \
  "$ROOT/install.sh" --app > "$FIXTURE/wrong-bundle.log" 2>&1; then
  echo "wrong bundle identifier unexpectedly succeeded" >&2
  exit 1
fi
grep -q "Unexpected BloatMac bundle identifier" "$FIXTURE/wrong-bundle.log"

mkdir "$FIXTURE/invalid"
cp -R "$APP_FIXTURE" "$FIXTURE/invalid/BloatMac.app"
printf '\0' >> "$FIXTURE/invalid/BloatMac.app/Contents/MacOS/BloatMac"
ditto -c -k --keepParent "$FIXTURE/invalid/BloatMac.app" "$FIXTURE/assets/$APP_NAME"
APP_SHA="$(shasum -a 256 "$FIXTURE/assets/$APP_NAME" | awk '{print $1}')"
printf '%s  %s\n' "$APP_SHA" "$APP_NAME" > "$FIXTURE/assets/BloatMac-v1.1.1-checksums.txt"
if BLOAT_INSTALL_API_URL="file://$FIXTURE/releases.json" \
  BLOAT_INSTALL_TEST_APPLICATIONS_DIR="$FIXTURE/test-applications" \
  "$ROOT/install.sh" --app > "$FIXTURE/invalid-signature.log" 2>&1; then
  echo "invalid app signature unexpectedly succeeded" >&2
  exit 1
fi
grep -q "code object is not signed at all\|a sealed resource is missing or invalid\|invalid signature\|main executable failed strict validation" "$FIXTURE/invalid-signature.log"

printf '%064d  %s\n' 0 "$CLI_NAME" > "$FIXTURE/assets/checksums.txt"
if BLOAT_INSTALL_API_URL="file://$FIXTURE/releases.json" \
  "$ROOT/install.sh" --download-only --output "$FIXTURE/out-bad" >"$FIXTURE/bad.log" 2>&1; then
  echo "corrupted checksum unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$FIXTURE/out-bad/$CLI_NAME"
grep -q "SHA-256 verification failed" "$FIXTURE/bad.log"

cat > "$FIXTURE/no-cli.json" <<EOF
[{"tag_name":"bloatmac-v1.1.1","draft":false,"prerelease":false,"assets":[]}]
EOF
if BLOAT_INSTALL_API_URL="file://$FIXTURE/no-cli.json" \
  "$ROOT/install.sh" --download-only --output "$FIXTURE/out-none" >"$FIXTURE/none.log" 2>&1; then
  echo "missing CLI release unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$FIXTURE/out-none/$CLI_NAME"
grep -q "Could not find a stable cli release" "$FIXTURE/none.log"

printf 'installer checks passed\n'
