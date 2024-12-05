#!/bin/bash
# Get GitHub Action Run stats and upload to cloudwatch metrics
# Don't forget to set your default AWS profile and github token
# export AWS_DEFAULT_PROFILE=nomis-development
# export GITHUB_TOKEN=xxxxx

set -eo pipefail

BASEDIR=$(dirname "$0")
CLOUDWATCH=0
DRYRUN=0
INTERVAL=

usage() {
  echo "Usage $0: [<opts>] -i <interval_in_seconds> -n <number_of_intervals> [<repo1>] .. [<repoN>]

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
  local repo
  local name
  local value
  local timestamp

  metric_name=$1
  repo=$2
  name=$3
  value=$4
  timestamp=$5

  if [[ $repo == 'all' && $name == 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value" "$timestamp"
  elif [[ $repo == 'all' && $name != 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value" "$timestamp" "WorkflowName=$name"
  elif [[ $repo != 'all' && $name == 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value" "$timestamp" "Repo=$repo"
  elif [[ $repo != 'all' && $name != 'all' ]]; then
    put_metric_data_dimension "$metric_name" "$value" "$timestamp" "Repo=$repo,WorkflowName=$name"
  fi
}

main() {
  round_arg=""
  verbose_arg=""

  while getopts "cdi:n:rv" opt; do
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
          n)
              NUMBER=${OPTARG}
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
  if [[ -z $INTERVAL ]]; then
    usage >&2
    exit 1
  fi

  if [[ $CLOUDWATCH == 0 ]]; then
    python3 "$BASEDIR"/github-workflow-monitor.py --interval "$INTERVAL" --number "$NUMBER" $round_arg $verbose_arg "$@"
  else
    IFS=$'\n'
    workflow_stats=($(python3 "$BASEDIR"/github-workflow-monitor.py --interval "$INTERVAL" --number "$NUMBER" $round_arg $verbose_arg "$@"))
    unset IFS

    num_stats=${#workflow_stats[@]}
    for (( i=0; i<num_stats; i++ )); do
      echo "${workflow_stats[i]}"
      [[ $i == 0 ]] && continue

      IFS=','
      workflow_stat=(${workflow_stats[i]})
      unset IFS

      timestamp=${workflow_stat[0]}
      repo=${workflow_stat[1]}
      name=${workflow_stat[2]}
      num_success=${workflow_stat[3]}
      num_failed=${workflow_stat[4]}
      put_metric_data "GitHubActionRunsSuccessCount" "$repo" "$name" "$num_success" "$timestamp"
      put_metric_data "GitHubActionRunsFailedCount" "$repo" "$name" "$num_failed" "$timestamp"
    done
  fi
}

main "$@"
