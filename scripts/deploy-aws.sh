#!/usr/bin/env bash
# Deploys dx01v2 to the EKS lab cluster of tx01v2 (docs/CONTRATO.md).
# CLOUD-MUTATING and billable: promotes images to ECR and makes the AWS Load Balancer Controller
# create an internet-facing ALB. Run it only on purpose, after the tx01v2 apply + platform steps;
# the teardown is the tx01v2 destroy. Not run in the cloud yet (v2).
# Used by .github/workflows/deploy-aws.yml and from a laptop (docs/RUNBOOK.md):
#   AWS_REGION=us-east-1 scripts/deploy-aws.sh
# Environment:
#   AWS_REGION           required; must match the SSM parameter /tx01v2/lab/region
#   RELEASE_DIR          verified bundle from publish-images (release manifest and two SBOMs)
#   RELEASE_RUN_ID       successful publish-images Actions run id for that bundle
#   GH_TOKEN             token with packages:read, attestations:read, and actions:read
#   GIT_SHA              optional; if set, must equal the release manifest source commit
#   DEPLOY_MODE          gitops (default: commit to gitops/aws and wait for Argo CD) or push
#                        (apply the cloud overlay directly; use only when Argo CD is not managing it)
#   GITHUB_TOKEN         optional in a laptop session; Actions provides it for the GitOps branch push
#   ARGO_SYNC_TIMEOUT    seconds to wait for the GitOps Application (default 600)
#   ALB_CERTIFICATE_ARN  optional ACM certificate of the region: selects overlays/aws-https
#   SMOKE_BASE_URL       smoke test URL (default http://<ALB hostname>); required with HTTPS:
#                        https://<a DNS name of the certificate that points at the ALB>
#   SMOKE_WAIT_SECONDS   how long the smoke test waits for the ALB and its DNS name (default 900)
# Steps: verify signed release -> SSM contract -> promote verified digests from GHCR to ECR
# (no build; immutable source-SHA tags) -> kubeconfig -> ConfigMap rds-ca -> configure Argo CD and publish gitops/aws
# (default) -> sync -> ExternalSecrets -> rollouts -> Ingress hostname -> smoke test through the ALB.
# DEPLOY_MODE=push applies the overlay directly; the script never runs Terraform or deletes anything.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

NAMESPACE=dx01v2
SSM_PREFIX=/tx01v2/lab
# Contract: every parameter the deploy reads (the harness check contract-app verifies this list).
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
RELEASE_MANIFEST=""
API_SOURCE_NAME=""
API_SOURCE_DIGEST=""
API_IMAGE_ID=""
WEB_SOURCE_NAME=""
WEB_SOURCE_DIGEST=""
WEB_IMAGE_ID=""

declare -A PARAM=()
WORK_DIR=""
GROUP_OPEN=0
OVERLAY=aws
API_IMAGE=""
WEB_IMAGE=""
ALB_HOSTNAME=""
BASE=""
DEPLOY_MODE="${DEPLOY_MODE:-gitops}"
ARGO_SYNC_TIMEOUT="${ARGO_SYNC_TIMEOUT:-600}"
GITOPS_REV=""

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
  [[ "$(param "$1")" == "$2" ]] || die "SSM $SSM_PREFIX/$1 is '$(param "$1")' but the manifests expect '$2' (docs/CONTRATO.md)"
}

write_summary() { # RESULT
  local api_digest="${API_IMAGE##*@}" web_digest="${WEB_IMAGE##*@}"
  [[ "$api_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || api_digest=not-promoted
  [[ "$web_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || web_digest=not-promoted
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "## dx01v2 deploy: $1"
    echo
    echo "| Item | Value |"
    echo "|---|---|"
    echo "| Commit | \`${GIT_SHA:-unknown}\` |"
    echo "| Overlay | \`deploy/k8s/overlays/$OVERLAY\` |"
    printf "| Images | API \`%s\`, web \`%s\` in ECR (%s) |\n" "$api_digest" "$web_digest" "$AWS_REGION"
    echo "| Entry point | $([[ -n "$ALB_HOSTNAME" ]] && echo 'ALB ready' || echo 'not reached') |"
    echo "| Smoke test | $([[ -f "$WORK_DIR/smoke.txt" ]] && echo 'completed' || echo 'not completed') |"
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
  require_cmd aws kubectl docker node git curl base64 gh jq
  [[ -n "${RELEASE_DIR:-}" ]] || die "RELEASE_DIR is required; publish and verify a release first"
  [[ -n "${RELEASE_RUN_ID:-}" ]] || die "RELEASE_RUN_ID is required; select the successful publish-images run"
  [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN with actions:read, attestations:read and packages:read is required"
  RELEASE_MANIFEST="$RELEASE_DIR/release-manifest.json"
  bash "$REPO_ROOT/scripts/verify-release-bundle.sh"
  API_SOURCE_NAME="$(jq -er '.images.api.name' "$RELEASE_MANIFEST")"
  API_SOURCE_DIGEST="$(jq -er '.images.api.digest' "$RELEASE_MANIFEST")"
  API_IMAGE_ID="$(jq -er '.images.api.image_id' "$RELEASE_MANIFEST")"
  WEB_SOURCE_NAME="$(jq -er '.images.web.name' "$RELEASE_MANIFEST")"
  WEB_SOURCE_DIGEST="$(jq -er '.images.web.digest' "$RELEASE_MANIFEST")"
  WEB_IMAGE_ID="$(jq -er '.images.web.image_id' "$RELEASE_MANIFEST")"
  release_sha="$(jq -er '.source.sha' "$RELEASE_MANIFEST")"
  if [[ -n "${GIT_SHA:-}" && "$GIT_SHA" != "$release_sha" ]]; then
    die "GIT_SHA does not match the verified release source commit $release_sha"
  fi
  GIT_SHA="$release_sha"
  [[ -n "${AWS_REGION:-}" ]] || die "AWS_REGION is required (the region of the tx01v2 lab)"
  [[ "$AWS_REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die "AWS_REGION does not look like a region: $AWS_REGION"
  [[ "$DEPLOY_MODE" == gitops || "$DEPLOY_MODE" == push ]] || die "DEPLOY_MODE must be gitops or push"
  if [[ ! "$ARGO_SYNC_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    die "ARGO_SYNC_TIMEOUT must be an integer of at least 5 seconds"
  fi
  if ((ARGO_SYNC_TIMEOUT < 5)); then
    die "ARGO_SYNC_TIMEOUT must be an integer of at least 5 seconds"
  fi
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
    [[ -n "${PARAM[$n]:-}" ]] || die "the SSM parameter $n is missing (docs/CONTRATO.md)"
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
  log "contract: ${#SSM_NAMES[@]} parameters read and consistent with the manifests"
}

promote_image() { # COMPONENT GHCR_NAME GHCR_DIGEST EXPECTED_IMAGE_ID ECR_URL
  local component=$1 source_name=$2 source_digest=$3 expected_id=$4 ecr_url=$5
  local source_ref="$source_name@$source_digest" ecr_tag="$ecr_url:$GIT_SHA" found digest remote_id local_id
  docker pull "$source_ref" >/dev/null || die "cannot pull verified $component source digest $source_ref"
  local_id="$(docker image inspect "$source_ref" --format '{{.Id}}')"
  [[ "$local_id" == "$expected_id" ]] || die "$component GHCR digest does not contain the image ID from the release manifest"
  found="$(aws ecr batch-get-image --repository-name "dx01v2/$component" --image-ids "imageTag=$GIT_SHA" \
    --query 'length(images)' --output text)" || die "cannot query the ECR repository dx01v2/$component"
  if [[ "$found" != 1 ]]; then
    docker tag "$local_id" "$ecr_tag"
    docker push "$ecr_tag" >&2
  else
    log "dx01v2/$component:$GIT_SHA already exists in ECR; verifying it matches the signed release"
  fi
  digest="$(aws ecr describe-images --repository-name "dx01v2/$component" --image-ids "imageTag=$GIT_SHA" \
    --query 'imageDetails[0].imageDigest' --output text)" ||
    die "cannot resolve the immutable ECR digest for dx01v2/$component:$GIT_SHA"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "ECR returned an invalid $component image digest: $digest"
  docker pull "$ecr_url@$digest" >/dev/null || die "cannot pull the promoted $component image from ECR"
  remote_id="$(docker image inspect "$ecr_url@$digest" --format '{{.Id}}')"
  [[ "$remote_id" == "$expected_id" ]] || die "promoted $component ECR digest differs from the signed GHCR image"
  printf '%s@%s' "$ecr_url" "$digest"
}

publish_images() {
  local ecr_host
  ecr_host="$(param ecr/api-url)"
  ecr_host="${ecr_host%%/*}"
  aws ecr get-login-password | docker login --username AWS --password-stdin "$ecr_host" >/dev/null
  API_IMAGE="$(promote_image api "$API_SOURCE_NAME" "$API_SOURCE_DIGEST" "$API_IMAGE_ID" "$(param ecr/api-url)")"
  WEB_IMAGE="$(promote_image web "$WEB_SOURCE_NAME" "$WEB_SOURCE_DIGEST" "$WEB_IMAGE_ID" "$(param ecr/web-url)")"
  log "promoted the signed release to ECR by immutable digest; no image was rebuilt"
}

connect_cluster() {
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  aws eks update-kubeconfig --name "$(param cluster-name)" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG" \
    --alias dx01v2-lab >/dev/null
  [[ "$(kubectl auth can-i create deployments.apps -n "$NAMESPACE")" == yes ]] ||
    die "this principal cannot deploy to namespace $NAMESPACE: it needs an EKS access entry in the group dx01v2-deployers (tx01v2 app_deployer_principal_arns) and the tx01v2 platform layer (Role dx01v2-deployer)"
  if [[ "$DEPLOY_MODE" == gitops ]]; then
    [[ "$(kubectl auth can-i patch applications.argoproj.io/dx01v2 -n argocd)" == yes ]] ||
      die "this principal cannot patch the Argo CD Application dx01v2 in argocd (tx01v2 full platform Role)"
    kubectl -n argocd get application dx01v2 >/dev/null ||
      die "Argo CD Application dx01v2 is missing (install the tx01v2 full platform first)"
  fi
}

create_rds_ca() {
  local url="${RDS_CA_BASE_URL}${AWS_REGION}/${AWS_REGION}-bundle.pem" file="$WORK_DIR/rds-ca.pem"
  download "$url" "$file"
  grep -q -- '-----BEGIN CERTIFICATE-----' "$file" || die "$url did not return a PEM bundle"
  kubectl -n "$NAMESPACE" create configmap rds-ca --from-file=ca.pem="$file" --dry-run=client -o yaml | kubectl apply -f -
}

write_params() {
  local params="$WORK_DIR/params.env"
  {
    echo "API_IMAGE=$API_IMAGE"
    echo "WEB_IMAGE=$WEB_IMAGE"
    echo "WAF_ACL_ARN=$(param waf/acl-arn)"
    echo "VPC_CIDR=$(param vpc-cidr)"
    echo "ALB_CERTIFICATE_ARN=${ALB_CERTIFICATE_ARN:-}"
  } >"$params"
}

render_and_apply() {
  local params="$WORK_DIR/params.env" tree="$WORK_DIR/k8s"
  write_params
  # Validates every value against the contract formats and renders a temporary copy of deploy/k8s.
  k8s_prepare_tree "$tree" "$params"
  cat >"$tree/overlays/$OVERLAY/gitops-revision.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitops-revision
  labels:
    app.kubernetes.io/name: dx01v2
    app.kubernetes.io/part-of: dx01v2
data:
  source-commit: "$GIT_SHA"
  api-image-tag: "$GIT_SHA"
  web-image-tag: "$GIT_SHA"
  api-image-digest: "${API_IMAGE##*@}"
  web-image-digest: "${WEB_IMAGE##*@}"
EOF
  kubectl kustomize "$tree/overlays/$OVERLAY" >"$WORK_DIR/rendered.yaml"
  log "overlays/$OVERLAY rendered: $(grep -c '^kind: ' "$WORK_DIR/rendered.yaml") objects"
  kubectl apply -k "$tree/overlays/$OVERLAY"
}

render_gitops_source() {
  local tree="$WORK_DIR/k8s"
  write_params
  k8s_prepare_tree "$tree" "$WORK_DIR/params.env"
  cat >"$tree/overlays/$OVERLAY/gitops-revision.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitops-revision
  labels:
    app.kubernetes.io/name: dx01v2
    app.kubernetes.io/part-of: dx01v2
data:
  source-commit: "$GIT_SHA"
  api-image-tag: "$GIT_SHA"
  web-image-tag: "$GIT_SHA"
  api-image-digest: "${API_IMAGE##*@}"
  web-image-digest: "${WEB_IMAGE##*@}"
EOF
  kubectl kustomize "$tree/overlays/$OVERLAY" >"$WORK_DIR/rendered.yaml"
  log "GitOps source overlays/$OVERLAY rendered: $(grep -c '^kind: ' "$WORK_DIR/rendered.yaml") objects"
}

configure_gitops_application() {
  local patch="$WORK_DIR/argocd-application-patch.json"
  write_params
  node "$REPO_ROOT/scripts/render-gitops-application.mjs" aws "$OVERLAY" \
    "$WORK_DIR/params.env" "$REPO_ROOT/deploy/k8s/components/aws/params.example.env" >"$patch"
  kubectl -n argocd patch application dx01v2 --type merge --patch-file "$patch" >/dev/null
  log "Argo CD Application source configured for $OVERLAY and image tag $GIT_SHA"
}

publish_gitops_revision() {
  GITOPS_REV="$(bash "$REPO_ROOT/scripts/publish-gitops.sh" aws "$OVERLAY" "$GIT_SHA" \
    "${API_IMAGE##*@}" "${WEB_IMAGE##*@}")"
  [[ "$GITOPS_REV" =~ ^[0-9a-f]{40}$ ]] || die "GitOps branch push returned no commit SHA"
  kubectl -n argocd annotate application dx01v2 argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  log "published origin/gitops/aws at ${GITOPS_REV:0:7}"
}

wait_for_gitops() {
  local i sync health revision=""
  for i in $(seq 1 $((ARGO_SYNC_TIMEOUT / 5))); do
    sync="$(kubectl -n argocd get application dx01v2 -o jsonpath='{.status.sync.status}' 2>/dev/null)" || sync=""
    health="$(kubectl -n argocd get application dx01v2 -o jsonpath='{.status.health.status}' 2>/dev/null)" || health=""
    revision="$(kubectl -n argocd get application dx01v2 -o jsonpath='{.status.sync.revision}' 2>/dev/null)" || revision=""
    [[ "$sync" == Synced && "$health" == Healthy && "$revision" == "$GITOPS_REV" ]] && {
      log "Argo CD: dx01v2 Synced and Healthy at ${revision:0:7}"
      return 0
    }
    ((i % 12 == 0)) && log "Argo CD: dx01v2 sync=${sync:-?} health=${health:-?} revision=${revision:0:7}"
    sleep 5
  done
  kubectl -n argocd get application dx01v2 -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' >&2 || :
  die "Argo CD did not reach Synced/Healthy at ${GITOPS_REV:0:7} within ${ARGO_SYNC_TIMEOUT}s"
}

wait_for_rollout() {
  local api_image api_init_image web_image
  kubectl -n "$NAMESPACE" wait externalsecret/db-credentials externalsecret/app-secrets --for=condition=Ready --timeout=300s
  api_image="$(kubectl -n "$NAMESPACE" get deployment api -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].image}')"
  api_init_image="$(kubectl -n "$NAMESPACE" get deployment api -o jsonpath='{.spec.template.spec.initContainers[?(@.name=="migrate")].image}')"
  web_image="$(kubectl -n "$NAMESPACE" get deployment web -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].image}')"
  [[ "$api_image" == "$API_IMAGE" && "$api_init_image" == "$API_IMAGE" && "$web_image" == "$WEB_IMAGE" ]] ||
    die "Argo CD did not apply the requested immutable digests (api=${api_image##*@} migrate=${api_init_image##*@} web=${web_image##*@})"
  kubectl -n "$NAMESPACE" rollout status deployment/api --timeout=600s
  kubectl -n "$NAMESPACE" rollout status deployment/web --timeout=600s
}

wait_for_ingress() {
  local i
  for i in $(seq 1 120); do
    ALB_HOSTNAME="$(kubectl -n "$NAMESPACE" get ingress dx01v2 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
    if [[ -n "$ALB_HOSTNAME" ]]; then
      if in_actions; then
        echo "::add-mask::$ALB_HOSTNAME"
      fi
      log "ALB hostname after about $((i * 5))s: $ALB_HOSTNAME"
      return 0
    fi
    sleep 5
  done
  kubectl -n "$NAMESPACE" describe ingress dx01v2 >&2
  die "the Ingress got no ALB hostname in 10 minutes (is the tx01v2 platform layer installed? see the events above)"
}

smoke() {
  local token status=0 smoke_host
  BASE="${SMOKE_BASE_URL:-http://$ALB_HOSTNAME}"
  if in_actions; then
    echo "::add-mask::$BASE"
    echo "::add-mask::$ALB_HOSTNAME"
    smoke_host="${BASE#*://}"
    smoke_host="${smoke_host%%/*}"
    echo "::add-mask::$smoke_host"
    smoke_host="${smoke_host%%:*}"
    if [[ -n "$smoke_host" ]]; then
      echo "::add-mask::$smoke_host"
    fi
  fi
  token=""
  if [[ "$BASE" == https://* ]]; then
    token="$(kubectl -n "$NAMESPACE" get secret app-secrets -o jsonpath='{.data.ADMIN_TOKEN}' | base64 -d)"
    [[ ${#token} -ge 32 ]] || die "the Secret app-secrets has no usable ADMIN_TOKEN (is the ExternalSecret synced?)"
    if in_actions; then
      echo "::add-mask::$token"
    fi
  else
    # The admin token is a credential: it never goes over plain HTTP to the internet.
    log "the entry point is plain HTTP: the admin token is not read, and the smoke test skips the DELETE that needs it (ALB_CERTIFICATE_ARN and SMOKE_BASE_URL give HTTPS)"
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
  section "contract: SSM parameters $SSM_PREFIX/*"
  read_contract
  section "signed release $GIT_SHA: promote GHCR digests to ECR"
  publish_images
  section "cluster $(param cluster-name): kubeconfig and RBAC"
  connect_cluster
  section "ConfigMap rds-ca ($AWS_REGION bundle)"
  create_rds_ca
  if [[ "$DEPLOY_MODE" == gitops ]]; then
    section "configure and publish GitOps revision gitops/aws"
    render_gitops_source
    configure_gitops_application
    publish_gitops_revision
    wait_for_gitops
  else
    section "kubectl apply -k deploy/k8s/overlays/$OVERLAY (direct push alternative)"
    render_and_apply
  fi
  section "ExternalSecrets and rollouts"
  wait_for_rollout
  section "Ingress (ALB)"
  wait_for_ingress
  section "smoke test through the ALB"
  smoke
  log "deploy of $GIT_SHA complete: $BASE"
}

main "$@"
