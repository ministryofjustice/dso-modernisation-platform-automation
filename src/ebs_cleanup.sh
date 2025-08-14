#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

# defaults
dryrun=false
max_age_months=1
region='eu-west-2'

valid_actions=("all" "delete" "unattached" "attached")

usage() {
  echo "Usage $0: [<opts>] $(IFS='|'; echo "${valid_actions[*]}")

Where <opts>:
  -d                     Dryrun for delete command. Default: false
  -m <months>            Exclude volumes younger than this number of months. Default: 1

And:
  all                    List all volumes in the current account
  attached               List all attached volumes
  unattached.            List all unattached volumes
  delete                 Delete unattached volumes
"
}

main() {
  check_action
  set_date_cmd
  get_volumes
}

while getopts ":de:m:s:" opt; do
  case $opt in
    d) dryrun=true ;;
    m) max_age_months="$OPTARG" ;;
    s) shell_output="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done
shift $((OPTIND -1))
action=$1

check_action() {
  message="Scanning for $action EBS volumes older than $max_age_months months in $region..."
  case $action in
    all)
      filters=''
      none_message="No volumes found older than $max_age_months months in $region"
      ;;
    attached)
      filters='--filters Name=status,Values=in-use'
      none_message="No attached volumes found older than $max_age_months months in $region"
      ;;
    unattached)
      filters='--filters Name=status,Values=available'
      none_message="No unattached volumes found older than $max_age_months months in $region"
      ;;
    delete)
      filters='--filters Name=status,Values=available'
      if [[ "$dryrun" == true ]]; then
        message="Dryrun - Pretend deleting EBS volumes older than $max_age_months months in $region..."
      else
        message="Deleting EBS volumes older than $max_age_months months in $region..."
      fi
      none_message="No unattached volumes found older than $max_age_months months in $region to delete"
      ;;
    *)
      action=unattached
      filters='--filters Name=status,Values=available'
      message="Scanning for $action EBS volumes older than $max_age_months months in $region..."
      none_message="No unattached volumes found older than $max_age_months months in $region"
      ;;
  esac
}

set_date_cmd(){
  # use linux date command for reliable behaviour
  if [[ "$(uname)" == "Darwin" ]]; then
    if command -v gdate >/dev/null 2>&1; then
      date_cmd="gdate"  # macOS with coreutils installed
    else
      echo "exiting. First you need to run: brew install core-utils"
      exit 1
    fi
  else
    date_cmd="date" # linux
  fi
  now=$($date_cmd +%s)
}

do_action() {
  created_epoch=$($date_cmd -d "$create_time" +%s)
  age_months_dp=$(awk "BEGIN { printf \"%.1f\", ($now - $created_epoch) / 2592000 }") # 1 decimal place
  age_months=$(awk "BEGIN { print int($age_months_dp) }")

  (( age_months >= max_age_months )) || return

  case $action in
    all)
      echo "$volume_id $state $age_months_dp months old" ;;
    attached)
      echo "$volume_id $age_months_dp months old" ;;
    unattached)
      echo "$volume_id $age_months_dp months old, reason: $reason" ;;
    delete)
      if [[ "$dryrun" == true ]]; then
        echo "$volume_id $age_months_dp months old, reason: $reason"
      else
        echo "Currently disabled delete function - $volume_id $age_months_dp months old"
        #echo "Deleting $volume_id $age_months_dp months old"
        #aws ec2 delete-volume --volume-id "$volume_id" --region "$region"
      fi
      ;;
  esac
}

get_volumes() {
  echo $message

  aws_output=$(aws ec2 describe-volumes \
    --region "$region" \
    --query "Volumes[*].{ID:VolumeId,CreateTime:CreateTime,State:State,Tags:Tags}" \
    --output text \
    $filters)

  # while read .... do ... <<< $aws_output - this structure because it handles variables better than piping |, e.g. if you wanted to iterate an outside variable within the loop  
  if [[ -n "$aws_output" ]]; then # because this loop would run once even without any aws_output
    while read -r col1 col2 col3 col4 col5; do
      case $col1 in
        20[0-9][0-9]-??-??T*)
          [[ -n "$volume_id" ]] && do_action
          create_time="$col1"
          volume_id="$col2"
          state="$col3"
          reason="?"
        ;;
        TAGS)
          [[ "$col2" == "map-migrated" ]] && reason="MAP"
        ;;
        *)
          echo "thing $col1 $col2"
      esac
    done <<< "$aws_output"
  else
    echo $none_message
  fi
}

main
