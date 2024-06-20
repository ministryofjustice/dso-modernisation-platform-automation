#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

usage() {
  echo "Usage $0: ec2|ami|list|delete <months>"
}

date_minus_month() {
  local month=$1
  shift
  if [[ "$(uname)" == "Darwin" ]]; then
     date -jv-${month}m $@
  else
     date -d "-${month} month" $@
  fi
}

date_minus_year() {
  local year=$1
  shift
  if [[ "$(uname)" == "Darwin" ]]; then
     date -jv-${year}y $@
  else
     date -d "-${year} year" $@
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
  m1=$(date_minus_month $m "+%m")
  m2=${m1#0}
  m3=$((m+m2))
  if ((m2<12)); then
    for ((i=m;i<m3;i++)); do
      date_filter=${date_filter}$(date_minus_month $i "+%Y-%m-*"),
    done
  else
    date_filter=${date_filter}$(date_minus_month $m2 "+%Y-*"),
  fi
  date_filter=${date_filter}$(date_minus_month $((m3+1)) "+%Y-*"),
  date_filter=${date_filter}$(date_minus_month $((m3+13)) "+%Y-*"),
  date_filter=${date_filter}$(date_minus_month $((m3+25)) "+%Y-*")
  echo $date_filter
}

get_images_csv() {
  # Input: <months_history>
  # Output: OwnerId,ImageId,Name,CreationDate,Public
  local date_filter
  local json 

  set -e
  echo aws sts get-caller-identity --query Account --output text >&2
  this_account_id=$(aws sts get-caller-identity --query Account --output text)
  if [[ -z $1 ]]; then
    echo aws ec2 describe-images --owners $this_account_id >&2
    json=$(aws ec2 describe-images --owners $this_account_id)
  else
    date_filter=$(get_date_filter $1)
    echo aws ec2 describe-images --filters "Name=creation-date,Values=$date_filter" --owners $this_account_id >&2
    json=$(aws ec2 describe-images --filters "Name=creation-date,Values=$date_filter" --owners $this_account_id)
  fi
  jq -r ".Images[] | [.ImageId, .OwnerId, .CreationDate, .Public, .Name] | @csv" <<< $json | sed 's/"//g'
}

get_ec2_instance_images() {
  local ids
  local json 

  set -e
  echo aws ec2 describe-instances --query "Reservations[*].Instances[*].ImageId" >&2
  ids=($(aws ec2 describe-instances --query "Reservations[*].Instances[*].ImageId" --output text))
  echo aws ec2 describe-images --image-ids ... >&2
  json=$(aws ec2 describe-images --image-ids ${ids[@]})
  jq -r ".Images[] | [.ImageId, .OwnerId, .CreationDate, .Public, .Name] | @csv" <<< $json | sed 's/"//g'
}

if [[ $1 == "ec2" ]]; then
  get_ec2_instance_images | sort -t, -k3
elif [[ $1 == "ami" ]]; then
  get_images_csv $2 | sort -t, -k3
elif [[ $1 == "list" ]]; then
  ec2=$(get_ec2_instance_images | sort)
  ami=$(get_images_csv $2 | sort)
  comm -23 <(echo "$ami") <(echo "$ec2") | sort -t, -k3
elif [[ $1 == "delete" ]]; then
  ec2=$(get_ec2_instance_images | sort)
  ami=$(get_images_csv $2 | sort)
  comm -23 <(echo "$ami") <(echo "$ec2") | sort -t, -k3
else
  usage >&2
  exit 1
fi
