# shellcheck shell=bash
# Kubernetes helpers shared by render-k8s.sh, e2e-kind.sh, deploy-aws.sh and the harness.
# Source after scripts/lib/common.sh.

K8S_DIR="$REPO_ROOT/deploy/k8s"
K8S_PARAMS_EXAMPLE="$K8S_DIR/components/aws/params.example.env"
# shellcheck disable=SC2034 # used by the scripts that source this file
K8S_OVERLAYS=(local aws aws-https)

# Formats accepted for every deploy parameter (values come from SSM, contract v1).
declare -A K8S_PARAM_PATTERN=(
  [API_IMAGE]='^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/dx01v2/api:[0-9a-f]{40}$'
  [WEB_IMAGE]='^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/dx01v2/web:[0-9a-f]{40}$'
  [WAF_ACL_ARN]='^arn:aws[a-z-]*:wafv2:[a-z0-9-]+:[0-9]{12}:regional/webacl/[A-Za-z0-9_-]+/[0-9a-f-]{36}$'
  [VPC_CIDR]='^([0-9]{1,3}\.){3}[0-9]{1,3}/([89]|1[0-9]|2[0-8])$'
  [ALB_CERTIFICATE_ARN]='^(arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/[0-9a-f-]{36})?$'
)

# k8s_validate_params FILE -> fails unless FILE has exactly the known keys with valid values.
k8s_validate_params() {
  local file=$1 line key value rc=0
  declare -A seen=()
  [[ -f "$file" ]] || die "params file not found: $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || {
      log "params: invalid line (KEY=VALUE expected): ${line%%=*}"
      rc=1
      continue
    }
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if [[ -z "${K8S_PARAM_PATTERN[$key]:-}" ]]; then
      log "params: unknown key $key"
      rc=1
    elif [[ ! "$value" =~ ${K8S_PARAM_PATTERN[$key]} ]]; then
      log "params: $key has an invalid format"
      rc=1
    fi
    seen[$key]=1
  done <"$file"
  for key in "${!K8S_PARAM_PATTERN[@]}"; do
    [[ -n "${seen[$key]:-}" ]] || {
      log "params: missing $key"
      rc=1
    }
  done
  return "$rc"
}

# k8s_prepare_tree DEST [PARAMS_FILE] -> copies deploy/k8s to DEST and installs the params file
# (default: the committed example) as components/aws/params.env. The repository is never written.
k8s_prepare_tree() {
  local dest=$1 params=${2:-$K8S_PARAMS_EXAMPLE}
  k8s_validate_params "$params" || die "invalid params file: $params"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$K8S_DIR/." "$dest/"
  rm -f "$dest/components/aws/params.env"
  cp "$params" "$dest/components/aws/params.env"
}

# k8s_render OVERLAY [PARAMS_FILE] -> rendered manifests of the overlay on stdout.
k8s_render() {
  local overlay=$1 params=${2:-} tmp rc=0
  require_cmd kubectl
  tmp="$(mktemp -d)"
  k8s_prepare_tree "$tmp/k8s" "$params"
  kubectl kustomize "$tmp/k8s/overlays/$overlay" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# k8s_dump_diagnostics NAMESPACE DIR -> state, events, descriptions and logs (never Secret values).
k8s_dump_diagnostics() {
  local ns=$1 dir=$2 pod container
  mkdir -p "$dir"
  log "collecting diagnostics of namespace $ns into $dir"
  kubectl get nodes -o wide >"$dir/nodes.txt" 2>&1 || :
  kubectl -n "$ns" get all,networkpolicy,pdb,configmap,ingress,hpa -o wide >"$dir/resources.txt" 2>&1 || :
  kubectl -n "$ns" get events --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1 || :
  kubectl -n "$ns" describe pods >"$dir/describe-pods.txt" 2>&1 || :
  kubectl -n "$ns" describe deployments,statefulsets >"$dir/describe-workloads.txt" 2>&1 || :
  kubectl -n kube-system get pods -o wide >"$dir/kube-system-pods.txt" 2>&1 || :
  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    for container in $(kubectl -n "$ns" get "$pod" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null); do
      kubectl -n "$ns" logs "$pod" -c "$container" --tail=500 >"$dir/logs-${pod#pod/}-$container.txt" 2>&1 || :
      kubectl -n "$ns" logs "$pod" -c "$container" --previous --tail=200 >"$dir/logs-${pod#pod/}-$container-previous.txt" 2>/dev/null || :
    done
  done < <(kubectl -n "$ns" get pods -o name 2>/dev/null)
  find "$dir" -type f -empty -delete
}
