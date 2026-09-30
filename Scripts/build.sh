#!/usr/bin/env bash
#
# build.sh — compile the MacPerfMonitor binary with Swift Package Manager.
#
# This is an Apple Silicon (arm64) only project: we build for the host arch and
# never produce a universal or x86_64 binary.
#
# Release by default. Flags:
#   --debug      faster, unoptimised build
#   --release    optimised build (default)
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
for arg in "$@"; do
  case "$arg" in
    --debug)     CONFIG="debug" ;;
    --release)   CONFIG="release" ;;
    --universal)
      echo "build.sh: --universal is not supported; this is an Apple Silicon (arm64) only project." >&2
      exit 2 ;;
    *) echo "build.sh: ignoring unknown argument '$arg'" >&2 ;;
  esac
done

# The Swift Build engine (SwiftPM's default since Xcode 27) stamps the deployment
# target into LC_BUILD_VERSION as the SDK version (sdk 15.0). macOS keys Liquid
# Glass and other new-SDK behaviour on that field, so 2.2.0 shipped with the
# legacy look (#117). Pass the real SDK version to the linker explicitly.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
LINK_SDK=(-Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$SDK_VERSION")

echo "Building MacPerfMonitor ($CONFIG, arm64, SDK $SDK_VERSION)..."
swift build -c "$CONFIG" "${LINK_SDK[@]}" --product MacPerfMonitor
# The privileged helper is a separate executable product (the app does not
# depend on it), so it must be built explicitly to be bundled alongside the app.
swift build -c "$CONFIG" "${LINK_SDK[@]}" --product MacPerfMonitorHelper
# `mpm`, the read-only command-line tool and MCP server for AI agents.
swift build -c "$CONFIG" "${LINK_SDK[@]}" --product mpm

BIN="$(swift build --show-bin-path -c "$CONFIG")/MacPerfMonitor"
echo "Built: $BIN"
