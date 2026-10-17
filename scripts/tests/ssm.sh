#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/ssm.sh
source "$REPO_ROOT/scripts/lib/ssm.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
mkdir "$work/bin"
cat >"$work/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == 'ssm get-parameters --names' ]]
shift 3
count=0
while (($#)) && [[ "$1" != --* ]]; do
  [[ "${FAIL_NAME:-}" != "$1" ]] || exit 3
  printf '%s\tvalue\n' "$1"
  count=$((count + 1))
  shift
done
((count > 0 && count <= 10))
printf '%s\n' "$count" >>"$CALLS"
MOCK
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH" CALLS="$work/calls"
names=()
for i in {1..21}; do names+=("/tx01v2/lab/key-$i"); done
out="$(read_ssm_parameters "${names[@]}")"
[[ "$(wc -l <<<"$out")" == 21 && "$(tr '\n' ',' <"$CALLS")" == 10,10,1, ]]
if FAIL_NAME=/tx01v2/lab/key-11 read_ssm_parameters "${names[@]}" >/dev/null; then die 'second batch failure ignored'; fi
echo 'PASS SSM batch limit, complete results and refusal of a failed later batch'
