#!/usr/bin/env bash
# Prove ZAP Baseline fails on the deliberately missing CSP header in the local fixture.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker curl node jq

REPORT_DIR="${ZAP_REPORT_DIR:-${TMPDIR:-/tmp}/dx01v2-dast}"
PORT="${ZAP_FIXTURE_PORT:-18081}"
ZAP_IMAGE='ghcr.io/zaproxy/zaproxy:2.17.0@sha256:5ccfff9a411743ab2615136a2edd7416bec9ce41572fa94e935df38c14adb2b6'
SERVER_LOG="$(mktemp "${TMPDIR:-/tmp}/dx01v2-zap-fixture.XXXXXX")"
server_pid=''

cleanup() {
  local rc=$?
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$SERVER_LOG"
  exit "$rc"
}
trap cleanup EXIT

[[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && ((PORT <= 65535)) || die "invalid ZAP_FIXTURE_PORT: $PORT"
mkdir -p "$REPORT_DIR"
chmod 0777 "$REPORT_DIR"
export ZAP_FIXTURE_PORT="$PORT"
node security/fixtures/dast/server.mjs >"$SERVER_LOG" 2>&1 &
server_pid=$!

ready=0
for attempt in $(seq 1 50); do
  if curl --connect-timeout 1 --max-time 2 -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null; then
    ready=1
    break
  fi
  sleep 0.2
done
((ready == 1)) || {
  cat "$SERVER_LOG" >&2
  die 'the local ZAP fixture did not become ready'
}

status=0
if docker run --rm --network host --shm-size=512m \
  --cap-drop ALL --security-opt no-new-privileges \
  --volume "$REPORT_DIR:/zap/wrk/:rw" \
  "$ZAP_IMAGE" zap-baseline.py \
  -t "http://127.0.0.1:$PORT" \
  -c /zap/wrk/zap.conf \
  -m 1 \
  -T 10 \
  -J /zap/wrk/zap-fixture.json; then
  status=0
else
  status=$?
fi

[[ "$status" == 1 ]] || die "ZAP did not fail at the expected alert threshold (exit $status)"
jq -e '[.site[].alerts[]? | select((.pluginid // .pluginId // .alertRef) == "10038")] | length > 0' \
  "$REPORT_DIR/zap-fixture.json" >/dev/null || die 'ZAP failed without reporting the expected CSP alert 10038'

echo 'PASS: ZAP Baseline rejected the deliberate CSP vulnerability (rule 10038).'
