#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

# defaults
dryrun=false
environment=''
max_age_months=1
region='eu-west-2'

valid_actions=("all" "delete" "unattached" "attached")

usage() {
  echo "Usage $0: [<opts>] $(IFS='|'; echo "${valid_actions[*]}")

Where <opts>:
  -d                     Dryrun for delete command. Default: false
  -e <environment>       Environment e.g. nomis-test          
  -m <months>            Exclude volumes younger than this number of months. Default: 1

And:
  all                    List all volumes in the current account
  attached               List all attached volumes
  unattached.            List all unattached volumes
  delete                 Delete unattached volumes
"
}

main() {
  check_profile
  check_action
  set_date_cmd
  action
}

while getopts ":de:m:s:" opt; do
  case $opt in
    d) dryrun=true ;;
    e) environment="$OPTARG" ;;
    m) max_age_months="$OPTARG" ;;
    s) shell_output="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done
shift $((OPTIND -1))
action=$1

check_profile() {
  # could check if we are actully logged in when environment is set, choosing to fail at the apply step if not logged in so it isnt very slow.
  if [[ -n "${environment:-}" ]]; then
    :
  elif env_alias=$(aws iam list-account-aliases --output text 2>/dev/null); then
    environment=$(echo "$env_alias" | awk '{print $2}')
  else
    echo "need to log into aws"
    exit 1
  fi
  
}

check_action() {
  message="Scanning for $action EBS volumes older than $max_age_months months in $environment $region..."
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
      message="Scanning for $action EBS volumes older than $max_age_months months in $environment $region..."
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

action() {
  echo $message

  aws_output=$(aws ec2 describe-volumes \
    --region "$region" \
    --query "Volumes[*].{ID:VolumeId,CreateTime:CreateTime,State:State}" \
    --output text \
    $filters $profile)
  
  if [[ -n "$aws_output" ]]; then
    while read -r create_time volume_id state; do
      created_epoch=$($date_cmd -d "$create_time" +%s)
      age_months_dec=$(awk "BEGIN { printf \"%.1f\", ($now - $created_epoch) / 2592000 }") # 1 decimal place
      age_months=$(awk "BEGIN { print int($age_months_dec) }")

      if [ "$age_months" -ge "$max_age_months" ]; then
        case $action in
          all)
            echo "$volume_id $state $age_months_dec months old in $environment" ;;
          attached)
            echo "$volume_id $age_months_dec months oldn $environment" ;;
          unattached)
            echo "$volume_id $age_months_dec months old in $environment" ;;
          delete)
            if [[ "$dryrun" == true ]]; then
              echo "Dryrun - would delete volume $volume_id - $age_months_dec months old in $environment"
            else
              echo "Deleting volume $volume_id - $age_months_dec months old in $environment"
              #aws ec2 delete-volume --volume-id "$volume_id" --region "$region" $profile
            fi
            ;;
        esac
      fi
    done <<< "$aws_output"
  else
    echo $none_message
  fi
}

main
