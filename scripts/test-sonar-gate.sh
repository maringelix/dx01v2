#!/usr/bin/env bash
# Negative integration test: submit a new, deliberately uncovered fixture and prove the
# Community Build Quality Gate rejected that exact analysis for its new-code coverage condition.
set -euo pipefail

require_env() {
  [[ -n "${!1:-}" ]] || {
    printf 'error: %s is required\n' "$1" >&2
    exit 1
  }
}

require_env SONAR_HOST_URL
require_env SONAR_ADMIN_TOKEN
require_env SONAR_FIXTURE_TOKEN
require_env SONAR_FIXTURE_PROJECT
require_env SONAR_FIXTURE_SOURCE
require_env SONAR_SCANNER
require_env RUNNER_TEMP

command -v curl >/dev/null 2>&1 || { echo 'error: curl is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
command -v grep >/dev/null 2>&1 || { echo 'error: grep is required' >&2; exit 1; }
command -v sed >/dev/null 2>&1 || { echo 'error: sed is required' >&2; exit 1; }
command -v head >/dev/null 2>&1 || { echo 'error: head is required' >&2; exit 1; }
command -v sleep >/dev/null 2>&1 || { echo 'error: sleep is required' >&2; exit 1; }
command -v seq >/dev/null 2>&1 || { echo 'error: seq is required' >&2; exit 1; }

[[ -x "$SONAR_SCANNER" ]] || { echo 'error: installed SonarScanner CLI is not executable' >&2; exit 1; }
[[ -s "$SONAR_FIXTURE_SOURCE/fixture.lcov" ]] || { echo 'error: the uncovered fixture has no LCOV report' >&2; exit 1; }
"$SONAR_SCANNER" --version | grep -Fq '8.1.0.6389' || {
  echo 'error: the cached SonarScanner version does not match the pinned version' >&2
  exit 1
}

host="${SONAR_HOST_URL%/}"
metadata="$RUNNER_TEMP/sonar-fixture-report-task.txt"
scan_log="$RUNNER_TEMP/sonar-fixture-scan.log"
rm -f "$metadata" "$scan_log"

set +e
(
  cd "$SONAR_FIXTURE_SOURCE"
  SONAR_HOST_URL="$host" SONAR_TOKEN="$SONAR_FIXTURE_TOKEN" "$SONAR_SCANNER" \
    -Dsonar.projectKey="$SONAR_FIXTURE_PROJECT" \
    -Dsonar.projectName="$SONAR_FIXTURE_PROJECT" \
    -Dsonar.sources=. \
    -Dsonar.javascript.lcov.reportPaths=fixture.lcov \
    -Dsonar.qualitygate.wait=true \
    -Dsonar.qualitygate.timeout=300 \
    -Dsonar.scanner.metadataFilePath="$metadata"
) >"$scan_log" 2>&1
scan_status=$?
set -e

if ((scan_status == 0)); then
  echo 'error: the intentionally uncovered fixture unexpectedly passed the SonarQube Quality Gate' >&2
  exit 1
fi
[[ -s "$metadata" ]] || {
  echo 'error: scanner failed before uploading an analysis; this does not prove a Quality Gate rejection' >&2
  cat "$scan_log" >&2
  exit 1
}

analysis_id="$(sed -n 's/^ceTaskId=//p' "$metadata" | head -n 1)"
[[ "$analysis_id" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo 'error: scanner metadata has no valid Compute Engine task id' >&2
  exit 1
}

# Wait for Compute Engine to finish, then query that specific analysis (never a stale project status).
for ((attempt = 1; attempt <= 60; attempt += 1)); do
  status_json="$(curl --connect-timeout 5 --max-time 20 -fsS \
    -H "Authorization: Bearer $SONAR_ADMIN_TOKEN" \
    --get --data-urlencode "analysisId=$analysis_id" \
    "$host/api/qualitygates/project_status")" || {
      sleep 5
      continue
    }
  gate_status="$(jq -r '.projectStatus.status // empty' <<<"$status_json")"
  [[ -n "$gate_status" ]] && break
  sleep 5
done

[[ "${gate_status:-}" == ERROR ]] || {
  echo "error: expected Quality Gate ERROR for fixture analysis, got '${gate_status:-missing}'" >&2
  cat "$scan_log" >&2
  exit 1
}
jq -e '.projectStatus.conditions | any(.metricKey == "new_coverage" and .status == "ERROR")' \
  <<<"$status_json" >/dev/null || {
    echo 'error: fixture gate failed for a reason other than insufficient new-code coverage' >&2
    jq -c '.projectStatus.conditions' <<<"$status_json" >&2
    exit 1
  }

echo 'PASS: SonarQube rejected the exact fixture analysis because new-code coverage was below the gate.'
