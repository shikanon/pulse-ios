#!/usr/bin/env bash
set -euo pipefail

for command_name in curl node mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

for variable_name in PULSE_APPLE_TEAM_ID PULSE_IOS_BUNDLE_ID PULSE_UNIVERSAL_LINK_HOST; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Missing required environment variable: $variable_name" >&2
    exit 1
  fi
done

team_id=${PULSE_APPLE_TEAM_ID}
bundle_id=${PULSE_IOS_BUNDLE_ID}
host=${PULSE_UNIVERSAL_LINK_HOST,,}

[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || {
  echo "PULSE_APPLE_TEAM_ID must be the 10-character uppercase Apple Team ID." >&2
  exit 1
}
[[ "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || {
  echo "PULSE_IOS_BUNDLE_ID must be a reverse-DNS bundle identifier." >&2
  exit 1
}
[[ "$host" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] && [[ "$host" != *..* ]] && [[ "$host" != *.example ]] && [[ "$host" != *.invalid ]] && [[ "$host" != "localhost" ]] || {
  echo "PULSE_UNIVERSAL_LINK_HOST must be one public host, without a scheme, port, path, or placeholder suffix." >&2
  exit 1
}

verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/pulse-aasa.XXXXXX")
headers_path="$verification_dir/headers"
body_path="$verification_dir/apple-app-site-association"

cleanup() {
  rm -rf "$verification_dir"
}
trap cleanup EXIT

url="https://${host}/.well-known/apple-app-site-association"
curl --fail --silent --show-error --max-redirs 0 --connect-timeout 10 --max-time 20 \
  --dump-header "$headers_path" --output "$body_path" "$url"

status_code=$(awk 'toupper($1) ~ /^HTTP\// { print $2; exit }' "$headers_path")
[[ "$status_code" == "200" ]] || {
  echo "AASA endpoint must return HTTP 200 without redirect; received ${status_code:-no HTTP status}." >&2
  exit 1
}
content_type=$(awk -F: 'tolower($1) == "content-type" { value=$2; sub(/^[[:space:]]+/, "", value); print tolower(value); exit }' "$headers_path" | tr -d '\r')
[[ "$content_type" == application/json* ]] || {
  echo "AASA endpoint must return application/json; received ${content_type:-no Content-Type}." >&2
  exit 1
}

node --input-type=module - "$body_path" "${team_id}.${bundle_id}" <<'NODE'
import { readFileSync } from 'node:fs'

const [bodyPath, expectedAppID] = process.argv.slice(2)
let payload
try {
  payload = JSON.parse(readFileSync(bodyPath, 'utf8'))
} catch {
  console.error('AASA response is not valid JSON.')
  process.exit(1)
}

const details = payload?.applinks?.details
if (!Array.isArray(details) || details.length !== 1) {
  console.error('AASA must contain exactly one applinks.details entry for this release.')
  process.exit(1)
}
const [detail] = details
const expectedPaths = ['/a/*', '/remix/*']
const paths = detail?.components?.map(component => component?.['/'])
if (
  !Array.isArray(detail?.appIDs) || detail.appIDs.length !== 1 || detail.appIDs[0] !== expectedAppID ||
  !Array.isArray(paths) || paths.length !== expectedPaths.length ||
  paths.some((path, index) => path !== expectedPaths[index])
) {
  console.error('AASA does not exactly match the released Pulse app identifier and /a/*, /remix/* routes.')
  process.exit(1)
}
NODE

echo "AASA deployment verified at $url for ${team_id}.${bundle_id}."
echo "Still run the signed-device Universal Link matrix: Apple serves associated-domain files through its CDN."
