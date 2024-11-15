#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development

set -eo pipefail

BASEDIR=$(dirname "$0")
CLOUDWATCH=0
DRYRUN=0
HISTORYSECONDS=

usage() {
  echo "Usage $0: [<opts>] -s <history_to_check_in_seconds>

Where <opts>:
  -c                     Upload metrics to cloudwatch
  -d                     Dryrun - show cloudwatch aws cli commands but don't upload
"
}

put_metric_data_dimension() {
  if [[ -z $3 ]]; then
    if [[ $DRYRUN == 0 ]]; then
      echo "aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name '$1' --value '$2' --region eu-west-2" >&2
      aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name "$1" --value "$2" --region eu-west-2
    else
      echo "DRYRUN: aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name '$1' --value '$2' --region eu-west-2" >&2
    fi
  else
    if [[ $DRYRUN == 0 ]]; then
      echo "aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name '$1' --value '$2' --dimension '$3' --region eu-west-2" >&2
      aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name "$1" --value "$2" --dimension "$3" --region eu-west-2
    else
      echo "DRYRUN: aws cloudwatch put-metric-data --namespace CustomMetrics --metric-name '$1' --value '$2' --dimension '$3' --region eu-west-2" >&2
    fi
  fi    
}

put_metric_data() {
  local metric_name
  local instance_id
  local document_name
  local value

  metric_name=$1
  instance_id=$2
  document_name=$3
  value=$4
  if [[ $instance_id == 'all' && $document_name == 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value"
  elif [[ $instance_id == 'all' && $document_name != 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value" "DocumentName=$document_name"
  elif [[ $instance_id != 'all' && $document_name == 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value" "InstanceId=$instance_id"
  elif [[ $instance_id != 'all' && $document_name != 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value" "DocumentName=$document_name,InstanceId=$instance_id"
  fi
}

main() {

  while getopts "cds:" opt; do
      case $opt in
          c)
              CLOUDWATCH=1
              ;;
          d)
              DRYRUN=1
              ;;
          s)
              HISTORYSECONDS=${OPTARG}
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
  if [[ -z $HISTORYSECONDS ]]; then
    usage >&2
    exit 1
  fi

  if [[ $CLOUDWATCH == 0 ]]; then
    python3 "$BASEDIR"/ssm-command-monitor.py --seconds "$HISTORYSECONDS" -vvvv
  else
    IFS=$'\n'
    ssm_documents=($(python3 "$BASEDIR"/ssm-command-monitor.py --seconds "$HISTORYSECONDS" -vvvv))
    unset IFS

    num_ssm_documents=${#ssm_documents[@]}
    for (( i=0; i<num_ssm_documents; i++ )); do
      echo "${ssm_documents[i]}"
      [[ $i == 0 ]] && continue

      IFS=','
      ssm_document=(${ssm_documents[i]})
      unset IFS

      ec2_instance=${ssm_document[0]}
      document_name=${ssm_document[1]}
      num_success=${ssm_document[2]}
      num_failed=${ssm_document[3]}
      num_ignored=${ssm_document[4]}
      put_metric_data "SSMCommandSuccessCount" "$ec2_instance" "$document_name" "$num_success"
      put_metric_data "SSMCommandFailedCount" "$ec2_instance" "$document_name" "$num_failed"
      put_metric_data "SSMCommandIgnoreCount" "$ec2_instance" "$document_name" "$num_ignored"
    done
  fi
}

main "$@"
