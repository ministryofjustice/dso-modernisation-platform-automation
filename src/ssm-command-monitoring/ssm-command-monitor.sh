#!/bin/bash
# Get AWS SSM Command Run stats and upload to cloudwatch metrics
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

BASEDIR=$(dirname "$0")
CLOUDWATCH=0
DRYRUN=0
INTERVAL=

usage() {
  echo "Usage $0: [<opts>] -i <interval>

Where <opts>:
  -c                     Upload metrics to cloudwatch
  -d                     Dryrun - show cloudwatch aws cli commands but don't upload
  -r                     Round the time interval checked
"
}

put_metric_data_dimension() {
  if [[ -z $4 ]]; then
    if [[ $DRYRUN == 0 ]]; then
      echo "aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name '$1' --value '$2' --timestamp '$3' --region eu-west-2" >&2
      aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name "$1" --value "$2" --timestamp "$3" --region eu-west-2
    else
      echo "DRYRUN: aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name '$1' --value '$2' --timestamp '$3' --region eu-west-2" >&2
    fi
  else
    if [[ $DRYRUN == 0 ]]; then
      echo "aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name '$1' --value '$2' --timestamp '$3' --dimension '$4' --region eu-west-2" >&2
      aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name "$1" --value "$2" --timestamp "$3" --dimension "$4" --region eu-west-2
    else
      echo "DRYRUN: aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name '$1' --value '$2' --timestamp '$3' --dimension '$4' --region eu-west-2" >&2
    fi
  fi
}

put_metric_data() {
  local metric_name
  local instance_id
  local document_name
  local value
  local timestamp

  metric_name=$1
  instance_id=$2
  document_name=$3
  value=$4
  timestamp=$5

  if [[ $instance_id == 'all' && $document_name == 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value" "$timestamp"
  elif [[ $instance_id == 'all' && $document_name != 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value" "$timestamp" "DocumentName=$document_name"
  # Don't bother with instance specific metrics unless we find a need
  #elif [[ $instance_id != 'all' && $document_name == 'all' ]]; then
  #  put_metric_data_dimension "$metric_name" "$value" "$timestamp" "InstanceId=$instance_id"
  #elif [[ $instance_id != 'all' && $document_name != 'all' ]]; then
  #  put_metric_data_dimension "$metric_name" "$value" "$timestamp" "DocumentName=$document_name,InstanceId=$instance_id"
  fi
}

main() {
  round_arg=""
  verbose_arg=""

  while getopts "cdi:rv" opt; do
      case $opt in
          c)
              CLOUDWATCH=1
              ;;
          d)
              DRYRUN=1
              ;;
          i)
              INTERVAL=${OPTARG}
              ;;
          r)
              round_arg="-r"
              ;;
          v)
              verbose_arg="-vvvvv"
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

  if [[ -n $1 ]]; then
    echo "Unexpected arguments: $@"
    usage >&2
    exit 1
  fi
  if [[ -z $INTERVAL ]]; then
    usage >&2
    exit 1
  fi

  if [[ $CLOUDWATCH == 0 ]]; then
    python3 "$BASEDIR"/ssm-command-monitor.py --interval "$INTERVAL" $round_arg $verbose_arg
  else
    IFS=$'\n'
    ssm_documents=($(python3 "$BASEDIR"/ssm-command-monitor.py --interval "$INTERVAL" $round_arg $verbose_arg))
    unset IFS

    num_ssm_documents=${#ssm_documents[@]}
    for (( i=0; i<num_ssm_documents; i++ )); do
      echo "${ssm_documents[i]}"
      [[ $i == 0 ]] && continue

      IFS=','
      ssm_document=(${ssm_documents[i]})
      unset IFS

      timestamp=${ssm_document[0]}
      ec2_instance=${ssm_document[1]}
      document_name=${ssm_document[2]}
      num_success=${ssm_document[3]}
      num_failed=${ssm_document[4]}
      num_ignored=${ssm_document[5]}
      put_metric_data "SSMCommandSuccessCount" "$ec2_instance" "$document_name" "$num_success" "$timestamp"
      put_metric_data "SSMCommandFailedCount" "$ec2_instance" "$document_name" "$num_failed" "$timestamp"
      put_metric_data "SSMCommandIgnoreCount" "$ec2_instance" "$document_name" "$num_ignored" "$timestamp"
    done
  fi
}

main "$@"
