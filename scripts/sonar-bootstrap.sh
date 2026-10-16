#!/usr/bin/env bash
# Starts from SonarQube's one-time admin credential, provisions isolated projects and issues
# project-scoped analysis tokens. Tokens are masked and passed only to later steps in this job.
set -euo pipefail

require_env() {
  [[ -n "${!1:-}" ]] || {
    printf 'error: %s is required\n' "$1" >&2
    exit 1
  }
}

require_env SONAR_HOST_URL
require_env SONAR_PROJECT_KEY
require_env SONAR_FIXTURE_PROJECT
require_env GITHUB_ENV

command -v curl >/dev/null 2>&1 || { echo 'error: curl is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo 'error: openssl is required' >&2; exit 1; }

host="${SONAR_HOST_URL%/}"
admin_password="$(openssl rand -hex 32)"
ready=0

for attempt in $(seq 1 180); do
  if body="$(curl --connect-timeout 3 --max-time 5 -fsS "$host/api/system/status" 2>/dev/null)" \
    && [[ "$(jq -r '.status // empty' <<<"$body")" == UP ]]; then
    ready=1
    break
  fi
  sleep 5
done
((ready == 1)) || { echo 'error: SonarQube did not become ready within 15 minutes' >&2; exit 1; }

# Community Build initializes with admin/admin. Rotate that credential immediately; the generated
# replacement is never written to the job environment or logs.
bootstrap_user=admin
bootstrap_password=admin
curl --connect-timeout 5 --max-time 20 -fsS -u "$bootstrap_user:$bootstrap_password" -X POST \
  --data-urlencode 'login=admin' \
  --data-urlencode 'previousPassword=admin' \
  --data-urlencode "password=$admin_password" \
  "$host/api/users/change_password" >/dev/null
unset bootstrap_user bootstrap_password

admin_payload="$(curl --connect-timeout 5 --max-time 20 -fsS -u "admin:$admin_password" -X POST \
  --data-urlencode 'name=ci-administration-bootstrap' \
  --data-urlencode 'type=USER_TOKEN' \
  "$host/api/user_tokens/generate")"
admin_token="$(jq -er '.token | select(type == "string" and length >= 20)' <<<"$admin_payload")"
unset admin_password admin_payload

printf '::add-mask::%s\n' "$admin_token"

api_post() {
  local path="$1"
  shift
  curl --connect-timeout 5 --max-time 20 -fsS -H "Authorization: Bearer $admin_token" \
    -X POST "$@" "$host$path"
}

create_project() {
  local key="$1" name="$2" token_name="$3" project_token
  api_post /api/projects/create --data-urlencode "project=$key" --data-urlencode "name=$name" >/dev/null
  project_token="$(api_post /api/user_tokens/generate \
    --data-urlencode "name=$token_name" \
    --data-urlencode 'type=PROJECT_ANALYSIS_TOKEN' \
    --data-urlencode "projectKey=$key" | jq -er '.token | select(type == "string" and length >= 20)')"
  printf '::add-mask::%s\n' "$project_token"
  printf '%s' "$project_token"
}

suffix="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
main_token="$(create_project "$SONAR_PROJECT_KEY" "$SONAR_PROJECT_KEY" "ci-$suffix-main")"
fixture_token="$(create_project "$SONAR_FIXTURE_PROJECT" "$SONAR_FIXTURE_PROJECT" "ci-$suffix-fixture")"

{
  printf 'SONAR_ADMIN_TOKEN=%s\n' "$admin_token"
  printf 'SONAR_TOKEN=%s\n' "$main_token"
  printf 'SONAR_FIXTURE_TOKEN=%s\n' "$fixture_token"
} >>"$GITHUB_ENV"

unset admin_token main_token fixture_token
echo 'SonarQube projects and project-scoped analysis tokens are ready.'
