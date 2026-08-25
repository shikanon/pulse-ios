#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
scheme=${PULSE_XCODE_SCHEME:-Pulse}
runtime_version=${PULSE_IOS_RUNTIME_VERSION:-26.5}
runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-${runtime_version//./-}"
result_dir=${PULSE_XCRESULT_DIR:-$repo_dir/.artifacts/xctest}
result_bundle="$result_dir/PulseTests-$(date -u +%Y%m%dT%H%M%SZ).xcresult"
simulator_id=""

cleanup() {
  if [[ -n "$simulator_id" ]]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for command_name in xcodebuild xcodegen xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

xcrun simctl list runtimes | grep -Fq "iOS $runtime_version" || {
  echo "iOS $runtime_version Simulator Runtime is not installed." >&2
  exit 1
}

for device_type in \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro \
  com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro; do
  if simulator_id=$(xcrun simctl create "Pulse-XCTest-$$" "$device_type" "$runtime_id" 2>/dev/null); then
    break
  fi
  simulator_id=""
done

if [[ -z "$simulator_id" ]]; then
  echo "Unable to create an iPhone simulator for iOS $runtime_version." >&2
  exit 1
fi

mkdir -p "$result_dir"
cd "$repo_dir"
xcodegen generate
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b

echo "Running $scheme XCTest on iOS $runtime_version simulator $simulator_id"
xcodebuild \
  -project Pulse.xcodeproj \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -configuration Debug \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test

xcrun xcresulttool get test-results summary --path "$result_bundle"
echo "XCTest passed. Result bundle: $result_bundle"
