#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

usage() {
  echo "Usage $0: [<opts>] list|delete

Where <opts>:
  -d                     Dryrun for delete command

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
  local i
  local n
  local snapshot
  local snapshots

  dryrun=$1
  shift
  IFS=$'\n'
  snapshots=($(echo "$@"))
  unset IFS
  n=${#snapshots[@]}
  echo "$n snapshot(s) to delete" >&2
  for ((i=0;i<n;i++)); do
    IFS=','
    snapshot=(${snapshots[i]})
    unset IFS
    echo "[$((i+1))/$n] aws ec2 delete-snapshot --snapshot-id ${snapshot[0]} # ${snapshot[2]} ${snapshot[4]} ${snapshot[5]} ${snapshot[6]}" >&2
    if [[ $dryrun == 0 ]]; then
      aws ec2 delete-snapshot --snapshot-id "${snapshot[0]}"
    fi
  done
}

main() {
  local snapshots
  local opt
  local dryrun

  dryrun=0
  while getopts "d" opt; do
      case $opt in
          d)
              dryrun=1
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
    delete_snapshots_csv=$(append_image_csv "$snapshots" | grep ",NoAmi" | grep 'vol-ffffffff')
    delete_snapshots "$dryrun" "$delete_snapshots_csv"
  else
    usage >&2
    exit 1
  fi
}

main "$@"
