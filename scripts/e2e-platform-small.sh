#!/usr/bin/env bash
# The platform e2e (scripts/e2e-platform.sh) on the small size of the tx01v2 platform (LOCAL_SIZE=small),
# inside a Docker daemon limited to SMALL_MEMORY of memory and no swap (Docker-in-Docker): the proof
# that the platform and this app fit in the Docker memory of a laptop (docs/LAB_LOCAL.md). Harness
# stage platform-small, CI job e2e-platform-small. It fails when the e2e fails or when any process
# inside was OOM-killed.
# HEAVY: it needs SMALL_MEMORY free on top of everything else the machine runs, and the inner daemon
# pulls every image of the lab again. It is meant for the CI runner (16 GB). On a 16 GB laptop that
# also runs an editor and a browser, do not run it: use e2e-platform with LOCAL_SIZE=small.
# Environment: SMALL_MEMORY (default 6g), E2E_SKIP_BUILD=1 (copies dx01v2-api:e2e and dx01v2-web:e2e
# from the outer Docker instead of building them inside), TX01V2_REPO (as in e2e-platform.sh),
# E2E_DIAGNOSTICS_DIR (default ${TMPDIR:-/tmp}/dx01v2-harness/platform-diagnostics).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# docker:29.9.0-dind (verified 2026-10-15).
DIND_IMAGE="docker:29.9.0-dind@sha256:0b6d18a4a222e71c88be6034926b4f6cde2fc33c2218643d03ccfddc65995470"
# What scripts/e2e-platform.sh and the install-tools.sh of both repositories need inside. Alpine keeps
# only the latest build of each package in a branch, so the versions follow the pinned base image.
PACKAGES=(bash curl git make unzip xz jq openssh-client nodejs coreutils findutils grep sed gawk tar procps)
MEMORY="${SMALL_MEMORY:-6g}"
NAME="dx01v2-small-$$"
DIAG_DIR="${E2E_DIAGNOSTICS_DIR:-${TMPDIR:-/tmp}/dx01v2-harness/platform-diagnostics}"

# -v: the anonymous volume of the inner /var/lib/docker holds every image of the lab (GBs).
cleanup() {
  docker rm -f -v "$NAME" >/dev/null 2>&1 || :
}

gib() {
  awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'
}

main() {
  local rc=0 i peak anon events hits oom summary
  require_cmd docker tar
  [[ "$MEMORY" =~ ^[0-9]+[mg]$ ]] || die "SMALL_MEMORY must look like 6g or 6144m (got '$MEMORY')"
  trap cleanup EXIT
  log "Docker-in-Docker $NAME limited to $MEMORY, no swap"
  docker run -d --privileged --name "$NAME" --memory "$MEMORY" --memory-swap "$MEMORY" "$DIND_IMAGE" >/dev/null
  for i in $(seq 1 60); do
    docker exec "$NAME" docker info >/dev/null 2>&1 && break
    ((i < 60)) && sleep 2
  done
  docker exec "$NAME" docker info >/dev/null 2>&1 || die "the inner Docker daemon did not start"
  docker exec "$NAME" apk add --no-cache "${PACKAGES[@]}" >/dev/null
  tar -C "$REPO_ROOT" --exclude=node_modules --exclude=./.tools -cf - . |
    docker exec -i "$NAME" sh -c 'mkdir -p /work/dx01v2 && tar -C /work/dx01v2 -xf -'
  if [[ "${E2E_SKIP_BUILD:-0}" == 1 ]]; then
    log "copying dx01v2-api:e2e and dx01v2-web:e2e into the inner Docker"
    docker save dx01v2-api:e2e dx01v2-web:e2e | docker exec -i "$NAME" docker load >/dev/null
  fi
  # memory.peak counts the page cache, which fills any limit. Without swap the anonymous memory cannot
  # be reclaimed, so its peak (sampled every 5 s) is what the platform needs.
  # shellcheck disable=SC2016 # expanded by the shell inside the container
  docker exec -d "$NAME" sh -c 'max=0; while sleep 5; do
    a=$(sed -n "s/^anon //p" /sys/fs/cgroup/memory.stat)
    if [ "$a" -gt "$max" ]; then max=$a; echo "$max" >/work/anon.max; fi; done'
  docker exec -e LOCAL_SIZE=small -e E2E_SKIP_BUILD="${E2E_SKIP_BUILD:-0}" -e TX01V2_REPO="${TX01V2_REPO:-}" \
    -e E2E_DIAGNOSTICS_DIR=/work/diagnostics "$NAME" bash -c 'cd /work/dx01v2 &&
      git config --global --add safe.directory "*" &&
      bash scripts/install-tools.sh kubectl >/dev/null && bash scripts/e2e-platform.sh' || rc=$?
  peak="$(docker exec "$NAME" cat /sys/fs/cgroup/memory.peak 2>/dev/null)" || peak=0
  anon="$(docker exec "$NAME" cat /work/anon.max 2>/dev/null)" || anon=0
  events="$(docker exec "$NAME" cat /sys/fs/cgroup/memory.events 2>/dev/null)" || events=""
  hits="$(awk '$1 == "max" { print $2 }' <<<"$events")"
  oom="$(awk '$1 == "oom_kill" { print $2 }' <<<"$events")"
  summary="Docker limited to $MEMORY: peak $(gib "$peak") (anonymous $(gib "$anon")), limit reached ${hits:-?} times, OOM kills ${oom:-?}"
  printf 'SUMMARY: %s\n' "$summary"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Platform e2e, size small\n\n%s; e2e exit code %s\n' "$summary" "$rc" >>"$GITHUB_STEP_SUMMARY"
  fi
  if ((rc == 0)) && [[ "$oom" != 0 ]]; then
    log "error: OOM kills inside the Docker daemon (${oom:-unknown}): the platform does not fit in $MEMORY"
    rc=1
  fi
  if ((rc != 0)); then
    mkdir -p "$DIAG_DIR"
    docker cp "$NAME:/work/diagnostics/." "$DIAG_DIR/" >/dev/null 2>&1 || :
    printf '%s\n' "$events" >"$DIAG_DIR/memory.events"
    docker exec "$NAME" dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' >"$DIAG_DIR/oom-kills.txt" || :
    log "diagnostics: $DIAG_DIR"
  fi
  return "$rc"
}

main "$@"
