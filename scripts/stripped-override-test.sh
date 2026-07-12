#!/usr/bin/env bash
#
# Regression test for the stripped-binary override bug (fixed in 0.6.0).
#
# Regular test targets are never symbol-stripped, so they can't reproduce the
# archive-time environment in which "\(keyPath)" degrades to
# "<computed 0x… (Type)>" and (on Forge <= 0.5.1) KeyPath overrides were stored
# under a key that could never match. This script builds the repro executable in
# release, strips it the way an archive/install action would, runs it, and
# requires it to exit 0.
#
# macOS only — the KeyPath description behavior under test is a Darwin behavior.

set -euo pipefail

REPRO_DIR="$(cd "$(dirname "$0")/../IntegrationTests/StrippedOverrideRepro" && pwd)"
cd "$REPRO_DIR"

echo "==> Building StrippedOverrideRepro (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/StrippedOverrideRepro"

echo "==> Stripping $BIN"
strip "$BIN"

# Sanity-check the environment actually degrades KeyPath descriptions. If a
# toolchain change makes stripped descriptions readable again, the original
# failure mode can no longer occur there — warn (don't fail) so the weakened
# coverage is visible in CI logs.
echo "==> Verifying stripped KeyPath description is degraded"
DESCRIPTION="$("$BIN" --describe-keypath)"
echo "    stripped description: $DESCRIPTION"
if [[ "$DESCRIPTION" != *"<computed"* ]]; then
    echo "WARNING: stripped KeyPath description is not degraded on this toolchain;"
    echo "         this run does not exercise the original failure mode."
fi

echo "==> Running stripped binary"
"$BIN"

echo "==> Stripped-override regression test passed"
