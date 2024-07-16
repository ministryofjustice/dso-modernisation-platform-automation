#!/bin/bash
AWS_ACCOUNT_NAME=
CMS_NAMES=
PROCESSING_NAMES=
TOMCAT_NAMES=
EC2_RUN_SCRIPT=$(dirname "$0")/../run_script_on_ec2.sh

set -eo pipefail

usage() {
  echo "Usage $0: <opts> <nomis_combined_reporting_environemnt>

Where <opts>:
  -0                     Stop BIP
  -1                     Start BIP
  -d                     Run in dryrun mode
  -z                     Print account name

Examples:
To stop t1:  $0 -0 t1
To start t1: $0 -1 t1
"
}

set_environment_vars() {
  nomis_combined_reporting_environment=$1
  if [[ $nomis_combined_reporting_environment == "dev" ]]; then
    AWS_ACCOUNT_NAME="nomis-combined-reporting-development"
  elif [[ $nomis_combined_reporting_environment == "t1" ]]; then
    AWS_ACCOUNT_NAME="nomis-combined-reporting-test"
  elif [[ $nomis_combined_reporting_environment == "lsast" ]]; then
    AWS_ACCOUNT_NAME="nomis-combined-reporting-preproduction"
  elif [[ $nomis_combined_reporting_environment == "preprod" ]]; then
    AWS_ACCOUNT_NAME="nomis-combined-reporting-preproduction"
    CMS_NAMES="pp-ncr-cms-a pp-ncr-cms-b"
    PROCESSING_NAMES="pp-ncr-processing-a"
    TOMCAT_NAMES="pp-ncr-web-admin-a pp-ncr-web-a pp-ncr-web-b"
  elif [[ $nomis_combined_reporting_environment == "prod" ]]; then
    AWS_ACCOUNT_NAME="nomis-combined-reporting-production"
  else
    echo "Unsupported AWS_ACCOUNT_NAME $AWS_ACCOUNT_NAME" >&2
    return 1
  fi
}

start_ncr() {
  local ec2name
  local stdout
  local stderr

  stderr=$(mktemp)
  for ec2name in $CMS_NAMES; do
    # run start server bash script on cms machines a then b
     echo "$ec2name: start"
     if ! stdout=$($EC2_RUN_SCRIPT first "$ec2name" "StartNCR" 'sudo su bobj && . ~/.bash_profile && /u01/app/bobj/BIP4/sap_bobj/ccm.sh -start all' 2>$stderr); then
       cat $stderr >&2
       echo "ERROR: $ec2name: $stdout"
       rm -f $stderr
       exit 1
     fi
     echo "$ec2name: $stdout"
  done
  for ec2name in $PROCESSING_NAMES; do
    # run start server bash script on processing nodes
    echo "$ec2name: start"
    if ! stdout=$($EC2_RUN_SCRIPT first "$ec2name" "StartNCR" 'sudo su bobj && . ~/.bash_profile && /u01/app/bobj/BIP4/sap_bobj/ccm.sh -start all' 2>$stderr); then
       cat $stderr >&2
       echo "ERROR: $ec2name: $stdout"
       rm -f $stderr
       exit 1
     fi
     echo "$ec2name: $stdout"
  done
  for ec2name in $TOMCAT_NAMES; do
    # run start server bash script on tomcat web servers
    echo "$ec2name: start"
    if ! stdout=$($EC2_RUN_SCRIPT first "$ec2name" "StartNCR" 'sudo su bobj && . ~/.bash_profile && /u01/app/bobj/BIP4/sap_bobj/ccm.sh -start all' 2>$stderr); then
       cat $stderr >&2
       echo "ERROR: $ec2name: $stdout"
       rm -f $stderr
       exit 1
     fi
     echo "$ec2name: $stdout"
  done
  rm -f $stderr
}

stop_ncr() {
  local ec2name

  for ec2name in $TOMCAT_NAMES; do
    # run stop server bash script on tomcat web servers
    echo "$ec2name: stop"
    if ! stdout=$($EC2_RUN_SCRIPT first "$ec2name" "StartNCR" 'sudo su bobj && . ~/.bash_profile && /u01/app/bobj/BIP4/sap_bobj/ccm.sh -stop all' 2>$stderr); then
       cat $stderr >&2
       echo "ERROR: $ec2name: $stdout"
       rm -f $stderr
       exit 1
     fi
     echo "$ec2name: $stdout"
  done
  for ec2name in $PROCESSING_NAMES; do
    # run stop server bash script on processing nodes
    echo "$ec2name: stop"
    if ! stdout=$($EC2_RUN_SCRIPT first "$ec2name" "StartNCR" 'sudo su bobj && . ~/.bash_profile && /u01/app/bobj/BIP4/sap_bobj/ccm.sh -stop all' 2>$stderr); then
       cat $stderr >&2
       echo "ERROR: $ec2name: $stdout"
       rm -f $stderr
       exit 1
     fi
     echo "$ec2name: $stdout"
  done
  for ec2name in $CMS_NAMES; do
    # run stop server bash script on cms machines b then a
    echo "$ec2name: stop"
    if ! stdout=$($EC2_RUN_SCRIPT first "$ec2name" "StartNCR" 'sudo su bobj && . ~/.bash_profile && /u01/app/bobj/BIP4/sap_bobj/ccm.sh -stop all' 2>$stderr); then
       cat $stderr >&2
       echo "ERROR: $ec2name: $stdout"
       rm -f $stderr
       exit 1
     fi
     echo "$ec2name: $stdout"
  done
}

main() {
  account_name=0
  start=0
  stop=0
  option_set=0
  while getopts "01dz" opt; do
      case $opt in
          0)
              stop=1
              option_set=$((option_set+1))
              ;;
          1)
              start=1
              option_set=$((option_set+1))
              ;;
          d)
              DRYRUN=1
              ;;
          z)
              account_name=1
              option_set=$((option_set+1))
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

  if [[ -z $1 || -n $2 || $option_set != 1 ]]; then
    usage >&2
    exit 1
  fi
  if ! set_environment_vars "$1"; then
    exit 1
  fi
  if [[ ! -x $EC2_RUN_SCRIPT ]]; then
    echo "Could not find $EC2_RUN_SCRIPT" >&2
    exit 1
  fi
  if ((account_name == 1)); then
    echo $AWS_ACCOUNT_NAME
  elif ((start == 1)); then
    start_ncr
  elif ((stop == 1)); then
    stop_ncr
  else
    usage >&2
    exit 1
  fi
}

main "$@"
