#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

usage() {
  echo "Usage $0: [<opts>] used|account|code|delete

Where <opts>:
  -a <application>       Specify which application for images in code, e.g. nomis 
  -b                     Optionally include AwsBackup images
  -c                     Also include images referenced in code
  -d                     Dryrun for delete command
  -m <months>            Exclude images younger than this number of months

And:
  used                   List all images in use (and -c flag to include code)
  account                List all images in the current account
  code                   List all image names referenced in code
  delete                 Delete unused images
"
}

date_minus_month() {
  local month

  month=$1
  shift
  if [[ "$(uname)" == "Darwin" ]]; then
     date -jv-"${month}"m "$@"
  else
     date -d "-${month} month" "$@"
  fi
}

date_minus_year() {
  local year

  year=$1
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

get_account_images_csv() {
  local date_filter
  local json
  local months
  local include_backup
  local this_account_id

  set -eo pipefail
  months=$1
  include_backup=$2  
  echo aws sts get-caller-identity --query Account --output text >&2
  this_account_id=$(aws sts get-caller-identity --query Account --output text)
  if [[ -z $months ]]; then
    echo aws ec2 describe-images --owners "$this_account_id" >&2
    json=$(aws ec2 describe-images --owners "$this_account_id")
  else
    date_filter=$(get_date_filter "$months")
    echo aws ec2 describe-images --filters "Name=creation-date,Values=$date_filter" --owners "$this_account_id" >&2
    json=$(aws ec2 describe-images --filters "Name=creation-date,Values=$date_filter" --owners "$this_account_id")
  fi
  if [[ $include_backup == 0 ]]; then
    jq -r ".Images[] | [.ImageId, .OwnerId, .CreationDate, .Public, .Name] | @csv" <<< "$json" | sed 's/"//g' > /dev/null
    jq -r ".Images[] | [.ImageId, .OwnerId, .CreationDate, .Public, .Name] | @csv" <<< "$json" | sed 's/"//g' | grep -v AwsBackup || true
  else
    jq -r ".Images[] | [.ImageId, .OwnerId, .CreationDate, .Public, .Name] | @csv" <<< "$json" | sed 's/"//g'
  fi
}

get_ec2_instance_images_csv() {
  local ids
  local json

  set -eo pipefail
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
    grep -Eo 'ami_name[[:space:]]*=[[:space:]]*"[^"]*"' "$envdir"/*/*.tf | cut -d\" -f2 | sort -u | grep -vF '*' | sort -u || true
  else
    envdir=$(dirname "$0")/../../modernisation-platform-environments/terraform/environments/"$1"
    if [[ ! -d "$envdir" ]]; then
      echo "Cannot find $envdir" >&2
      exit 1
    fi
    grep -Eo 'ami_name[[:space:]]*=[[:space:]]*"[^"]*"' "$envdir"/*.tf | cut -d\" -f2 | sort -u | grep -vF '*' | sort -u || true
  fi
}

get_code_csv() {
  local ami
  local code

  ami=$(get_account_images_csv 0 | sort -t, -k5)
  code=$(get_code_image_names "$1")
  join -o 1.1,1.2,1.3,1.4,1.5  -t, -1 5 <(echo "$ami") <(echo "$code")
}

get_ec2_and_code_csv() {
  local ami
  local code
  local amicode
  local ec2

  ami=$(get_account_images_csv 0 | sort -t, -k5)
  code=$(get_code_image_names "$1")
  amicode=$(join -o 1.1,1.2,1.3,1.4,1.5  -t, -1 5 <(echo "$ami") <(echo "$code") | sort)
  ec2=$(get_ec2_instance_images_csv | sort)
  comm <(echo "$amicode") <(echo "$ec2") | tr -d ' ' | tr -d '\t'
}

get_in_use_images_csv() {
  local ec2
  local code
  local application

  ec2=$1
  code=$2
  application=$3
  if [[ $ec2 == 1 ]]; then
    if [[ $code == 1 ]]; then
      get_ec2_and_code_csv "$application"
    else
      get_ec2_instance_images_csv
    fi
  elif [[ $code == 1 ]]; then
    get_code_csv "$application"
  else
    echo "Need either include_images_in_code or include_images_in_ec2 to be set" >&2
    return 1
  fi
}

get_images_to_delete_csv() {
  local ami
  local ec2

  set -eo pipefail
  ec2=$(get_in_use_images_csv "$1" "$2" "$3" | sort)
  ami=$(get_account_images_csv "$4" "$5" | sort)
  comm -23 <(echo "$ami") <(echo "$ec2")
}

delete_images() {
  local dryrun
  local i
  local id
  local ids
  local n

  dryrun=$1
  shift
  IFS=$'\n'
  ids=($(echo "$@"))
  unset IFS
  n=${#ids[@]}
  if [[ $dryrun == 0 ]]; then
    echo "deleting $n AMI(s)" >&2
  else
    echo "DRY RUN: would delete $n AMI(s)" >&2
  fi
  for ((i=0;i<n;i++)); do
    IFS=','
    id=(${ids[i]})
    unset IFS
    if [[ $dryrun == 0 ]]; then
      echo -n "[$((i+1))/$n] " >&2
    fi
    echo "aws ec2 deregister-image --image-id ${id[0]} # ${id[2]} ${id[4]}" >&2
    if [[ $dryrun == 0 ]]; then
      aws ec2 deregister-image --image-id "${id[0]}" >&2
    fi
  done
}

main() {
  months=
  application=
  include_backup=0
  include_images_in_code=0
  include_images_on_ec2=1
  dryrun=0
  while getopts "a:bcdxm:" opt; do
      case $opt in
          a)
              application=${OPTARG}
              ;;
          b)
              include_backup=1
              ;;
          c)
              include_images_in_code=1
              ;;
          d)
              dryrun=1
              ;;
          x)
              include_images_on_ec2=0 # for testing
              ;;
          m)
              months=${OPTARG}
              ;;
          :)
              echo "Error: option ${OPTARG} requires an argument" 
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

  if [[ -n $2 ]]; then  
    echo "Unexpected argument: $1 $2"
    usage >&2
    exit 1
  fi

  if [[ $1 == "used" ]]; then
    get_in_use_images_csv "$include_images_on_ec2" "$include_images_in_code" "$application"
  elif [[ $1 == "account" ]]; then
    get_account_images_csv "$months" "$include_backup" | sort -t, -k3
  elif [[ $1 == "code" ]]; then
    get_code_image_names "$application"
  elif [[ $1 == "delete" ]]; then
    csv=$(get_images_to_delete_csv "$include_images_on_ec2" "$include_images_in_code" "$application" "$months" "$include_backup" | sort -t, -k3)
    delete_images "$dryrun" "$csv"
  else
    usage >&2
    exit 1
  fi
}

main "$@"
