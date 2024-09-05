#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

usage() {
  echo "Usage $0: [<opts>] list|delete

Where <opts>:
  -d                     Dryrun for delete command
  -s <file>              Output AWS shell commands to file

And:
  list                   List all snapshots along with associated AMI
  delete                 Delete unused snapshots
"
}

get_images_csv() {
  local json
  local this_account_id

  set -eo pipefail
  echo aws sts get-caller-identity --query Account --output text >&2
  this_account_id=$(aws sts get-caller-identity --query Account --output text)
  echo aws ec2 describe-images --owners "$this_account_id" >&2
  json=$(aws ec2 describe-images --owners "$this_account_id")
  jq -r ".Images[] | [.ImageId, .OwnerId, .CreationDate, .Public, .Name] | @csv" <<< "$json" | sed 's/"//g'
}

get_snapshots_csv() {
  local json
  local this_account_id

  set -eo pipefail
  echo aws sts get-caller-identity --query Account --output text >&2
  this_account_id=$(aws sts get-caller-identity --query Account --output text)
  echo aws ec2 describe-snapshots --no-paginate --filters "Name=owner-id,Values=$this_account_id" >&2
  json=$(aws ec2 describe-snapshots --no-paginate --filters "Name=owner-id,Values=$this_account_id")
  jq -r ".Snapshots[] | [.SnapshotId, .OwnerId, .StartTime, .VolumeId, .Description] | @csv" <<< "$json" | sed 's/"//g'
}

parse_snapshot_description_csv() {
  local ami
  local description
  local type
  local i
  local n 
  local snapshot
  local snapshots

  set -eo pipefail
  IFS=$'\n'
  snapshots=($(echo "$@"))
  unset IFS
  n=${#snapshots[@]}
  echo "Parsing $n snapshot description(s)" >&2
  for ((i=0;i<n;i++)); do
    IFS=','
    snapshot=(${snapshots[i]})
    unset IFS
    ami=
    type=Other
    description=
    if [[ ${snapshot[4]} == "Created by CreateImage"* ]]; then
      type=CreateImage
      ami=$(grep -Eo 'ami-[^ ]*' <<< "${snapshot[4]}")
      description=$(grep -Eo '\(i-[^)]*' <<< "${snapshot[4]}" | cut -c2-)
    elif [[ ${snapshot[4]} == "Copied for DestinationAmi"* ]]; then
      type=Copied
      ami=$(grep -Eo 'DestinationAmi ami-[^ ]*' <<< "${snapshot[4]}" | cut -d\  -f2)
      description=$(grep -Eo 'SourceAmi ami-[^ ]*' <<< "${snapshot[4]}" | cut -d\  -f2)
    else
      description="${snapshot[4]}"
    fi
    echo "${snapshot[0]},${snapshot[1]},${snapshot[2]},${snapshot[3]},${type},${ami},${description}"
  done
}

append_image_csv() {
  local snapshots
  local images
  local joined
  local n

  set -eo pipefail
  snapshots=$(sort -t, -k6 <<< "$@")
  images=$(get_images_csv | sort -t, -k1)
  n=$(echo "$images" | wc -l | tr -d [[:space:]])
  echo "Joining snapshot with $n image(s)" >&2
  joined=$(join -o 1.1,1.2,1.3,1.4,1.5,1.6,1.7,2.3,2.5  -t, -1 6 -2 1  <(echo "$snapshots") <(echo "$images"))
  unjoined=$(comm -23 <(echo "$snapshots" | sort) <(echo "$joined" | cut -d, -f1-7 | sort))
  echo "$joined"
  echo "$unjoined" | sed 's/$/,NoAmi,NoAmi/'
}

delete_snapshots() {
  local dryrun
  local aws_cmd_file
  local i
  local n
  local snapshot
  local snapshots

  dryrun=$1
  aws_cmd_file=$2
  shift 2
  IFS=$'\n'
  snapshots=($(echo "$@"))
  unset IFS
  n=${#snapshots[@]}
  if [[ $dryrun == 0 ]]; then
    echo "deleting $n snapshot(s)" >&2
  else
    echo "DRY RUN: would delete $n snapshot(s)" >&2
  fi
  for ((i=0;i<n;i++)); do
    IFS=','
    snapshot=(${snapshots[i]})
    unset IFS
    if [[ $dryrun == 0 ]]; then
      echo -n "[$((i+1))/$n] " >&2
    fi
    echo "aws ec2 delete-snapshot --snapshot-id ${snapshot[0]} # ${snapshot[2]} ${snapshot[4]} ${snapshot[5]} ${snapshot[6]}" >&2
    if [[ -n $aws_cmd_file ]]; then
      echo "aws ec2 delete-snapshot --snapshot-id ${snapshot[0]} # ${snapshot[2]} ${snapshot[4]} ${snapshot[5]} ${snapshot[6]}" >> "$aws_cmd_file"
    fi
    if [[ $dryrun == 0 ]]; then
      aws ec2 delete-snapshot --snapshot-id "${snapshot[0]}" >&2
    fi
  done
}

main() {
  local aws_cmd_file
  local snapshots
  local opt
  local dryrun

  aws_cmd_file=
  dryrun=0
  while getopts "ds:" opt; do
      case $opt in
          d)
              dryrun=1
              ;;
          s)
              aws_cmd_file=${OPTARG}
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

  if [[ $1 == "list_snapshots_only" ]]; then
    get_snapshots_csv
  elif [[ $1 == "list_parse_description" ]]; then
    parse_snapshot_description_csv "$(get_snapshots_csv)"
  elif [[ $1 == "list" ]]; then
    snapshots=$(parse_snapshot_description_csv "$(get_snapshots_csv)")
    append_image_csv "$snapshots"
  elif [[ $1 == "delete" ]]; then
    snapshots=$(parse_snapshot_description_csv "$(get_snapshots_csv)")
    delete_snapshots_csv=$(append_image_csv "$snapshots" | grep ",NoAmi" | grep 'vol-ffffffff' || true)
    delete_snapshots "$dryrun" "$aws_cmd_file" "$delete_snapshots_csv"
  else
    usage >&2
    exit 1
  fi
}

main "$@"
