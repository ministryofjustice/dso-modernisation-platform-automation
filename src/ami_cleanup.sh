#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

# defaults
aws_cmd_file=
months=
application=
include_backup=0
include_images_in_code=0
include_images_on_ec2=1
dryrun=0
valid_actions=("used" "account" "code" "delete")
profile=''
aws_error_log='aws_error.log'

usage() {
  echo -e "Usage:\n $0 [<opts>] $(IFS='|'; echo "${valid_actions[*]}")

Where <opts>:
  -a <application>       Specify which application for images e.g. nomis or core-shared-services. Needed for core-shared-services or when looking in code (-c)
  -b                     Optionally include AwsBackup images
  -c                     Also include images referenced in code
  -d                     Dryrun for delete command
  -e <environment>       Specify which environment for images e.g. production (only needed for core-shared-services)
  -m <months>            Exclude images younger than this number of months
  -s <file>              Output AWS shell commands to file

And:
  used                   List all images in use (and -c flag to include code)
  account                List all images in the current account
  code                   List all image names referenced in code
  delete                 Delete unused images

e.g.
  export AWS_DEFAULT_PROFILE=nomis-test
  $0 -a core-shared-services -d -m 2 -s amis_del.txt delete   # dryrun, see which AMIs are not used and are older than 2 months in core-shared-services
  or
  export AWS_DEFAULT_PROFILE=nomis-test
  $0 -a nomis -c used                                         # in nomis-test list AMIs in use by ec2s or in code
  or
  export AWS_DEFAULT_PROFILE=oasys-preproduction
  $0 account                                                  # in oasys-preproduction list all AMIs in the account
"
}

main() {
  parse_inputs "$@"
  set_date_cmd
  case $action in
    used)
      get_in_use_images_csv "$include_images_on_ec2" "$include_images_in_code" "$application" ;;
    account)
      get_account_images_csv "$months" "$include_backup" | sort -t, -k3 ;;
    code)
      get_code_image_names "$application" ;;
    delete)
      csv=$(get_images_to_delete_csv "$include_images_on_ec2" "$include_images_in_code" "$application" "$months" "$include_backup" | sort -t, -k3)
      delete_images "$dryrun" "$aws_cmd_file" "$csv" ;;
    *)
      usage >&2
      exit 1 ;;
  esac
  cleanup
}

parse_inputs() {
  while getopts "a:bcdxm:s:" opt; do
      case $opt in
          a)  application=${OPTARG} ;;
          b)  include_backup=1 ;;
          c)  include_images_in_code=1 ;;
          d)  dryrun=1 ;;
          x)  include_images_on_ec2=0 ;; # for testing
          m)  months=${OPTARG} ;;
          s)  aws_cmd_file=${OPTARG} ;;
          :)  echo "Error: option ${OPTARG} requires an argument" ;;
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

  action=$1
  if [[ "$application" == "core-shared-services" ]]; then 
    profile="--profile $application-production"
  fi
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

date_minus_month() {
  local month=$1
  shift
  $date_cmd -d "-${month} month" "$@"
}

date_minus_year() {
  local year=$1
  shift
  $date_cmd -d "-${year} year" "$@"
}

get_date_filter() {
  local date_filter
  local i
  local m=$1
  local m1=$(date_minus_month "$m" "+%m")
  local m2=${m1#0}
  local m3=$((m+m2))
  
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
  echo "$date_filter"
}

get_account_images_csv() {
  local months=$1
  local include_backup=$2  
  
  if [[ -z $months ]]; then
    filters=''
  else
    local date_filter=$(get_date_filter "$months")
    filters="--filters Name=creation-date,Values=$date_filter"
  fi

  local csv=$(aws ec2 describe-images $filters $profile \
           --owners self \
           --query 'Images[].[ImageId, OwnerId, CreationDate, Public, Name]' \
           --output text 2> $aws_error_log | \
           awk '{print $1","$2","$3","$4","$5}')
  check_aws_error

  if [[ $include_backup == 0 ]]; then
    echo "$csv" | grep -v AwsBackup || true
  else
    echo "$csv"
  fi
}

get_usage_report_csv() {
  local account_images=($(get_account_images_csv $months $include_backup))
  for ami in "${account_images[@]}"; do
    IFS=',' read -r image_id owner_id creation_date public name <<< "$ami"
    report_id=$(aws ec2 create-image-usage-report $profile \
                  --image-id $image_id \
                  --resource-types ResourceType=ec2:Instance 'ResourceType=ec2:LaunchTemplate,ResourceTypeOptions=[{OptionName=version-depth,OptionValues=100}]' \
                  --output text 2>/dev/null || true)
    # on failure, assume in use
    if [[ -z "$report_id" ]]; then
      echo $ami
      continue
    fi
    
    report_usage=""
    for attempt in {1..3}; do
      report_usage=$(
        set +e
        aws ec2 describe-image-usage-report-entries $profile \
          --report-id "$report_id" \
          --output text 2>&1
        echo "__EXITCODE__$?"
      )
      status=$(echo "$report_usage" | awk -F'__EXITCODE__' '{print $2}')
      report_usage=$(echo "$report_usage" | sed 's/__EXITCODE__.*//')
      [[ -n "$report_usage" ]] && break
      sleep 30
    done
      
    [[ $status -ne 0 ]]      && echo $ami && continue # aws command failed, assume used
    [[ -n "$report_usage" ]] && echo $ami && continue # command succeed and has data
  done
}

get_ec2_instance_images_csv() {
  if [[ "$application" == "core-shared-services" ]]; then
    get_usage_report_csv
  else
    local ids=($(aws ec2 describe-instances $profile \
            --query "Reservations[*].Instances[*].ImageId" \
            --output text 2> $aws_error_log | sort | uniq))
    check_aws_error
    local csv=$(aws ec2 describe-images $profile \
            --image-ids "${ids[@]}" \
            --query 'Images[].[ImageId, OwnerId, CreationDate, Public, Name]' \
            --output text 2> $aws_error_log | \
            awk '{print $1","$2","$3","$4","$5}')
    check_aws_error
    echo "$csv"
  fi
}

get_code_image_names() {
  local app=$1
  local envdir
  local tf_files
  
  if [[ "$app" == "core-shared-services" ]]; then 
    envdir=$(dirname "$0")/../../modernisation-platform/terraform/environments/core-shared-services
  else 
    envdir=$(dirname "$0")/../../modernisation-platform-environments/terraform/environments/$app
  fi
  if [[ ! -d "$envdir" ]]; then
    echo "Cannot find $envdir" >&2
    exit 1
  fi
  if [[ -n $app ]]; then
    tf_files="${envdir}/*.tf" 
  else
    tf_files="${envdir}/*/*.tf"
  fi
  grep -Eo 'ami_name[[:space:]]*=[[:space:]]*"[^"]*"' $tf_files | cut -d\" -f2 | sort -u | grep -vF '*' | sort -u || true
}

get_code_csv() {
  local ami=$(get_account_images_csv 0 | sort -t, -k5)
  local code=$(get_code_image_names "$1")
  join -o 1.1,1.2,1.3,1.4,1.5  -t, -1 5 <(echo "$ami") <(echo "$code")
}

get_ec2_and_code_csv() {
  local ami=$(get_account_images_csv 0 | sort -t, -k5)
  local code=$(get_code_image_names "$1")
  local amicode=$(join -o 1.1,1.2,1.3,1.4,1.5  -t, -1 5 <(echo "$ami") <(echo "$code") | sort)
  local ec2=$(get_ec2_instance_images_csv | sort)
  comm <(echo "$amicode") <(echo "$ec2") | tr -d ' ' | tr -d '\t'
}

get_in_use_images_csv() {
  local ec2=$1
  local code=$2
  local application=$3

  if [[ $ec2 == 1 && $code == 1 ]]; then
    get_ec2_and_code_csv "$application"
  elif [[ $ec2 == 1 ]]; then
    get_ec2_instance_images_csv
  elif [[ $code == 1 ]]; then
    get_code_csv "$application"
  else
    echo "Need either include_images_in_code or include_images_in_ec2 to be set" >&2
    return 1
  fi
}

get_images_to_delete_csv() {
  local in_use_amis=$(get_in_use_images_csv "$1" "$2" "$3" | sort)
  local account_amis=$(get_account_images_csv "$4" "$5" | sort)
  comm -23 <(echo "$account_amis") <(echo "$in_use_amis") 
}

delete_images() {
  local dryrun=$1
  local aws_cmd_file=$2
  local i
  local id
  local ids
  local n

  shift 2
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
    if [[ -n $aws_cmd_file ]]; then
      echo "aws ec2 deregister-image --image-id ${id[0]} # ${id[2]} ${id[4]}" >> "$aws_cmd_file"
    fi
    if [[ $dryrun == 0 ]]; then
      echo thing
      #aws ec2 deregister-image --image-id "${id[0]}" >&2
    fi
  done
}

check_aws_error() {
  if [[ -s $aws_error_log ]]; then
    echo "AWS CLI returned an error:"
    cat $aws_error_log
    cleanup
    exit 1
  fi
}

cleanup() {
  [[ -f $aws_error_log ]] && rm $aws_error_log
}

main "$@"
