#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
# shellcheck source=scripts/lib/region-target.sh
source "$REPO_ROOT/scripts/lib/region-target.sh"
select_region_target primary
[[ "$SSM_PREFIX" == /tx01v2/lab && "$GITOPS_BRANCH" == gitops/aws ]]
select_region_target secondary
[[ "$SSM_PREFIX" == /tx01v2/lab-dr && "$CONTRACT_CLUSTER" == tx01v2-lab-dr && "$GITOPS_BRANCH" == gitops/aws-dr ]]
if (select_region_target unrelated) >/dev/null 2>&1; then die 'arbitrary target accepted'; fi
work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
sed -e 's/us-east-1/us-west-2/g' -e 's/DB_ENDPOINT=tx01v2-lab-postgres/DB_ENDPOINT=tx01v2-lab-dr-postgres/' \
  "$K8S_PARAMS_EXAMPLE" >"$work/dr.env"
k8s_render aws-https-full "$work/dr.env" >"$work/dr.yaml"
k8s_render aws-https-full >"$work/example.yaml"
node --input-type=module - "$work/dr.yaml" <<'JS'
import fs from 'node:fs';
import YAML from 'yaml';
const docs = YAML.parseAllDocuments(fs.readFileSync(process.argv[2], 'utf8')).map((d) => d.toJSON());
const secret = docs.find((d) => d?.kind === 'ExternalSecret' && d.metadata.name === 'db-credentials');
if (secret?.spec.target.template.data.DB_HOST !== 'tx01v2-lab-dr-postgres.example.us-west-2.rds.amazonaws.com' ||
    secret.spec.target.template.mergePolicy !== 'Merge' ||
    secret.spec.data.some((entry) => entry.remoteRef.key !== 'tx01v2-lab/db/app')) {
  throw new Error('current credential fields or standby endpoint are not preserved');
}
JS
node "$REPO_ROOT/scripts/render-gitops-application.mjs" aws aws-https-full "$work/dr.env" "$K8S_PARAMS_EXAMPLE" >"$work/application.json"
jq -e '.spec.source.targetRevision == "gitops/aws-dr"' "$work/application.json" >/dev/null
node "$REPO_ROOT/scripts/check-gitops-renderer.mjs" "$work/application.json" "$work/example.yaml"
echo 'PASS bounded regional targets, unchanged current credential names, regional DB_HOST and separate GitOps branch'
