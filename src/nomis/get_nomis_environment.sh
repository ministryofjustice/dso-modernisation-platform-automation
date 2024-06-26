#!/bin/bash


usage() {
  echo "Usage $0: <opts> <nomis_environment>

Where <opts>:
  -a                     Print account name
  -w                     Print weblogic ASG which has the most instances
"
}

get_account_name() {
  local nomis_environment

  nomis_environment=$1
  if [[ $nomis_environment == "dev" ]]; then
    account_name="nomis-development"
  elif [[ $nomis_environment == "qa11r" ]]; then
    account_name="nomis-development"
  elif [[ $nomis_environment == "qa11g" ]]; then
    account_name="nomis-development"
  elif [[ $nomis_environment == "t1" ]]; then
    account_name="nomis-test"
  elif [[ $nomis_environment == "t2" ]]; then
    account_name="nomis-test"
  elif [[ $nomis_environment == "t3" ]]; then
    account_name="nomis-test"
  elif [[ $nomis_environment == "lsast" ]]; then
    account_name="nomis-preproduction"
  elif [[ $nomis_environment == "preprod" ]]; then
    account_name="nomis-preproduction"
  elif [[ $nomis_environment == "prod" ]]; then
    account_name="nomis-production"
  else
    echo "Unsupported nomis_environment $nomis_environment" >&2
    return 1
  fi
  echo "$account_name"
}

get_weblogic() {
  local nomis_environment

  set -eo pipefail

  account_id=$(aws sts get-caller-identity --query Account --output text)
  if [[ -z $account_id ]]; then
    echo "Check AWS credentials, could not retrieve account id" >&2
    return 1
  fi
  nomis_environment=$1
  asg_a="${nomis_environment}-nomis-web-a"
  asg_b="${nomis_environment}-nomis-web-b"
  echo "Describe instances for $asg_a and $asg_b" >&2
  asg_a_count=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${asg_a}" "Name=instance-state-name,Values=running" | jq '.Reservations | length')
  asg_b_count=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${asg_b}" "Name=instance-state-name,Values=running" | jq '.Reservations | length')
  if ((asg_a_count == 0)); then
    if ((asg_b_count == 0)); then
      echo "No running instances in either $asg_a or $asg_b" >&2
      return 1
    else
      echo "$asg_b"
    fi
  elif ((asg_a_count >= asg_b_count)); then
    echo "$asg_a"
  else
    echo "$asg_b"
  fi
}

main() {
  set -eo pipefail
  option_set=0
  account_name=0
  weblogic=0
  while getopts "aw" opt; do
      case $opt in
          a)
              option_set=1
              account_name=1
              ;;
          w)
              option_set=1
              weblogic=1
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

  if [[ -z $1 || -n $2 || $option_set == 0 ]]; then
    usage >&2
    exit 1
  fi

  if (( account_name == 1 )); then
    if ! get_account_name "$1"; then
      exit 1
    fi
  fi
  if (( weblogic == 1 )); then
    if ! get_weblogic "$1"; then
      exit 1
    fi
  fi
}

main "$@"
