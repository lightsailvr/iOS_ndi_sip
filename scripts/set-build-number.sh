#!/usr/bin/env bash
# Set the iOS build number to the git commit count (PRD: build = git commit count).
#
# Usage:
#   scripts/set-build-number.sh
#
# Run this on macOS before `xcodebuild archive`. It uses Apple's `agvtool`,
# which rewrites CURRENT_PROJECT_VERSION in the project's pbxproj.
#
# Marketing version (CFBundleShortVersionString) is bumped manually via
# `agvtool new-marketing-version 1.0.1` (or by editing MARKETING_VERSION in
# the pbxproj directly).

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v git >/dev/null; then
  echo "git not found" >&2
  exit 1
fi

if ! command -v agvtool >/dev/null; then
  echo "agvtool not found — this script requires macOS + Xcode command line tools" >&2
  echo "Install with: xcode-select --install" >&2
  exit 1
fi

count="$(git rev-list --count HEAD)"
short="$(git rev-parse --short HEAD)"

cd stereondi
agvtool new-version -all "$count" >/dev/null

echo "CURRENT_PROJECT_VERSION = $count   (git $short)"
