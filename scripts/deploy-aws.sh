#!/usr/bin/env bash
# Deploys dx01v2 to the EKS lab cluster of tx01v2 (contract v1, docs/CONTRATO.md).
# CLOUD-MUTATING and billable: pushes images to ECR and makes the AWS Load Balancer Controller
# create an internet-facing ALB. Run it only on purpose, after the tx01v2 apply + platform steps;
# the teardown is the tx01v2 destroy. Not run in the cloud yet (v2).
# Used by .github/workflows/deploy-aws.yml and from a laptop (docs/RUNBOOK.md):
#   AWS_REGION=us-east-1 scripts/deploy-aws.sh
# Environment:
#   AWS_REGION           required; must match the SSM parameter /tx01v2/lab/region
#   GIT_SHA              commit to deploy (default: HEAD, and the working tree must be clean)
#   ALB_CERTIFICATE_ARN  optional ACM certificate of the region: selects overlays/aws-https
#   SMOKE_BASE_URL       smoke test URL (default http://<ALB hostname>); required with HTTPS:
#                        https://<a DNS name of the certificate that points at the ALB>
#   SMOKE_WAIT_SECONDS   how long the smoke test waits for the ALB and its DNS name (default 900)
# Steps: SSM contract -> images (linux/amd64 build + push; skipped when the tag exists, ECR tags
# are immutable) -> kubeconfig -> ConfigMap rds-ca -> render + kubectl apply -k -> ExternalSecrets
# -> rollouts -> Ingress hostname -> smoke test through the ALB -> job summary (GitHub Actions).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

NAMESPACE=dx01v2
SSM_PREFIX=/tx01v2/lab
# Contract v1: every parameter the deploy reads (the harness check contract-app verifies this list).
SSM_NAMES=(
  "$SSM_PREFIX/region"
  "$SSM_PREFIX/cluster-name"
  "$SSM_PREFIX/vpc-id"
  "$SSM_PREFIX/vpc-cidr"
  "$SSM_PREFIX/ecr/api-url"
  "$SSM_PREFIX/ecr/web-url"
  "$SSM_PREFIX/waf/acl-arn"
  "$SSM_PREFIX/db/secret-name"
  "$SSM_PREFIX/app/admin-token-secret-name"
  "$SSM_PREFIX/eso/cluster-secret-store"
)
# Values hard-coded in deploy/k8s/components/aws: the copy published by tx01v2 must agree.
CONTRACT_CLUSTER=tx01v2-lab
CONTRACT_DB_SECRET=tx01v2-lab/db/app
CONTRACT_ADMIN_TOKEN_SECRET=tx01v2-lab/app/admin-token
CONTRACT_SECRET_STORE=aws-secrets-manager
ECR_URL_PATTERN='^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/dx01v2/'
RDS_CA_BASE_URL=https://truststore.pki.rds.amazonaws.com/
# The tx01v2 node group runs AL2023_x86_64_STANDARD.
IMAGE_PLATFORM=linux/amd64

declare -A PARAM=()
WORK_DIR=""
GROUP_OPEN=0
OVERLAY=aws
API_IMAGE=""
WEB_IMAGE=""
ALB_HOSTNAME=""
BASE=""

in_actions() { [[ "${GITHUB_ACTIONS:-}" == true ]]; }

section() {
  if in_actions; then
    ((GROUP_OPEN == 0)) || echo "::endgroup::"
    echo "::group::$*"
    GROUP_OPEN=1
  else
    log "== $*"
  fi
}

param() { printf '%s' "${PARAM[$SSM_PREFIX/$1]}"; }

expect_param() { # NAME VALUE
  [[ "$(param "$1")" == "$2" ]] || die "SSM $SSM_PREFIX/$1 is '$(param "$1")' but the manifests expect '$2' (contract v1)"
}

write_summary() { # RESULT
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "## dx01v2 deploy: $1"
    echo
    echo "| Item | Value |"
    echo "|---|---|"
    echo "| Commit | \`${GIT_SHA:-unknown}\` |"
    echo "| Overlay | \`deploy/k8s/overlays/$OVERLAY\` |"
    echo "| Images | \`dx01v2/api:${GIT_SHA:-}\`, \`dx01v2/web:${GIT_SHA:-}\` in ECR ($AWS_REGION) |"
    echo "| Entry point | ${BASE:-not reached} |"
    if [[ -f "$WORK_DIR/smoke.txt" ]]; then
      echo
      echo '```'
      cat "$WORK_DIR/smoke.txt"
      echo '```'
    fi
    echo
    echo "The ALB, the EKS cluster and RDS bill by the hour: tear the lab down with the tx01v2 terraform-destroy workflow (it deletes every Ingress, and so the ALB, first)."
  } >>"$GITHUB_STEP_SUMMARY"
}

cleanup() {
  local rc=$?
  if ((GROUP_OPEN)); then
    echo "::endgroup::"
  fi
  if [[ -n "$WORK_DIR" ]]; then
    if ((rc == 0)); then
      write_summary succeeded
    else
      write_summary failed
    fi
    rm -rf "$WORK_DIR"
  fi
  exit "$rc"
}

preflight() {
  require_cmd aws kubectl docker node git curl base64
  [[ -n "${AWS_REGION:-}" ]] || die "AWS_REGION is required (the region of the tx01v2 lab)"
  [[ "$AWS_REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die "AWS_REGION does not look like a region: $AWS_REGION"
  if [[ -z "${GIT_SHA:-}" ]]; then
    [[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] ||
      die "the working tree has uncommitted changes: images are tagged with the commit SHA and ECR tags are immutable"
    GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  fi
  [[ "$GIT_SHA" =~ ^[0-9a-f]{40}$ ]] || die "GIT_SHA must be a full 40-character commit SHA"
  if [[ -n "${ALB_CERTIFICATE_ARN:-}" ]]; then
    OVERLAY=aws-https
    [[ "${SMOKE_BASE_URL:-}" == https://* ]] ||
      die "with ALB_CERTIFICATE_ARN, set SMOKE_BASE_URL=https://<a DNS name of the certificate that points at the ALB>"
  fi
  aws sts get-caller-identity --query Arn --output text >/dev/null ||
    die "no usable AWS credentials (role dx01v2-gha-deploy, or a principal listed in app_deployer_principal_arns of tx01v2)"
}

read_contract() {
  local out name value n
  out="$(aws ssm get-parameters --names "${SSM_NAMES[@]}" --query 'Parameters[].[Name,Value]' --output text)" ||
    die "cannot read the SSM parameters $SSM_PREFIX/* (was tx01v2 terraform/envs/lab applied in $AWS_REGION?)"
  while IFS=$'\t' read -r name value; do
    if [[ -n "$name" ]]; then
      PARAM[$name]=$value
    fi
  done <<<"$out"
  for n in "${SSM_NAMES[@]}"; do
    [[ -n "${PARAM[$n]:-}" ]] || die "the SSM parameter $n is missing (contract v1, docs/CONTRATO.md)"
  done
  expect_param region "$AWS_REGION"
  expect_param cluster-name "$CONTRACT_CLUSTER"
  expect_param db/secret-name "$CONTRACT_DB_SECRET"
  expect_param app/admin-token-secret-name "$CONTRACT_ADMIN_TOKEN_SECRET"
  expect_param eso/cluster-secret-store "$CONTRACT_SECRET_STORE"
  [[ "$(param ecr/api-url)" =~ ${ECR_URL_PATTERN}api$ ]] || die "SSM $SSM_PREFIX/ecr/api-url is not the URL of the dx01v2/api repository"
  [[ "$(param ecr/web-url)" =~ ${ECR_URL_PATTERN}web$ ]] || die "SSM $SSM_PREFIX/ecr/web-url is not the URL of the dx01v2/web repository"
  API_IMAGE="$(param ecr/api-url):$GIT_SHA"
  WEB_IMAGE="$(param ecr/web-url):$GIT_SHA"
  log "contract v1: ${#SSM_NAMES[@]} parameters read and consistent with the manifests"
}

push_image() { # COMPONENT IMAGE
  local component=$1 image=$2 found
  found="$(aws ecr batch-get-image --repository-name "dx01v2/$component" --image-ids "imageTag=$GIT_SHA" \
    --query 'length(images)' --output text)" || die "cannot query the ECR repository dx01v2/$component"
  if [[ "$found" == 1 ]]; then
    log "dx01v2/$component:$GIT_SHA is already in ECR (immutable tags): not rebuilt"
    return 0
  fi
  docker build --platform "$IMAGE_PLATFORM" -f "$REPO_ROOT/$component/Dockerfile" --build-arg GIT_SHA="$GIT_SHA" \
    -t "$image" "$REPO_ROOT"
  docker push "$image"
}

publish_images() {
  aws ecr get-login-password | docker login --username AWS --password-stdin "${API_IMAGE%%/*}" >/dev/null
  push_image api "$API_IMAGE"
  push_image web "$WEB_IMAGE"
}

connect_cluster() {
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  aws eks update-kubeconfig --name "$(param cluster-name)" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG" \
    --alias dx01v2-lab >/dev/null
  [[ "$(kubectl auth can-i create deployments.apps -n "$NAMESPACE")" == yes ]] ||
    die "this principal cannot deploy to namespace $NAMESPACE: it needs an EKS access entry in the group dx01v2-deployers (tx01v2 app_deployer_principal_arns) and the tx01v2 platform layer (Role dx01v2-deployer)"
}

create_rds_ca() {
  local url="${RDS_CA_BASE_URL}${AWS_REGION}/${AWS_REGION}-bundle.pem" file="$WORK_DIR/rds-ca.pem"
  download "$url" "$file"
  grep -q -- '-----BEGIN CERTIFICATE-----' "$file" || die "$url did not return a PEM bundle"
  kubectl -n "$NAMESPACE" create configmap rds-ca --from-file=ca.pem="$file" --dry-run=client -o yaml | kubectl apply -f -
}

render_and_apply() {
  local params="$WORK_DIR/params.env" tree="$WORK_DIR/k8s"
  {
    echo "API_IMAGE=$API_IMAGE"
    echo "WEB_IMAGE=$WEB_IMAGE"
    echo "WAF_ACL_ARN=$(param waf/acl-arn)"
    echo "VPC_CIDR=$(param vpc-cidr)"
    echo "ALB_CERTIFICATE_ARN=${ALB_CERTIFICATE_ARN:-}"
  } >"$params"
  # Validates every value against the contract formats and renders a temporary copy of deploy/k8s.
  k8s_prepare_tree "$tree" "$params"
  kubectl kustomize "$tree/overlays/$OVERLAY" >"$WORK_DIR/rendered.yaml"
  log "overlays/$OVERLAY rendered: $(grep -c '^kind: ' "$WORK_DIR/rendered.yaml") objects"
  kubectl apply -k "$tree/overlays/$OVERLAY"
}

wait_for_rollout() {
  kubectl -n "$NAMESPACE" wait externalsecret/db-credentials externalsecret/app-secrets --for=condition=Ready --timeout=300s
  kubectl -n "$NAMESPACE" rollout status deployment/api --timeout=600s
  kubectl -n "$NAMESPACE" rollout status deployment/web --timeout=600s
}

wait_for_ingress() {
  local i
  for i in $(seq 1 120); do
    ALB_HOSTNAME="$(kubectl -n "$NAMESPACE" get ingress dx01v2 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
    if [[ -n "$ALB_HOSTNAME" ]]; then
      log "ALB hostname after about $((i * 5))s: $ALB_HOSTNAME"
      return 0
    fi
    sleep 5
  done
  kubectl -n "$NAMESPACE" describe ingress dx01v2 >&2
  die "the Ingress got no ALB hostname in 10 minutes (is the tx01v2 platform layer installed? see the events above)"
}

smoke() {
  local token status=0
  BASE="${SMOKE_BASE_URL:-http://$ALB_HOSTNAME}"
  token="$(kubectl -n "$NAMESPACE" get secret app-secrets -o jsonpath='{.data.ADMIN_TOKEN}' | base64 -d)"
  [[ ${#token} -ge 32 ]] || die "the Secret app-secrets has no usable ADMIN_TOKEN (is the ExternalSecret synced?)"
  if in_actions; then
    echo "::add-mask::$token"
  fi
  # SMOKE_BEHIND_WAF=1: the WAF of tx01v2 answers oversized bodies with 403 before the API does.
  BASE_URL="$BASE" ADMIN_TOKEN="$token" SMOKE_WAIT_SECONDS="${SMOKE_WAIT_SECONDS:-900}" SMOKE_BEHIND_WAF=1 \
    node "$REPO_ROOT/e2e/smoke.mjs" | tee "$WORK_DIR/smoke.txt" || status=$?
  ((status == 0)) || die "the smoke test through the ALB failed (FAIL lines above)"
}

main() {
  (($# == 0)) || die "usage: $0 (configuration through environment variables, see the header)"
  preflight
  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  section "contract v1: SSM parameters $SSM_PREFIX/*"
  read_contract
  section "images dx01v2/api and dx01v2/web, tag $GIT_SHA"
  publish_images
  section "cluster $(param cluster-name): kubeconfig and RBAC"
  connect_cluster
  section "ConfigMap rds-ca ($AWS_REGION bundle)"
  create_rds_ca
  section "kubectl apply -k deploy/k8s/overlays/$OVERLAY"
  render_and_apply
  section "ExternalSecrets and rollouts"
  wait_for_rollout
  section "Ingress (ALB)"
  wait_for_ingress
  section "smoke test through the ALB"
  smoke
  log "deploy of $GIT_SHA complete: $BASE"
}

main "$@"
