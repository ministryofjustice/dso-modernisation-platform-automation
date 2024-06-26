#!/bin/bash
set -eo pipefail

usage() {
    echo "Usage: $0 first|all <tag:Name> <comment> <script>"
    echo
    echo "Finds EC2s matching tag:Name and runs the given script using SSM"
    echo "  first: run on first EC2 only."
    echo "  all:   run on all matching EC2s"
    echo "Returns exitcode of 1 if script fails to run, 2 if instance not found"G
}

get_instance_ids() {
  local instance_json
  instance_json=$(aws ec2 describe-instances --no-cli-pager --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" || true)
  jq -r ".Reservations[].Instances[].InstanceId" <<< "$instance_json"
}

run_command_on_instance() {
  echo "aws ssm send-command \
    --instance-ids '$1' \
    --document-name 'AWS-RunShellScript' \
    --comment '$2' \
    --parameters '{\"commands\":[\"$3\"]}'" >&2
  aws ssm send-command \
    --instance-ids $1 \
    --document-name "AWS-RunShellScript" \
    --comment "$2" \
    --parameters "{\"commands\":[\"$3\"]}"
}

wait_for_command() {
  local result_json
  local result_status
  local i
  local n

  n=12
  for i in $(seq 1 $n); do
    echo "[$i/$n] aws ssm get-command-invocation --instance-id '$1' --command-id '$2'" >&2
    result_json=$(aws ssm get-command-invocation --instance-id "$1" --command-id "$2")
    result_status=$(jq -r ".Status" <<< "$result_json")
    if [[ $result_status == "Success" || $result_status == "Failed" || $result_status == "Terminated" ]]; then
      break
    fi
    sleep 5
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

  instance_ids=$(get_instance_ids "$name")
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
  command_json=$(run_command_on_instance "$instance_ids" "$comment" "$script")
  echo "$command_json"
  command_id=$(jq -r ".Command.CommandId" <<< "$command_json")

  exitcode=0
  for instance_id in $instance_ids; do
    result_json=$(wait_for_command "$instance_id" "$command_id")
    echo "$result_json"
    result_status=$(jq -r ".Status" <<< "$result_json")

    echo "Results for instance_id=$instance_id" >&2
    if [[ $result_status == "Success" ]]; then
      jq -r ".StandardOutputContent" <<< "$result_json"
    elif [[ $result_status == "Failed" ]]; then
      jq -r ".StandardOutputContent" <<< "$result_json"
      jq -r ".StandardErrorContent" <<< "$result_json" >&2
      exitcode=1
    else
      echo "Command failed to execute, or timed out waiting for response >&2"
      echo "$result_status" >&2
      exitcode=1
    fi
  done
  return $exitcode
}

main "$@"
