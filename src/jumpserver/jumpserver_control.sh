#!/bin/bash

# helper script for stopping/starting jump server

DRYRUN=0

usage() {
  echo "Usage $0: <opts> <jumpserver>

Where <opts>:
  -0                     Power off
  -1                     Power on
  -z                     Print account name
"
}

get_account_name() {
  local jumpserver

  jumpserver=$1
  if [[ $jumpserver =~ "t1-jump" ]]; then
    account_name="hmpps-domain-services-test"
  elif [[ $jumpserver =~ "pp-jump" ]]; then
    account_name="hmpps-domain-services-preproduction"
  elif [[ $jumpserver =~ "pd-jump" ]]; then
    account_name="hmpps-domain-services-production"
  else
    echo "Unsupported jumpserver $jumpserver" >&2
    return 1
  fi
  echo "$account_name"
}

get_instance_state() {
  local i
  local j
  local name
  local json
  local num_reservations
  local num_instances
  local instance_id
  local last_instance_id
  local state

  name="$1"
  json=$(aws ec2 describe-instances --no-cli-pager --filters "Name=tag:Name,Values=$name")
  num_reservations=$(echo "$json" | jq '.Reservations | length')
  instance_id=
  last_instance_id=
  state=
  for ((i=0; i<num_reservations; i++)); do
    num_instances=$(echo "$json" | jq ".Reservations[$i].Instances | length")
    for ((j=0; j<num_instances; j++)); do
      instance_json=$(echo "$json" | jq ".Reservations[$i].Instances[$j]")
      instance_id=$(echo "$instance_json" | jq -r ".InstanceId")
      state=$(echo "$instance_json" | jq -r ".State.Name")
      if [[ -n $last_instance_id && $last_instance_id != "$instance_id" ]]; then
        echo "Multiple instances with same Name '$name' not supported '$last_instance_id' and '$instance_id' >&2"
        return 1
      fi
      last_instance_id=$instance_id
    done
  done
  if [[ -z $instance_id ]]; then
    echo "Cannot find jumpserver '$name' with current shell AWS creds" >&2
    return 1
  fi
  echo "$instance_id,$state"
}

power() {
  set -eo pipefail
  opt=$1
  name=$2
  if ! id_and_state=$(get_instance_state "$name"); then
    return 1
  fi
  instance_id=$(echo "$id_and_state" | cut -d, -f1)
  state=$(echo "$id_and_state" | cut -d, -f2)

  if [[ $opt == "display" ]]; then
    echo "$id_and_state"
  elif [[ $opt == "on" ]]; then
    n=60
    for ((i=1; i<=n; i++)); do
      if [[ $state == "running" ]]; then
        echo "Instance running: $id_and_state"
        return 0
      elif [[ $state == "terminated" ]]; then
        echo "Cannot start a terminated ec2: $id_and_state" >&2
        return 1
      elif [[ $state == "stopped" ]]; then
        if (( DRYRUN == 0 )); then
          echo aws ec2 start-instances --instance-ids "$instance_id" >&2
          if ! aws ec2 start-instances --instance-ids "$instance_id"; then
            return 1
          fi
        else
          echo aws ec2 start-instances --instance-ids "$instance_id" --dry-run >&2
          aws ec2 start-instances --instance-ids "$instance_id" --dry-run
          return 0
        fi
      fi
      echo "[$i/$n] Waiting 10 seconds for instance state running: $id_and_state" >&2
      sleep 10
      if ! id_and_state=$(get_instance_state "$name"); then
        return 1
      fi
      instance_id=$(echo "$id_and_state" | cut -d, -f1)
      state=$(echo "$id_and_state" | cut -d, -f2)
    done
    echo "Timed out waiting for instance to start" >&2
    return 1
  elif [[ $opt == "off" ]]; then
    n=60
    for ((i=1; i<=n; i++)); do
      if [[ $state == "terminated" || $state == "stopped" ]]; then
        echo "Instance stopped: $id_and_state"
        return 0
      elif [[ $state == "running" ]]; then
        if (( DRYRUN == 0 )); then
          echo aws ec2 stop-instances --instance-ids "$instance_id" >&2
          if ! aws ec2 stop-instances --instance-ids "$instance_id"; then
            return 1
          fi
        else
          echo aws ec2 stop-instances --instance-ids "$instance_id" --dry-run >&2
          aws ec2 stop-instances --instance-ids "$instance_id" --dry-run
          return 0
        fi
      fi
      echo "[$i/$n] Waiting 10 seconds for instance state stopped: $id_and_state" >&2
      sleep 10
      if ! id_and_state=$(get_instance_state "$name"); then
        return 1
      fi
      instance_id=$(echo "$id_and_state" | cut -d, -f1)
      state=$(echo "$id_and_state" | cut -d, -f2)
    done
    echo "Timed out waiting for instance to stop" >&2
    return 1
  else
    echo "INTERNAL ERROR: unsupported power() option '$opt'" >&2
    return 1
  fi
}

main() {
  set -eo pipefail
  option_set=0
  account_name=0
  power_off=0
  power_on=0
  while getopts "01dz" opt; do
      case $opt in
          0)
              option_set=$((option_set + 1))
              power_off=1
              ;;
          1)
              option_set=$((option_set + 1))
              power_on=1
              ;;
          d)
              DRYRUN=1
              ;;
          z)
              option_set=$((option_set + 1))
              account_name=1
              ;;
          :)
              echo "Error: option ${OPTARG} requires an argument" >&2
              exit 1
              ;;
          ?)
              echo "Invalid option: ${OPTARG}" >&2
              echo >&2
              usage >&2
              exit 1
              ;;
      esac
  done

  shift $((OPTIND-1))

  if [[ -z $1 || -n $2 ]]; then
    usage >&2
    exit 1
  fi

  if (( account_name == 1 )); then
    if ! get_account_name "$1"; then
      exit 1
    fi
  elif (( power_on == 1 )); then
    if ! power on "$1"; then
      exit 1
    fi
  elif (( power_off == 1 )); then
    if ! power off "$1"; then
      exit 1
    fi
  else
    power display "$1"
  fi
}

main "$@"
