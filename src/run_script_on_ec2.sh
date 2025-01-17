#!/bin/bash
set -eo pipefail

SHOW_PROGRESS="${SHOW_PROGRESS:-1}"
SHOW_COMMAND_JSON="${SHOW_COMMAND_JSON:-0}"
SHOW_RESULT_JSON="${SHOW_RESULT_JSON:-0}"
SHOW_STDERR_ON_SUCCESS="${SHOW_STDERR_ON_SUCCESS:0}"
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"
CHECK_INTERVAL_SECS="${CHECK_INTERVAL_SECS:-10}"
LOGPREFIX=

usage() {
    echo "Usage (1): $0 first|all        <tag:Name>                     <comment> <script|filename> [logprefix]"
    echo "Usage (2): $0 shell|powershell 'instance_id1 .. instance_idn' <comment> <script|filename> [logprefix]"
    echo
    echo "Usage (1) Finds EC2s matching tag:Name and runs the given script using SSM"
    echo "  first: run on first EC2 only."
    echo "  all:   run on all matching EC2s"
    echo
    echo "Usage (2) Runs given shell or powershell script against all given instance ids"
    echo
    echo "Returns exitcode of 1 if script fails to run, 2 if instance not found"
    echo
    echo "Example Usage: TIMEOUT_SECS=3600 $0 first 'pd-ndh-app-a'        'cdecopy'                  'sudo su tibco -c cdecopy.sh'"
    echo "Example Usage:                   $0 all   'server-type:ncr-web' 'systemctl status sapbobj' 'sudo systemctl status sapbobj'"
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
  if ((SHOW_PROGRESS != 0)); then
    echo "${LOGPREFIX}aws ssm send-command \
      --instance-ids '$1' \
      --document-name '$4' \
      --comment '$2' \
      --parameters '$3'" >&2
  fi
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
    if ((SHOW_PROGRESS != 0)); then
      echo "${LOGPREFIX}[$i/$n] aws ssm get-command-invocation --instance-id '$1' --command-id '$2'" >&2
    fi
    result_json=$(aws ssm get-command-invocation --instance-id "$1" --command-id "$2")
    result_status=$(jq -r ".Status" <<< "$result_json")
    if [[ $result_status == "Success" || $result_status == "Failed" || $result_status == "Terminated" ]]; then
      break
    fi
  done
  echo "$result_json"
}

main() {
  option=$1
  comment=$3
  script=$4
  LOGPREFIX=$5
  if [[ -z $option || -z $comment || -z $script ]]; then
    usage >&2
    exit 1
  fi

  if [[ $option == "shell" ]]; then
    document_name=AWS-RunShellScript
    instance_ids="$2"
  elif [[ $option == "powershell" ]]; then
    document_name=AWS-RunPowerShellScript
    instance_ids="$2"
  elif [[ $option == "all" || $option == "first" ]]; then
    if [[ $2 == *:* ]]; then
      tag=${2%:*}
      name=${2#*:}
    else
      tag=Name
      name=$2
    fi
    if [[ -z $name || -z $tag ]]; then
      usage >&2
      exit 1
    fi
    instance_json=$(aws ec2 describe-instances --no-cli-pager --filters "Name=tag:$tag,Values=$name" "Name=instance-state-name,Values=running" || true)
    instance_ids=$(jq -r ".Reservations[].Instances[].InstanceId" <<< "$instance_json")
    platforms=$(jq -r ".Reservations[].Instances[].Platform" <<< "$instance_json" | sort -u)
    if [[ $platforms == "windows" ]]; then
      document_name=AWS-RunPowerShellScript
    else
      document_name=AWS-RunShellScript
    fi
    if [[ -z $instance_ids ]]; then
      echo "${LOGPREFIX}No running instance with tag:$tag=$name" >&2
      exit 2
    fi
    if [[ $option == "first" ]]; then
      instance_ids=$(echo "$instance_ids" | head -1)
    fi
  else
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

    if ((SHOW_PROGRESS != 0)); then
      echo "${LOGPREFIX}Results for instance_id=$instance_id" >&2
    fi
    if [[ $result_status == "Success" ]]; then
      if ((SHOW_STDERR_ON_SUCCESS != 0)); then
        jq -r ".StandardErrorContent" <<< "$result_json" | sed -e "s/^/$LOGPREFIX/" >&2
      fi
      jq -r ".StandardOutputContent" <<< "$result_json" | sed -e "s/^/$LOGPREFIX/"
    elif [[ $result_status == "Failed" ]]; then
      jq -r ".StandardErrorContent" <<< "$result_json" | sed -e "s/^/$LOGPREFIX/" >&2
      jq -r ".StandardOutputContent" <<< "$result_json" | sed -e "s/^/$LOGPREFIX/"
      exitcode=1
    else
      if ((SHOW_PROGRESS != 0)); then
        echo "${LOGPREFIX}Command failed to execute, or timed out waiting for response >&2"
      fi
      echo "${LOGPREFIX}$result_status" >&2
      exitcode=1
    fi
  done
  return "$exitcode"
}

main "$@"
