# shellcheck shell=bash
# GetParameters accepts at most ten names. Return a failure even if only a later batch fails.
read_ssm_parameters() {
  local offset
  local -a names=("$@")
  for ((offset = 0; offset < ${#names[@]}; offset += 10)); do
    aws ssm get-parameters --names "${names[@]:offset:10}" --query 'Parameters[].[Name,Value]' --output text || return
  done
}
