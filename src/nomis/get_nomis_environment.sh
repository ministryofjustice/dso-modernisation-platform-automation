#!/bin/bash
LBNAME="private-lb"
MAINTENANCE_PRIORITY=999
PORT=443

usage() {
  echo "Usage $0: <opts> <nomis_environment>

Where <opts>:
  -a                     Print account name
  -d                     Print active weblogic target group desired count
  -h                     Print active number of healthy weblogic targets
  -t                     Print active weblogic target group arn
  -m                     Print whether maintenance mode enabled or not
  -n                     Print active weblogic target group name
  -u                     Print customer facing URL
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

get_desired_count() {
  local targetgroup
  local asgjson

  if ! targetgroup=$(get_target_group_name "$1"); then
    return 1
  fi
  asgjson=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$targetgroup") 
  if (($(jq -r '.AutoScalingGroups | length' <<< "$asgjson") != 1)); then
    echo "$asgjson" >&2
    echo "Can't find ASG" >&2
    return 1
  fi
  jq -r '.AutoScalingGroups[0].DesiredCapacity' <<< "$asgjson"
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
  echo "Retrieving load balancer config using aws elbv2 commands" >&2
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

get_maintenance_mode() {
  local lbrulejson

  if ! lbrulejson=$(get_lb_rule_json "$1"); then
    return 1
  fi
  priority=$(jq -r '.Priority' <<< "$lbrulejson")
  num_priorities=$(wc -l <<< "$priority" | tr -d "[:space:]")
  if [[ -z $priority || $num_priorities != "1" ]]; then
    echo "$lbrulejson" >&2
    echo "Error detecting weblogic lb rule priority" >&2
    return 1
  fi
  if ((priority < MAINTENANCE_PRIORITY)); then
    echo "disabled"
  else
    echo "enabled"
  fi
}

get_target_group_arn() {
  local lbrulejson
  local targetgrouparns

  if ! lbrulejson=$(get_lb_rule_json "$1"); then
    return 1
  fi
  targetgrouparns=$(jq -r '.Actions[] | select(.Type == "forward").TargetGroupArn' <<< "$lbrulejson")
  num_targetgrouparns=$(wc -l <<< "$targetgrouparns" | tr -d "[:space:]")
  if [[ -z $targetgrouparns || $num_targetgrouparns != "1" ]]; then   
    echo "$lbrulejson" >&2
    echo "Error detecting weblogic target group arn" >&2
    return 1
  fi
  echo "$targetgrouparns"
}

get_target_group_health() {
  local arn
  local json

  if ! arn=$(get_target_group_arn "$1"); then
    return 1
  fi
  json=$(aws elbv2 describe-target-health --target-group-arn "$arn")
  healthy_ec2s=$(jq -r '.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy").Target.Id' <<< "$json")
  num_healthy_ec2s=$(wc -l <<< "$healthy_ec2s" | tr -d "[:space:]")
  echo "$num_healthy_ec2s"
}

get_target_group_name() {
  local arn
  local targetgroup

  if ! arn=$(get_target_group_arn "$1"); then
    return 1
  fi
  targetgroup=$(cut -d/ -f2 <<< "$arn" | cut -d- -f1-4)
  if [[ -z $targetgroup ]]; then
    echo "Error extracting target group from arn: $arn"
    return 1
  fi
  echo "$targetgroup"
}

get_url() {
  local nomis_environment

  nomis_environment=$1
  if [[ $nomis_environment == "dev" ]]; then
    url="c-dev.development.nomis.service.justice.gov.uk"
  elif [[ $nomis_environment == "qa11r" ]]; then
    url="c-qa11r.development.nomis.service.justice.gov.uk"
  elif [[ $nomis_environment == "qa11g" ]]; then
    url="c-qa11g.development.nomis.service.justice.gov.uk"
  elif [[ $nomis_environment == "t1" ]]; then
    url="c-t1.test.nomis.service.justice.gov.uk"
  elif [[ $nomis_environment == "t2" ]]; then
    url="c-t2.test.nomis.service.justice.gov.uk"
  elif [[ $nomis_environment == "t3" ]]; then
    url="c-t3.test.nomis.service.justice.gov.uk"
  elif [[ $nomis_environment == "lsast" ]]; then
    url="c-lsast.preproduction.nomis.service.justice.gov.uk"
  elif [[ $nomis_environment == "preprod" ]]; then
    url="c.preproduction.nomis.service.justice.gov.uk"
  elif [[ $nomis_environment == "prod" ]]; then
    url="c.nomis.service.justice.gov.uk"
  else
    echo "Unsupported nomis_environment $nomis_environment" >&2
    return 1
  fi
  echo "$url"
}

main() {
  set -eo pipefail
  option_set=0
  account_name=0
  desired_count=0
  maintenance_mode=0
  target_group_arn=0
  target_group_health=0
  target_group_name=0
  url=0
  while getopts "adhmntu" opt; do
      case $opt in
          a)
              option_set=$((option_set + 1))
              account_name=1
              ;;
          d)
              option_set=$((option_set + 1))
              desired_count=1
              ;;
          h)
              option_set=$((option_set + 1))
              target_group_health=1
              ;;
          m)
              option_set=$((option_set + 1))
              maintenance_mode=1
              ;;
          n)
              option_set=$((option_set + 1))
              target_group_name=1
              ;;
          t)
              option_set=$((option_set + 1))
              target_group_arn=1
              ;;
          u)
              option_set=$((option_set + 1))
              url=1
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

  if (( account_name == 1 )); then
    if ! get_account_name "$1"; then
      exit 1
    fi
  fi
  if (( desired_count == 1 )); then
    if ! get_desired_count "$1"; then
      exit 1
    fi
  fi
  if (( maintenance_mode == 1 )); then
    if ! get_maintenance_mode "$1"; then
      exit 1
    fi
  fi
  if (( target_group_arn == 1 )); then
    if ! get_target_group_arn "$1"; then
      exit 1
    fi
  fi
  if (( target_group_health == 1 )); then
    if ! get_target_group_health "$1"; then
      exit 1
    fi
  fi
  if (( target_group_name == 1 )); then
    if ! get_target_group_name "$1"; then
      exit 1
    fi
  fi
  if (( url == 1 )); then
    if ! get_url "$1"; then
      exit 1
    fi
  fi
}

main "$@"
