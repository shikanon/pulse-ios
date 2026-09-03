#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "Gate 1/2: XCTest contracts, state, and safety behavior"
"$script_dir/run-xctest.sh"

echo "Gate 2/2: isolated core user journeys"
"$script_dir/run-core-user-journeys.sh"

echo "Pulse client quality gate passed: browse, generate, publish immediately, discover on Home, like, comment, and play journeys are usable."
