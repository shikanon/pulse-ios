#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
api_repo=${PULSE_API_REPO:-$(cd "$repo_dir/../pulse-api" && pwd)}
runtime_version=${PULSE_IOS_RUNTIME_VERSION:-26.5}
runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-${runtime_version//./-}"
api_port=18787
only_testing=${PULSE_ONLY_TESTING:-PulseUITests/CoreUserJourneyUITests}
result_dir=${PULSE_XCRESULT_DIR:-$repo_dir/.artifacts/core-user-journeys}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_bundle="$result_dir/CoreUserJourneys-$timestamp.xcresult"
api_log="$result_dir/pulse-api-$timestamp.log"
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/pulse-core-user-journeys.XXXXXX")
simulator_id=""
api_pid=""

terminate_process_tree() {
  local parent_pid="$1"
  local child_pid
  while IFS= read -r child_pid; do
    terminate_process_tree "$child_pid"
  done < <(pgrep -P "$parent_pid" || true)
  kill "$parent_pid" >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "$api_pid" ]]; then
    terminate_process_tree "$api_pid"
    wait "$api_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$simulator_id" ]]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$run_dir"
}
trap cleanup EXIT

for command_name in curl go lsof xcodebuild xcodegen xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

[[ -f "$api_repo/go.mod" ]] || {
  echo "Pulse Go API repository not found: $api_repo" >&2
  exit 1
}

if lsof -nP -iTCP:"$api_port" -sTCP:LISTEN >/dev/null; then
  echo "TCP port $api_port is already in use; stop the conflicting process before running the isolated core-user-journey gate." >&2
  exit 1
fi

xcrun simctl list runtimes | grep -Fq "iOS $runtime_version" || {
  echo "iOS $runtime_version Simulator Runtime is not installed." >&2
  exit 1
}

for device_type in \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro \
  com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro; do
  if simulator_id=$(xcrun simctl create "Pulse-Core-Journeys-$$" "$device_type" "$runtime_id" 2>/dev/null); then
    break
  fi
  simulator_id=""
done

[[ -n "$simulator_id" ]] || {
  echo "Unable to create an iPhone simulator for iOS $runtime_version." >&2
  exit 1
}

mkdir -p "$result_dir"
(
  cd "$api_repo"
  PORT="$api_port" \
    DATA_FILE="$run_dir/pulse.json" \
    GENERATION_STAGE_DELAY_MS=5 \
    PULSE_AGENT_MODE=deterministic-local \
    PULSE_ASSET_STORAGE_MODE=local-metadata \
    PULSE_OBJECT_STORAGE_ENV_FILE=disabled \
    PULSE_SUPPORT_URL="https://support.pulse.test/core-journeys" \
    go run ./cmd/pulse-api >"$api_log" 2>&1
) &
api_pid=$!

for _ in {1..120}; do
  if curl --fail --silent "http://127.0.0.1:$api_port/readyz" >/dev/null; then
    break
  fi
  if ! kill -0 "$api_pid" >/dev/null 2>&1; then
    echo "Pulse API stopped before becoming ready. See $api_log" >&2
    exit 1
  fi
  sleep 0.25
done
curl --fail --silent "http://127.0.0.1:$api_port/readyz" >/dev/null || {
  echo "Pulse API did not become ready. See $api_log" >&2
  exit 1
}

cd "$repo_dir"
xcodegen generate
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b

echo "Running core client journeys with local account pulse.e2e on iOS $runtime_version simulator $simulator_id"
set +e
xcodebuild \
  -project Pulse.xcodeproj \
  -scheme PulseGenerationE2E \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -configuration Debug \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  "-only-testing:$only_testing" \
  CODE_SIGNING_ALLOWED=NO \
  test
test_status=$?
set -e

xcrun xcresulttool get test-results summary --path "$result_bundle" || true
echo "Core-user-journey result bundle: $result_bundle"
echo "Pulse API log: $api_log"
exit "$test_status"
