#!/usr/bin/env bash
#
# run.sh — build the probe via xcodebuild and execute it.
#
# We can't use `swift run` because mlx-swift needs the Metal toolchain
# to compile its shaders; SPM-CLI can't do that, xcodebuild can.

set -euo pipefail

cd "$(dirname "$0")"

DERIVED="$HOME/Library/Developer/Xcode/DerivedData/HTDemucsSwiftProbe-gxnhiypnumrdmhfajbxlrgfrrope/Build/Products/Debug/htdemucs-probe"

xcodebuild \
  -scheme htdemucs-probe \
  -destination 'platform=OS X' \
  -configuration Debug \
  build \
  -quiet

exec "$DERIVED" "$@"
