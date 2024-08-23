#!/bin/bash
set -eo pipefail

SHOW_COMMAND_JSON="${SHOW_COMMAND_JSON:-0}"
SHOW_RESULT_JSON="${SHOW_RESULT_JSON:-0}"
SHOW_STDERR_ON_SUCCESS="${SHOW_STDERR_ON_SUCCESS:0}"
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"
CHECK_INTERVAL_SECS="${CHECK_INTERVAL_SECS:-10}"

usage() {
    echo "Usage: $0 first|all <tag:Name> <comment> <script|filename>"
    echo
    echo "Finds EC2s matching tag:Name and runs the given script using SSM"
    echo "  first: run on first EC2 only."
    echo "  all:   run on all matching EC2s"
    echo "Returns exitcode of 1 if script fails to run, 2 if instance not found"
    echo
    echo "Example Usage: TIMEOUT_SECS=3600 $0 first 'pd-ndh-app-a' 'cdecopy' 'sudo su tibco -c cdecopy.sh'"
}

get_command_json() {
  local script_lines
  local script_line
  local i
  local n

  IFS=$'\n'
  if [[ -f "$1" ]]; then
    script_lines=($(cat "$1"))
  else
    script_lines=($(echo "$1"))
  fi
  unset IFS
  echo '{"commands":['
  n=${#script_lines[@]}
  for ((i=0; i<n-1; i++)); do
    script_line=$(jq -MR <<< "${script_lines[$i]}")
    echo "${script_line},"
  done
  jq -MR <<< "${script_lines[$i]}"
  echo ']}'
}

run_command_on_instance() {
  local command_json
  command_json=$(get_command_json "$3")
  echo "aws ssm send-command \
    --instance-ids '$1' \
    --document-name '$4' \
    --comment '$2' \
    --parameters '$command_json'" >&2
  aws ssm send-command \
    --instance-ids $1 \
    --document-name "$4" \
    --comment "$2" \
    --parameters "$command_json"
}

wait_for_command() {
  local result_json
  local result_status
  local i
  local n

  n=$((1+TIMEOUT_SECS/CHECK_INTERVAL_SECS))
  for i in $(seq 1 $n); do
    sleep "$CHECK_INTERVAL_SECS"
    echo "[$i/$n] aws ssm get-command-invocation --instance-id '$1' --command-id '$2'" >&2
    result_json=$(aws ssm get-command-invocation --instance-id "$1" --command-id "$2")
    result_status=$(jq -r ".Status" <<< "$result_json")
    if [[ $result_status == "Success" || $result_status == "Failed" || $result_status == "Terminated" ]]; then
      break
    fi
  done
  echo "$result_json"
}

main() {
  instance_count=$1
  name=$2
  comment=$3
  script=$4
  if [[ -z $instance_count || -z $name || -z $comment || -z $script ]]; then
    usage >&2
    exit 1
  fi

  instance_json=$(aws ec2 describe-instances --no-cli-pager --filters "Name=tag:Name,Values=$name" "Name=instance-state-name,Values=running" || true)
  instance_ids=$(jq -r ".Reservations[].Instances[].InstanceId" <<< "$instance_json")
  platforms=$(jq -r ".Reservations[].Instances[].Platform" <<< "$instance_json" | sort -u)
  if [[ $platforms == "windows" ]]; then
    document_name=AWS-RunPowerShellScript
  else
    document_name="AWS-RunShellScript"
  fi
  if [[ -z $instance_ids ]]; then
    echo "No running instance with tag:Name=$name" >&2
    exit 2
  fi
  if [[ $instance_count == "first" ]]; then
    instance_ids=$(echo "$instance_ids" | head -1)
  elif [[ $instance_count != "all" ]]; then
    echo "Expected first or all, got $instance_count" >&2
    usage >&2
    exit 1
  fi
  command_json=$(run_command_on_instance "$instance_ids" "$comment" "$script" "$document_name")
  if ((SHOW_COMMAND_JSON != 0)); then
    echo "$command_json" >&2
  fi
  command_id=$(jq -r ".Command.CommandId" <<< "$command_json")

  exitcode=0
  for instance_id in $instance_ids; do
    result_json=$(wait_for_command "$instance_id" "$command_id")
    if ((SHOW_RESULT_JSON != 0)); then
      echo "$result_json" | grep -v StandardErrorContent | grep -v StandardOutputContent >&2
    fi
    result_status=$(jq -r ".Status" <<< "$result_json")

    echo "Results for instance_id=$instance_id" >&2
    if [[ $result_status == "Success" ]]; then
      if ((SHOW_STDERR_ON_SUCCESS != 0)); then
        jq -r ".StandardErrorContent" <<< "$result_json" >&2
      fi
      jq -r ".StandardOutputContent" <<< "$result_json"
    elif [[ $result_status == "Failed" ]]; then
      jq -r ".StandardErrorContent" <<< "$result_json" >&2
      jq -r ".StandardOutputContent" <<< "$result_json"
      exitcode=1
    else
      echo "Command failed to execute, or timed out waiting for response >&2"
      echo "$result_status" >&2
      exitcode=1
    fi
  done
  return "$exitcode"
}

main "$@"
