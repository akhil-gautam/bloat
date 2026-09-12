#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/bloatmac-checks.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

check() {
    name=$1
    shift
    xcrun swiftc -module-cache-path "$scratch/modules" -default-isolation MainActor \
        -warnings-as-errors "$@" -o "$scratch/$name"
    "$scratch/$name"
}

check search "$root/bloatmac/Models/SearchEntry.swift" "$root/Checks/SearchChecks.swift"
check intelligence -D INTELLIGENCE_POLICY_CHECK "$root/bloatmac/Models/IntelligencePolicy.swift" "$root/Checks/IntelligencePolicyCheck.swift"
check cleanup "$root/bloatmac/Models/CleanupSafety.swift" "$root/Checks/cleanup_safety_check.swift"
check system "$root/bloatmac/Models/SystemStatusPolicy.swift" "$root/Checks/SystemStatusPolicyCheck.swift"
check battery "$root/bloatmac/Models/BatteryForecastPolicy.swift" "$root/Checks/BatteryForecastPolicyCheck.swift"
