# shellcheck shell=bash
select_region_target() {
  LAB_TARGET="${1:-primary}"
  case "$LAB_TARGET" in
    primary) SSM_PREFIX=/tx01v2/lab; CONTRACT_CLUSTER=tx01v2-lab; GITOPS_BRANCH=gitops/aws ;;
    secondary) SSM_PREFIX=/tx01v2/lab-dr; CONTRACT_CLUSTER=tx01v2-lab-dr; GITOPS_BRANCH=gitops/aws-dr ;;
    *) die 'LAB_TARGET must be primary or secondary' ;;
  esac
  export LAB_TARGET SSM_PREFIX CONTRACT_CLUSTER GITOPS_BRANCH
}
