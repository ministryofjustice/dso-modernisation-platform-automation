#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

usage() {
  echo "Usage $0: ec2|ami|code|list|delete <months>

$0 ec2
  - list all AMIs referenced by EC2s

$0 ami <months>
  - list all AMIs in account older than <months>

$0 code_names <application>
  - list all AMI names found in the environments repo, optionally provide an application name, e.g. nomis

$0 code <application>
  - list all AMIs in account which are also referenced in the environments repo, optionally provide an application name, e.g. nomis

$0 ec2_and_code <application>
  - list all AMIs either referenced by EC2s or referenced in environments repo

$0 list <months> [keep_ec2_and_code <application>]
  - list all AMIs older than <months> that can be deleted. By default just check for AMIs referenced by running EC2s. But option to keep those referenced in code also

$0 list_including_backup <months> [keep_ec2_and_code <application>]
  - same as list except includes any AwsBackup AMIs found

$0 delete <months> [keep_ec2_and_code <application>]
  - delete all AMIs older than <months> that can be deleted. By default just check for AMIs referenced by running EC2s. But option to keep those referenced in code also

$0 delete_including_backup <months> [keep_ec2_and_code <application>]
  - same as delete except includes any AwsBackup AMIs found
"
}

date_minus_month() {
  local month=$1
  shift
  if [[ "$(uname)" == "Darwin" ]]; then
     date -jv-"${month}"m "$@"
  else
     date -d "-${month} month" "$@"
  fi
}

date_minus_year() {
  local year=$1
  shift
  if [[ "$(uname)" == "Darwin" ]]; then
     date -jv-"${year}"y "$@"
  else
     date -d "-${year} year" "$@"
  fi
}

get_date_filter() {
  local date_filter
  local i
  local m
  local m1
  local m2
  local m3

  m=$1
  m1=$(date_minus_month "$m" "+%m")
  m2=${m1#0}
  m3=$((m+m2))
  if ((m2<12)); then
    for ((i=m;i<m3;i++)); do
      date_filter=${date_filter}$(date_minus_month "$i" "+%Y-%m-*"),
    done
  else
    date_filter=${date_filter}$(date_minus_month "$m2" "+%Y-*"),
  fi
  date_filter=${date_filter}$(date_minus_month $((m3+1)) "+%Y-*"),
  date_filter=${date_filter}$(date_minus_month $((m3+13)) "+%Y-*"),
  date_filter=${date_filter}$(date_minus_month $((m3+25)) "+%Y-*")
  echo $date_filter
}

get_images_csv() {
  # Input: <months_history>
  # Output: ImageId,OwnerId,CreationDate,Public,Name
  local date_filter
  local json

  set -e
  echo aws sts get-caller-identity --query Account --output text >&2
  this_account_id=$(aws sts get-caller-identity --query Account --output text)
  if [[ -z $1 ]]; then
    echo aws ec2 describe-images --owners "$this_account_id" >&2
    json=$(aws ec2 describe-images --owners "$this_account_id")
  else
    date_filter=$(get_date_filter "$1")
    echo aws ec2 describe-images --filters "Name=creation-date,Values=$date_filter" --owners "$this_account_id" >&2
    json=$(aws ec2 describe-images --filters "Name=creation-date,Values=$date_filter" --owners "$this_account_id")
  fi
  jq -r ".Images[] | [.ImageId, .OwnerId, .CreationDate, .Public, .Name] | @csv" <<< "$json" | sed 's/"//g'
}

get_ec2_instance_images_csv() {
  # Output: ImageId,OwnerId,CreationDate,Public,Name
  local ids
  local json

  set -e
  echo aws ec2 describe-instances --query "Reservations[*].Instances[*].ImageId" >&2
  ids=($(aws ec2 describe-instances --query "Reservations[*].Instances[*].ImageId" --output text))
  echo aws ec2 describe-images --image-ids ... >&2
  json=$(aws ec2 describe-images --image-ids "${ids[@]}")
  jq -r ".Images[] | [.ImageId, .OwnerId, .CreationDate, .Public, .Name] | @csv" <<< "$json" | sed 's/"//g'
}

get_code_image_names() {
  local envdir

  if [[ -z $1 ]]; then
    envdir=$(dirname "$0")/../../modernisation-platform-environments/terraform/environments
    if [[ ! -d "$envdir" ]]; then
      echo "Cannot find $envdir" >&2
      exit 1
    fi
    grep -Eo 'ami_name[[:space:]]*=[[:space:]]*"[^"]*"' "$envdir"/*/*.tf | cut -d\" -f2 | sort -u | grep -vF '*' | sort -u
  else
    envdir=$(dirname "$0")/../../modernisation-platform-environments/terraform/environments/"$1"
    if [[ ! -d "$envdir" ]]; then
      echo "Cannot find $envdir" >&2
      exit 1
    fi
    grep -Eo 'ami_name[[:space:]]*=[[:space:]]*"[^"]*"' "$envdir"/*.tf | cut -d\" -f2 | sort -u | grep -vF '*' | sort -u
  fi
}

get_code_csv() {
  ami=$(get_images_csv 0 | sort -t, -k5)
  code=$(get_code_image_names "$1")
  join -o 1.1,1.2,1.3,1.4,1.5  -t, -1 5 <(echo "$ami") <(echo "$code")
}

get_ec2_and_code_csv() {
  ami=$(get_images_csv 0 | sort -t, -k5)
  code=$(get_code_image_names "$1")
  amicode=$(join -o 1.1,1.2,1.3,1.4,1.5  -t, -1 5 <(echo "$ami") <(echo "$code") | sort)
  ec2=$(get_ec2_instance_images_csv | sort)
  comm <(echo "$amicode") <(echo "$ec2") | tr -d ' ' | tr -d '\t'
}

get_images_to_delete_csv() {
  local ami
  local ec2

  ami=$(get_images_csv "$1" | sort)
  if [[ $2 == "keep_ec2_and_code" ]]; then
    ec2=$(get_ec2_and_code_csv "$3" | sort)
  else
    ec2=$(get_ec2_instance_images_csv | sort)
  fi
  comm -23 <(echo "$ami") <(echo "$ec2")
}

delete_images() {
  echo "DELETING FOLLOWING AMIS" >&2
  echo "${@}" >&2
  for id in $(echo "$@" | cut -d, -f1); do
    echo "aws ec2 deregister-image --image-id $id" >&2
    aws ec2 deregister-image --image-id "$id"
  done
}

main() {
  if [[ $1 == "ec2" ]]; then
    get_ec2_instance_images_csv | sort -t, -k3
  elif [[ $1 == "ami" ]]; then
    get_images_csv "$2" | sort -t, -k3
  elif [[ $1 == "code_names" ]]; then
    get_code_image_names "$2"
  elif [[ $1 == "code" ]]; then
    get_code_csv "$2" | sort -t, -k3
  elif [[ $1 == "ec2_and_code" ]]; then
    get_ec2_and_code_csv "$2" | sort -t, -k3
  elif [[ $1 == "list" ]]; then
    shift
    get_images_to_delete_csv "$@" | grep -v AwsBackup | sort -t, -k3
  elif [[ $1 == "list_including_backup" ]]; then
    shift
    get_images_to_delete_csv "$@" | sort -t, -k3
  elif [[ $1 == "delete" ]]; then
    shift
    csv=$(get_images_to_delete_csv "$@" | grep -v AwsBackup |  sort -t, -k3)
    delete_images "$csv"
  elif [[ $1 == "delete_including_backup" ]]; then
    shift
    csv=$(get_images_to_delete_csv "$@" | sort -t, -k3)
    delete_images "$csv"
  else
    usage >&2
    exit 1
  fi
}

main "$@"
