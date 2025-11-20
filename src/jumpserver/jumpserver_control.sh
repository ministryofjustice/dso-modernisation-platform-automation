#!/bin/bash

# helper script for stopping/starting jump server

DRYRUN=0
LBNAME="public-lb"
MAINTENANCE_PRIORITY=999
PORT=443
EC2TAG=gha-jumpserver-startstop
WAIT_RETRIES=60
SLEEP=10

usage() {
  echo "Usage $0: <opts> <arg1> [.. <argN>]

Where <opts>:
  -0                     Disable maintenance mode
  -1                     Enable maintenance mode
  -m                     Get maintenance mode
  -p off|on|display      Power EC2 off or on or display current state
  -t <tag>               Use a different tag such as 'Name' instead of '$EC2TAG' for selecting EC2s
  -z                     Print account name

Example Usage:
  (1) $0 -0     test                  # disable maintenance mode in test
  (2) $0 -p off preproduction         # power down EC2s in preproduction
  (3) $0 -p on  production            # power up   EC2s in production
  (4) $0 -p off -t Name t1-jump2022-1 # power off t1-jump2022-1
"
}

get_account_name() {
  local jumpserver

  jumpserver=$1
  if [[ $jumpserver =~ "t1" || $jumpserver =~ "test" ]]; then
    account_name="hmpps-domain-services-test"
  elif [[ $jumpserver =~ "pp" || $jumpserver =~ "preproduction" ]]; then
    account_name="hmpps-domain-services-preproduction"
  elif [[ $jumpserver =~ "pd" || $jumpserver =~ "production" ]]; then
    account_name="hmpps-domain-services-production"
  else
    echo "Unsupported jumpserver $jumpserver" >&2
    return 1
  fi
  echo "$account_name"
}

get_url() {
  local jumpserver

  jumpserver=$1
  if [[ $jumpserver =~ "t1" || $jumpserver =~ "test" ]]; then
    url="rdweb1.test.hmpps-domain.service.justice.gov.uk"
  elif [[ $jumpserver =~ "pp" || $jumpserver =~ "preproduction" ]]; then
    url="rdweb1.preproduction.hmpps-domain.service.justice.gov.uk"
  elif [[ $jumpserver =~ "pd" || $jumpserver =~ "production" ]]; then
    url="rdweb1.hmpps-domain.service.justice.gov.uk"
  else
    echo "Unsupported jumpserver $jumpserver" >&2
    return 1
  fi
  echo "$url"
}

get_lb_rule_json() {
  local url
  local lbarn
  local listenerarn
  local rulesjson
  local rulejson

  if ! url=$(get_url "$1"); then
    return 1
  fi
  lbarn=$(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[] | select(.LoadBalancerName=="'$LBNAME'").LoadBalancerArn')
  if [[ -z $lbarn ]]; then
    echo "Error retriving load balancer details for $LBNAME" >&2
    return 1
  fi
  listenerarn=$(aws elbv2 describe-listeners --load-balancer-arn "$lbarn" | jq -r '.Listeners[] | select(.Port=='$PORT').ListenerArn')
  if [[ -z $listenerarn ]]; then
    echo "Error retrieving load balancer HTTPS $PORT listener for $LBNAME" >&2
    return 1
  fi
  rulesjson=$(aws elbv2 describe-rules --listener-arn "$listenerarn")
  rulejson=$(jq -r '.Rules[] | select(.Conditions | length != 0) | select(.Conditions[].Values[] | contains("'"$url"'")) | select(.Actions | length != 0) | select(.Priority != "'$MAINTENANCE_PRIORITY'")' <<< "$rulesjson")

  if [[ -z $rulejson ]]; then
    echo "Error detecting weblogic lb rule" >&2
    return 1
  fi
  echo "$rulejson"
}

disable_maintenance_mode() {
  local lbrulejson
  local priority
  local num_priorities
  local rulearn

  if ! lbrulejson=$(get_lb_rule_json "$1"); then
    return 1
  fi
  rulearn=$(jq -r '.RuleArn' <<< "$lbrulejson")
  priority=$(jq -r '.Priority' <<< "$lbrulejson")
  num_priorities=$(wc -l <<< "$priority" | tr -d " ")
  if [[ -z $priority || $num_priorities != "1" ]]; then
    echo "$lbrulejson" >&2
    echo "Error detecting lb rule priority" >&2
    return 1
  fi
  if ((priority > MAINTENANCE_PRIORITY)); then
    newpriority=$((priority - 1000))
    if (( DRYRUN == 0 )); then
      echo "aws elbv2 set-rule-priorities --rule-priorities 'RuleArn=$rulearn,Priority=$newpriority'" >&2
      aws elbv2 set-rule-priorities --rule-priorities "RuleArn=$rulearn,Priority=$newpriority"
    else
      echo "Dry Run: aws elbv2 set-rule-priorities --rule-priorities 'RuleArn=$rulearn,Priority=$newpriority'" >&2
    fi
  else
    echo "maintenance mode already disabled" >&2
  fi
}

enable_maintenance_mode() {
  local lbrulejson
  local priority
  local num_priorities
  local rulearn

  if ! lbrulejson=$(get_lb_rule_json "$1"); then
    return 1
  fi
  rulearn=$(jq -r '.RuleArn' <<< "$lbrulejson")
  priority=$(jq -r '.Priority' <<< "$lbrulejson")
  num_priorities=$(wc -l <<< "$priority" | tr -d " ")
  if [[ -z $priority || $num_priorities != "1" ]]; then
    echo "$lbrulejson" >&2
    echo "Error detecting lb rule priority" >&2
    return 1
  fi
  if ((priority < MAINTENANCE_PRIORITY)); then
    newpriority=$((priority + 1000))
    if (( DRYRUN == 0 )); then
      echo "aws elbv2 set-rule-priorities --rule-priorities 'RuleArn=$rulearn,Priority=$newpriority'" >&2
      aws elbv2 set-rule-priorities --rule-priorities "RuleArn=$rulearn,Priority=$newpriority"
    else
      echo "Dry Run: aws elbv2 set-rule-priorities --rule-priorities 'RuleArn=$rulearn,Priority=$newpriority'" >&2
    fi
  else
    echo "maintenance mode already enabled" >&2
  fi
}

get_maintenance_mode() {
  local lbrulejson
  local priority
  local num_priorities

  if ! lbrulejson=$(get_lb_rule_json "$1"); then
    return 1
  fi
  priority=$(jq -r '.Priority' <<< "$lbrulejson")
  num_priorities=$(wc -l <<< "$priority" | tr -d " ")
  if [[ -z $priority || $num_priorities != "1" ]]; then
    echo "$lbrulejson" >&2
    echo "Error detecting lb rule priority" >&2
    return 1
  fi
  if ((priority < MAINTENANCE_PRIORITY)); then
    echo "disabled"
  else
    echo "enabled"
  fi
}

get_instance_state_by_tag() {
  local json
  local instance_ids
  local instance_id
  local name
  local state

  if ! json=$(aws ec2 describe-instances --no-cli-pager --filters "Name=tag:$1,Values=$2"); then
    return 1
  fi
  instance_ids=$(echo "$json" | jq -r ".Reservations[].Instances[] | .InstanceId" | sort -u)
  for instance_id in $instance_ids; do
    name=$(echo "$json" | jq -r ".Reservations[].Instances[] | select(.InstanceId==\"$instance_id\") | .Tags[] | select(.Key==\"Name\") | .Value")
    state=$(echo "$json" | jq -r ".Reservations[].Instances[] | select(.InstanceId==\"$instance_id\") | .State.Name")
    echo "$name,$instance_id,$state"
  done
  if [[ -z $instance_ids ]]; then
    echo "Cannot find any EC2 instances with tag $1=$2" >&2
    return 1
  fi
}

power() {
  local opt
  local tagvalue
  local id_and_states
  local instance_id
  local state

  set -eo pipefail
  opt=$1
  tagvalue=$2
  if ! id_and_states=$(get_instance_state_by_tag "$EC2TAG" "$tagvalue"); then
    return 1
  fi

  if [[ $opt == "display" ]]; then
    echo "$id_and_states"
  elif [[ $opt == "on" ]]; then
    n=$WAIT_RETRIES
    for ((i=1; i<=n; i++)); do
      waiting=
      exitcode=-1
      for id_and_state in $id_and_states; do
        name=$(echo "$id_and_state" | cut -d, -f1)
        instance_id=$(echo "$id_and_state" | cut -d, -f2)
        state=$(echo "$id_and_state" | cut -d, -f3)
        if [[ $state == "stopped" ]]; then
          if (( DRYRUN == 0 )); then
            echo "$name": aws ec2 start-instances --instance-ids "$instance_id" >&2
            if ! aws ec2 start-instances --instance-ids "$instance_id"; then
              exitcode=1
            fi
          else
            echo "$name": aws ec2 start-instances --instance-ids "$instance_id" --dry-run >&2
            aws ec2 start-instances --instance-ids "$instance_id" --dry-run
            exitcode=0
          fi
          waiting="$waiting $id_and_state"
        elif [[ $state == "terminated" ]]; then
          echo "Cannot start a terminated instance: $id_and_state" >&2
          exitcode=1
        elif [[ $state != "running" ]]; then
          waiting="$waiting $id_and_state"
        fi
      done
      if (( exitcode != -1 )); then
        return $exitcode
      fi
      if [[ -z $waiting ]]; then
        echo "OK:" $id_and_states
        return 0
      fi
      echo "[$i/$n] Waiting $SLEEP seconds for instance state running:$waiting" >&2
      sleep $SLEEP
      if ! id_and_states=$(get_instance_state_by_tag "$EC2TAG" "$tagvalue"); then
        return 1
      fi
    done
    echo "$name: Timed out waiting for instance to start" >&2
    return 1
  elif [[ $opt == "off" ]]; then
    n=$WAIT_RETRIES
    for ((i=1; i<=n; i++)); do
      waiting=
      exitcode=-1
      for id_and_state in $id_and_states; do
        name=$(echo "$id_and_state" | cut -d, -f1)
        instance_id=$(echo "$id_and_state" | cut -d, -f2)
        state=$(echo "$id_and_state" | cut -d, -f3)
        if [[ $state == "running" ]]; then
          if (( DRYRUN == 0 )); then
            echo "$name": aws ec2 stop-instances --instance-ids "$instance_id" >&2
            if ! aws ec2 stop-instances --instance-ids "$instance_id"; then
              exitcode=1
            fi
          else
            echo "$name": aws ec2 stop-instances --instance-ids "$instance_id" --dry-run >&2
            aws ec2 stop-instances --instance-ids "$instance_id" --dry-run
            exitcode=0
          fi
          waiting="$waiting $id_and_state"
        elif [[ $state != "stopped" && $state != "terminated" ]]; then
          waiting="$waiting $id_and_state"
        fi
      done
      if (( exitcode != -1 )); then
        return $exitcode
      fi
      if [[ -z $waiting ]]; then
        echo "OK: "$id_and_states
        return 0
      fi
      echo "[$i/$n] Waiting $SLEEP seconds for instance state stopped:$waiting" >&2
      sleep $SLEEP
      if ! id_and_states=$(get_instance_state_by_tag "$EC2TAG" "$tagvalue"); then
        return 1
      fi
    done
    echo "$name: Timed out waiting for instance to stop" >&2
    return 1
  else
    echo "$name: INTERNAL ERROR: unsupported power() option '$opt'" >&2
    return 1
  fi
}

main() {
  set -eo pipefail
  option_set=0
  account_name=0
  maintenance_mode_disable=0
  maintenance_mode_enable=0
  maintenance_mode_get=0
  power_opt=
  while getopts "01dmp:t:z" opt; do
      case $opt in
          0)
              option_set=$((option_set + 1))
              maintenance_mode_disable=1
              ;;
          1)
              option_set=$((option_set + 1))
              maintenance_mode_enable=1
              ;;
          d)
              DRYRUN=1
              ;;
          m)
              option_set=$((option_set + 1))
              maintenance_mode_get=1
              ;;
          p)
              option_set=$((option_set + 1))
              power_opt=${OPTARG}
              ;;
          t)
              EC2TAG=${OPTARG}
              ;;
          z)
              option_set=$((option_set + 1))
              account_name=1
              ;;
          :)
              echo "Error: option ${OPTARG} requires an argument" >&2
              return 1
              ;;
          ?)
              echo "Invalid option: ${OPTARG}" >&2
              echo >&2
              usage >&2
              return 1
              ;;
      esac
  done

  shift $((OPTIND-1))

  if [[ $option_set != 1 || -z $1 ]]; then
    usage >&2
    return 1
  fi

  if (( maintenance_mode_disable == 1 )); then
    if ! disable_maintenance_mode "$1"; then
      exit 1
    fi
  fi
  if (( maintenance_mode_enable == 1 )); then
    if ! enable_maintenance_mode "$1"; then
      exit 1
    fi
  fi
  if (( maintenance_mode_get == 1 )); then
    if ! get_maintenance_mode "$1"; then
      exit 1
    fi
  fi
  if (( account_name == 1 )); then
    if [[ -z $1 ]]; then
      usage >&2
      return 1
    fi
    if ! get_account_name "$1"; then
      exitcode=1
    fi
  fi
  if [[ -n $power_opt ]]; then
    if [[ -z $1 ]]; then
      usage >&2
      return 1
    fi
    for hostname; do
        if ! power "$power_opt" "$hostname"; then
          exitcode=1
        fi
    done
  fi
  return $exitcode
}

main "$@"
