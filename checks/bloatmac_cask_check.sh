#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/bloatmac-cask-check.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT INT TERM

ruby -c "$ROOT/Casks/bloatmac.rb"
[ "$(grep -c '^  caveats <<~EOS$' "$ROOT/Casks/bloatmac.rb")" -eq 1 ]
grep -Fq 'System Settings > Privacy & Security' "$ROOT/Casks/bloatmac.rb"
grep -Fq 'click Open Anyway' "$ROOT/Casks/bloatmac.rb"

mkdir -p "$FIXTURE/tap/Casks"
sed '/^  caveats <<~EOS$/,/^  EOS$/d' "$ROOT/Casks/bloatmac.rb" > "$FIXTURE/tap/Casks/bloatmac.rb"
git -C "$FIXTURE/tap" init -q
git -C "$FIXTURE/tap" add Casks/bloatmac.rb
git -C "$FIXTURE/tap" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture

ruby -ryaml -e '
  steps = YAML.load_file(ARGV[0], aliases: true).fetch("jobs").fetch("bump").fetch("steps")
  print steps.find { |step| step["name"] == "Update cask file" }.fetch("run")
' "$ROOT/.github/workflows/bump-homebrew-bloatmac.yml" > "$FIXTURE/update.sh"

for _ in 1 2; do
  (cd "$FIXTURE/tap" && VERSION=9.8.7 SHA256="$(printf 'a%.0s' {1..64})" bash "$FIXTURE/update.sh")
done

CASK="$FIXTURE/tap/Casks/bloatmac.rb"
ruby -c "$CASK"
grep -Fxq '  version "9.8.7"' "$CASK"
grep -Fxq "  sha256 \"$(printf 'a%.0s' {1..64})\"" "$CASK"
[ "$(grep -c '^  caveats <<~EOS$' "$CASK")" -eq 1 ]
grep -Fq 'System Settings > Privacy & Security' "$CASK"
grep -Fq 'click Open Anyway' "$CASK"

printf 'BloatMac cask checks passed\n'
