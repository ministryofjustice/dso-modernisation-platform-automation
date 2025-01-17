#!/bin/bash
#
# Helper script for starting/stopping BIP environment cleanly
#
# To shutdown environment cleanly as per https://me.sap.com/notes/0002390652:
# See usage for more detail

DRYRUN=0
VERBOSE=0
LBS=
EC2_RUN_SCRIPT=$(dirname "$0")/../run_script_on_ec2.sh
STAGE3_WAIT_SECS=600

usage() {
  echo "Usage $0: <opts> <cmd>

Where <opts>:
  -3 wait_secs              Override default pipeline stage 3 wait time
  -d                        Enable dryrun for maintenance mode commands
  -e <env>                  Set nomis-combined-reporting environment
  -l public|private|admin   Select LB endpoint(s)
  -v                        Enable verbose debug

Where <cmd>:
  ec2        display                                  - display status of ec2s
  env        aws-account                              - display aws account name
  lb         maintenance-mode    enable|disable|check - enable, disable or check maintenance mode on given LB
  lb         get-target-group    arn|health|name      - get target group ARN, health or name on given LB
  lb         get-json            rules|rule           - debug lb json
  pipeline   start|stop|shutdown all|012345678        - start and stop services with given stages/steps, use dryrun flag to check, shutdown stops EC2 as well

For pipeline stop and shutdown, below steps are run 0 through to 8
For pipeline start, below steps are run in reverse order 8 through to 0:
  STAGE      STOP          START    DESCRIPTION
  0          enable     or disable  maintenance mode on LB
  1          stop       or start    on web servers
  2          disable    or enable   all BIP servers barring CMS and FRS
  3          wait 10 minutes
  4          stop       or start    BIP event servers
  5          stop       or start    BIP job servers
  6          stop       or start    BIP processing servers
  7          stop       or start    all other servers
  8          stop       or start    SIA
" >&2
  return 1
}

debug() {
  if ((VERBOSE != 0)); then
    echo "DEBUG: $*" >&2
  fi
}

dryrun_debug() {
  if ((DRYRUN != 0)); then
    echo "DRYRUN: $*" >&2
  elif ((VERBOSE != 0)); then
    echo "DEBUG: $*" >&2
  fi
}

error() {
  echo "$@" >&2
}

set_env_variables() {
  PUBLIC_LB_NAME=public-lb
  PUBLIC_LB_RULE_MAINTENANCE_PRIORITY=999
  PUBLIC_LB_PORT=443
  PUBLIC_LB_BACKEND_PORT=7777
  PRIVATE_LB_NAME=private-lb
  PRIVATE_LB_RULE_MAINTENANCE_PRIORITY=999
  PRIVATE_LB_PORT=7777
  PRIVATE_LB_BACKEND_PORT=7777
  ADMIN_LB_NAME=public-lb
  ADMIN_LB_RULE_MAINTENANCE_PRIORITY=999
  ADMIN_LB_PORT=443
  ADMIN_LB_BACKEND_PORT=7010

  if [[ $NCR_ENVIRONMENT == t1 ]]; then
    AWS_ACCOUNT=nomis-combined-reporting-test
    ADMIN_URL=t1.test.reporting.nomis.service.justice.gov.uk
    PUBLIC_LB_URL=t1.test.reporting.nomis.service.justice.gov.uk
    PRIVATE_LB_URL=t1-int.test.reporting.nomis.service.justice.gov.uk
    EXPECTED_WEBADMIN_EC2_COUNT=0
    EXPECTED_WEB_EC2_COUNT=1
    if [[ -z $LBS ]]; then
      LBS="private public"
    fi
  elif [[ $NCR_ENVIRONMENT == ls ]]; then
    AWS_ACCOUNT=nomis-combined-reporting-preproduction
    ADMIN_URL=ls.preproduction.reporting.nomis.service.justice.gov.uk
    PUBLIC_LB_URL=ls.preproduction.reporting.nomis.service.justice.gov.uk
    PRIVATE_LB_URL=ls-int.preproduction.reporting.nomis.service.justice.gov.uk
    EXPECTED_WEBADMIN_EC2_COUNT=0
    EXPECTED_WEB_EC2_COUNT=1
    if [[ -z $LBS ]]; then
      LBS="private public"
    fi
  elif [[ $NCR_ENVIRONMENT == pp ]]; then
    AWS_ACCOUNT=nomis-combined-reporting-preproduction
    ADMIN_URL=admin.preproduction.reporting.nomis.service.justice.gov.uk
    PUBLIC_LB_URL=preproduction.reporting.nomis.service.justice.gov.uk
    PRIVATE_LB_URL=int.preproduction.reporting.nomis.service.justice.gov.uk
    EXPECTED_WEBADMIN_EC2_COUNT=1
    EXPECTED_WEB_EC2_COUNT=1
    if [[ -z $LBS ]]; then
      LBS="private public admin"
    fi
  elif [[ $NCR_ENVIRONMENT == pd ]]; then
    AWS_ACCOUNT=nomis-combined-reporting-production
    ADMIN_URL=admin.reporting.nomis.service.justice.gov.uk
    PUBLIC_LB_URL=reporting.nomis.service.justice.gov.uk
    PRIVATE_LB_URL=int.reporting.nomis.service.justice.gov.uk
    EXPECTED_WEBADMIN_EC2_COUNT=1
    EXPECTED_WEB_EC2_COUNT=4
    if [[ -z $LBS ]]; then
      LBS="private public admin"
    fi
  else
    error "Unsupported nomis-combined-reporting-environment value '$NCR_ENVIRONMENT'"
    return 1
  fi
}

get_ec2_status_json() {
  debug "aws ec2 describe-instance-status --filters 'Name=tag:nomis-combined-reporting-environment,Values=$NCR_ENVIRONMENT'"
  if ! aws ec2 describe-instance-status --no-cli-pager; then
    return 1
  fi
}

get_ec2_server_info() {
  # return space separated list of ec2_name:instance_id:running_status
  local json
  local ec2id
  local ec2ids
  local name
  local status

  debug "aws ec2 describe-instances --filters 'Name=tag:nomis-combined-reporting-environment,Values=$NCR_ENVIRONMENT' 'Name=tag:$1,Values=$2'"
  if ! json=$(aws ec2 describe-instances --no-cli-pager --filters "Name=tag:nomis-combined-reporting-environment,Values=$NCR_ENVIRONMENT" "Name=tag:$1,Values=$2"); then
    return 1
  fi
  ec2ids=$(jq -r ".Reservations[].Instances[].InstanceId" <<< "$json")
  (
    for ec2id in $ec2ids; do
      if ! name=$(jq -r ".Reservations[].Instances[] | select(.InstanceId==\"$ec2id\") | .Tags[] | select(.Key==\"Name\") | .Value" <<< "$json"); then
        return 1
      fi
      if ! status=$(jq -r ".Reservations[].Instances[] | select(.InstanceId==\"$ec2id\") | .State.Name" <<< "$json"); then
        return 1
      fi
      if [[ -z $name || -z $status ]]; then
        error "Unable to retrieve name and/or status for $ec2id; name=$name, status=$status"
        return 1
      fi
      echo "$name:$ec2id:$status"
    done
  ) | xargs
}

set_env_ec2_info() {
  if ! CMS_EC2_INFO=$(get_ec2_server_info "server-type" "ncr-bip-cms"); then
    return 1
  fi
  if ! APP_EC2_INFO=$(get_ec2_server_info "server-type" "ncr-bip-app"); then
    return 1
  fi
  if ! WEB_EC2_INFO=$(get_ec2_server_info "server-type" "ncr-web"); then
    return 1
  fi
  if ! WEBADMIN_EC2_INFO=$(get_ec2_server_info "server-type" "ncr-webadmin"); then
    return 1
  fi
  if [[ -z $APP_EC2_INFO && -z $CMS_EC2_INFO ]]; then
    error "Error retrieving EC2 info with ncr-bip-cms and ncr-bip-app tags"
    return 1
  fi
}

set_env_lb() {
  if [[ $1 == "public" ]]; then
    LB_NAME=$PUBLIC_LB_NAME
    LB_RULE_MAINTENANCE_PRIORITY=$PUBLIC_LB_RULE_MAINTENANCE_PRIORITY
    LB_PORT=$PUBLIC_LB_PORT
    LB_BACKEND_PORT=$PUBLIC_LB_BACKEND_PORT
    LB_URL=$PUBLIC_LB_URL
  elif [[ $1 == "private" ]]; then
    LB_NAME=$PRIVATE_LB_NAME
    LB_RULE_MAINTENANCE_PRIORITY=$PRIVATE_LB_RULE_MAINTENANCE_PRIORITY
    LB_PORT=$PRIVATE_LB_PORT
    LB_BACKEND_PORT=$PRIVATE_LB_BACKEND_PORT
    LB_URL=$PRIVATE_LB_URL
  elif [[ $1 == "admin" ]]; then
    if [[ $ADMIN_URL == "$PUBLIC_LB_URL" ]]; then
      error "No specific admin endpoint for this environment"
      return 1
    fi
    LB_NAME=$ADMIN_LB_NAME
    LB_RULE_MAINTENANCE_PRIORITY=$ADMIN_LB_RULE_MAINTENANCE_PRIORITY
    LB_PORT=$ADMIN_LB_PORT
    LB_BACKEND_PORT=$ADMIN_LB_BACKEND_PORT
    LB_URL=$ADMIN_URL
  else
    error "Unexpected lb '$1', expected public or private"
    return 1
  fi
}

lb_get_listener_rules_json() {
  local lbarn
  local listenerarn

  debug "aws elbv2 describe-load-balancers"
  lbarn=$(aws elbv2 describe-load-balancers --no-cli-pager | jq -r '.LoadBalancers[] | select(.LoadBalancerName=="'"$LB_NAME"'").LoadBalancerArn')
  if [[ -z $lbarn ]]; then
    error "Error retriving load balancer details for $LB_NAME"
    return 1
  fi
  debug "aws elbv2 describe-listeners --load-balancer-arn '$lbarn'"
  listenerarn=$(aws elbv2 describe-listeners --load-balancer-arn "$lbarn" --no-cli-pager | jq -r '.Listeners[] | select(.Port=='"$LB_PORT"').ListenerArn')
  if [[ -z $listenerarn ]]; then
    error "Error retrieving load balancer port $LB_PORT listener for $LB_NAME"
    return 1
  fi
  debug "aws elbv2 describe-rules --listener-arn '$listenerarn'"
  aws elbv2 describe-rules --listener-arn "$listenerarn" --no-cli-pager
}

lb_get_rule_json() {
  local rules_json
  local rules_json1
  local rules_json2
  local rules_json3
  local num_rules

  if ! rules_json1=$(lb_get_listener_rules_json); then
    return 1
  fi
  if ! rules_json2=$(jq '.Rules[] | select(.Actions | length != 0)' <<< "$rules_json1"); then
    debug "$rules_json1"
    error "Error finding rules with actions"
    return 1
  fi
  if ! rules_json3=$(jq -s '.[] | select(.Priority != "'"$LB_RULE_MAINTENANCE_PRIORITY"'")' <<< "$rules_json2"); then
    debug "$rules_json2"
    error "Error finding rules excluding maintenance mode"
    return 1
  fi
  if ! rules_json=$(jq -s '.[] | select([.Conditions[].Values[] == "'"$LB_URL"'"] | any)' <<< "$rules_json3"); then
    debug "$rules_json3"
    error "Error finding rules with conditions matching $LB_URL"
    return 1
  fi
  num_rules=$(jq -s '. | length' <<< "$rules_json")
  if [[ -z $num_rules ]]; then
    debug "$rules_json"
    error "Error counting lb rules for $LB_URL"
    return 1
  fi
  if [[ $num_rules -eq 0 ]]; then
    debug "$rules_json3"
    error "Error finding matching lb rule for $LB_URL"
    return 1
  fi
  if [[ $num_rules -ne 1 ]]; then
    debug "$rules_json"
    error "Error finding unique lb rule for $LB_URL"
    return 1
  fi
  echo "$rules_json"
}

lb_disable_maintenance_mode() {
  local logprefix
  local lbrulejson
  local priority
  local num_priorities
  local rulearn
  local json

  logprefix=$1
  if ! lbrulejson=$(lb_get_rule_json); then
    return 1
  fi
  rulearn=$(jq -r '.RuleArn' <<< "$lbrulejson")
  priority=$(jq -r '.Priority' <<< "$lbrulejson")
  num_priorities=$(wc -l <<< "$priority" | tr -d " ")
  if [[ -z $priority || $num_priorities != "1" ]]; then
    debug "$lbrulejson"
    error "${logprefix}Error detecting weblogic lb rule priority $num_priorities"
    return 1
  fi
  if ((priority > LB_RULE_MAINTENANCE_PRIORITY)); then
    newpriority=$((priority - 1000))
    dryrun_debug "${logprefix}aws elbv2 set-rule-priorities --rule-priorities 'RuleArn=$rulearn,Priority=$newpriority' --no-cli-pager"
    if (( DRYRUN == 0 )); then
      json=$(aws elbv2 set-rule-priorities --rule-priorities "RuleArn=$rulearn,Priority=$newpriority" --no-cli-pager)
      debug "$json"
      echo "${logprefix}maintenance mode disabled"
    fi
  else
    echo "${logprefix}maintenance mode already disabled"
  fi
}

lb_enable_maintenance_mode() {
  local logprefix
  local lbrulejson
  local priority
  local num_priorities
  local rulearn
  local json

  logprefix=$1
  if ! lbrulejson=$(lb_get_rule_json); then
    return 1
  fi
  rulearn=$(jq -r '.RuleArn' <<< "$lbrulejson")
  priority=$(jq -r '.Priority' <<< "$lbrulejson")
  num_priorities=$(wc -l <<< "$priority" | tr -d " ")
  if [[ -z $priority || $num_priorities != "1" ]]; then
    debug "$lbrulejson"
    error "${logprefix}Error detecting weblogic lb rule priority"
    return 1
  fi
  if ((priority < LB_RULE_MAINTENANCE_PRIORITY)); then
    newpriority=$((priority + 1000))
    dryrun_debug "aws elbv2 set-rule-priorities --rule-priorities 'RuleArn=$rulearn,Priority=$newpriority' --no-cli-pager"
    if (( DRYRUN == 0 )); then
      json=$(aws elbv2 set-rule-priorities --rule-priorities "RuleArn=$rulearn,Priority=$newpriority" --no-cli-pager)
      debug "$json"
      echo "${logprefix}maintenance mode enabled"
    fi
  else
    echo "${logprefix}maintenance mode already enabled"
  fi
}

lb_get_maintenance_mode() {
  local lbrulejson
  local priority
  local num_priorities

  if ! lbrulejson=$(lb_get_rule_json); then
    return 1
  fi
  priority=$(jq -r '.Priority' <<< "$lbrulejson")
  num_priorities=$(wc -l <<< "$priority" | tr -d " ")
  if [[ -z $priority || $num_priorities != "1" ]]; then
    debug "$lbrulejson"
    error "Error detecting weblogic lb rule priority"
    return 1
  fi
  if ((priority < LB_RULE_MAINTENANCE_PRIORITY)); then
    echo "disabled"
  else
    echo "enabled"
  fi
}

lb_get_target_group_arn() {
  local lbrulejson
  local targetgrouparns

  if ! lbrulejson=$(lb_get_rule_json); then
    return 1
  fi
  targetgrouparns=$(jq -r '.Actions[] | select(.Type == "forward").TargetGroupArn' <<< "$lbrulejson" | grep "$LB_BACKEND_PORT")
  num_targetgrouparns=$(wc -l <<< "$targetgrouparns" | tr -d " ")
  if [[ -z $targetgrouparns || $num_targetgrouparns != "1" ]]; then
    debug "$lbrulejson"
    error "Error detecting backend target group arn"
    return 1
  fi
  echo "$targetgrouparns"
}

lb_get_target_group_health() {
  local arn
  local json
  local healthy_ec2s

  if ! arn=$(lb_get_target_group_arn); then
    return 1
  fi

  debug "aws elbv2 describe-target-health --target-group-arn '$arn'"
  json=$(aws elbv2 describe-target-health --target-group-arn "$arn" --no-cli-pager)
  healthy_ec2s=$(jq -r '.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy").Target.Id' <<< "$json")
  if [[ -z $healthy_ec2s ]]; then
    echo 0
  else
    wc -l <<< "$healthy_ec2s" | tr -d " "
  fi
}

lb_get_target_group_name() {
  local arn
  local targetgroup

  if ! arn=$(lb_get_target_group_arn); then
    return 1
  fi
  targetgroup=$(cut -d/ -f2 <<< "$arn" | cut -d- -f1-4)
  if [[ -z $targetgroup ]]; then
    error "Error extracting target group from arn: $arn"
    return 1
  fi
  echo "$targetgroup"
}

lb_wait_for_target_group_health() {
  local healthy_ec2_count
  local i
  local n
  local lb_env
  local logprefix

  logprefix=$1
  lb_env=$2
  expected_healthy_ec2_count=$3

  set_env_lb "$lb_env"
  n=10
  for i in $(seq 1 $n); do
    healthy_ec2_count=$(lb_get_target_group_health)
    if ((healthy_ec2_count == expected_healthy_ec2_count )); then
      return 0
    elif ((DRYRUN != 0)); then
      echo "${logprefix}DRYRUN: skipping waiting for $healthy_ec2_count/$expected_healthy_ec2_count healthy EC2(s)"
      return 0
    fi
    echo "${logprefix}[$i/$n]: waiting for $healthy_ec2_count/$expected_healthy_ec2_count healthy EC2(s)"
    sleep 30
  done
  error "${logprefix}timed out waiting $healthy_ec2_count/$expected_healthy_ec2_count healthy EC2(s)"
  return 1
}

do_env() {
  set -eo pipefail

  if [[ $1 == "aws-account" ]]; then
    echo "$AWS_ACCOUNT"
  else
    usage
  fi
}

do_ec2() {
  set -eo pipefail

  set_env_ec2_info
  if [[ $1 == "display" ]]; then
    echo "cms:      $CMS_EC2_INFO"
    echo "app:      $APP_EC2_INFO"
    echo "web:      $WEB_EC2_INFO"
    echo "webadmin: $WEBADMIN_EC2_INFO"
  else
    usage
  fi
}

do_lb() {
  set -eo pipefail

  if [[ -z $LBS ]]; then
    error "No LB specified"
    return 1
  fi

  num_lbs=$(wc -w <<< "$LBS" | tr -d " ")
  for LB in $LBS; do
    set_env_lb "$LB"
    if ((num_lbs > 1)); then
      echo -n "$LB: "
    fi

    if [[ $FORMAT != "default" ]]; then
      error "$FORMAT format unsupported with lb commands"
      return 1
    fi

    if [[ $1 == "maintenance-mode" ]]; then
      if [[ $2 == "enable" ]]; then
        lb_enable_maintenance_mode ""
      elif [[ $2 == "disable" ]]; then
        lb_disable_maintenance_mode ""
      elif [[ $2 == "check" ]]; then
        lb_get_maintenance_mode
      else
        usage
        return 1
      fi
    elif [[ $1 == "get-target-group" ]]; then
      if [[ $2 == "arn" ]]; then
        lb_get_target_group_arn
      elif [[ $2 == "health" ]]; then
        lb_get_target_group_health
      elif [[ $2 == "name" ]]; then
        lb_get_target_group_name
      else
        usage
        return 1
      fi
    elif [[ $1 == "get-json" ]]; then
      if [[ $2 == "rules" ]]; then
        lb_get_listener_rules_json
      elif [[ $2 == "rule" ]]; then
        lb_get_rule_json
      else
        usage
        return 1
      fi
    else
      usage
      return 1
    fi
 done
}

pipeline_stage_lb() {
  # enable/disable LB maintenance mode
  local lb_cmd
  local lb_env
  local lb_expected_state
  local lb_ec2_count
  local logprefix

  set -eo pipefail

  logprefix=$1
  lb_cmd=$2
  lb_env=$3
  lb_ec2_count=$4

  if [[ $lb_cmd == enable ]]; then
    lb_expected_state=enabled
  elif [[ $lb_cmd == disable ]]; then
    lb_expected_state=disabled
  else
    error "${logprefix}unexpected pipeline_stage_lb parameter $lb_cmd"
    return 1
  fi

  set_env_lb "$lb_env"
  lb_existing_maintenance_mode=$(lb_get_maintenance_mode)
  if [[ $lb_existing_maintenance_mode != "$lb_expected_state" ]]; then
    if [[  $lb_ec2_count != "-1" ]]; then
      lb_wait_for_target_group_health "$logprefix" "$lb_env" "$lb_ec2_count"
    fi
    if ((DRYRUN == 0)); then
      echo "${logprefix}running:  $lb_cmd lb maintenance mode"
      if [[ $lb_cmd == enable ]]; then
        lb_enable_maintenance_mode "${logprefix}"
      else
        lb_disable_maintenance_mode "${logprefix}"
      fi
    else
      echo "${logprefix}DRYRUN:   $lb_cmd lb maintenance mode"
    fi
  else
    echo "${logprefix}skipping: lb maintenance mode already $lb_expected_state"
  fi
}

pipeline_stage_ec2_start() {
  local ec2
  local ec2name
  local ec2id
  local ec2status
  local ec2s
  local ec2update
  local ec2wait
  local i
  local n
  local logprefix

  set -eo pipefail

  logprefix="$1"
  ec2s=$2
  ec2wait=
  shift 1

  if ((VERBOSE == 0)); then
    export SHOW_PROGRESS=0
  else
    export SHOW_PROGRESS=1
  fi
  export TIMEOUT_SECS=120
  for ec2 in $ec2s; do
    ec2name=$(cut -d: -f1 <<< "$ec2")
    ec2id=$(cut -d: -f2 <<< "$ec2")
    ec2status=$(cut -d: -f3 <<< "$ec2")
    if [[ $ec2status != 'running' ]]; then
      if ((DRYRUN == 0 )); then
        echo "${logprefix}${ec2name}: running:  aws ec2 start-instances --instance-ids $ec2id"
        aws ec2 start-instances --instance-ids "$ec2id" >/dev/null
        ec2wait="$ec2wait $ec2"
      else
        echo "${logprefix}${ec2name}: DRYRUN:   aws ec2 start-instances --instance-ids $ec2id"
      fi
    else
      debug "${logprefix}${ec2name}: run_script_on_ec2.sh shell '$ec2id' 'systemctl is-active sapbobj' 'sudo systemctl is-active sapbobj'"
      output=$($EC2_RUN_SCRIPT shell "$ec2id" "systemctl is-active sapbobj" "sudo systemctl is-active sapbobj" 2>/dev/null || true)
      if [[ $output == active ]]; then
        echo "${logprefix}${ec2name}: complete: sapbobj $1"
      elif ((DRYRUN == 0 )); then
        echo "${logprefix}${ec2name}: running:  systemctl start sapbobj"
        debug "${logprefix}${ec2name}: run_script_on_ec2.sh shell '$ec2id' 'systemctl start sapbobj' 'sudo systemctl start sapbobj'"
        $EC2_RUN_SCRIPT shell "$ec2id" "systemctl start sapbobj" "sudo systemctl start sapbobj" "${logprefix}${ec2name}: " || true
      else
        echo "${logprefix}${ec2name}: DRYRUN:   systemctl $2 sapbobj"
      fi
    fi
  done
  n=10
  for i in $(seq 1 $n); do
    if [[ -z $ec2wait ]]; then
      return 0
    fi
    echo "${logprefix}[$i/$n]: waiting for active sapbobj service on $ec2wait"
    sleep 60
    ec2s="$ec2wait"
    ec2wait=
    for ec2 in $ec2s; do
      ec2name=$(cut -d: -f1 <<< "$ec2")
      ec2id=$(cut -d: -f2 <<< "$ec2")
      ec2status=$(cut -d: -f3 <<< "$ec2")
      
      if [[ $ec2status != "running" ]]; then
        if ec2update=$(get_ec2_server_info "Name" "$ec2name"); then
          ec2name=$(cut -d: -f1 <<< "$ec2update")
          ec2id=$(cut -d: -f2 <<< "$ec2update")
          ec2status=$(cut -d: -f3 <<< "$ec2update")
        fi
      fi
      if [[ $ec2status == "running" ]]; then
        # check sapbobj status
        debug "${logprefix}run_script_on_ec2.sh shell '$ec2id' 'systemctl is-active sapbobj' 'sudo systemctl is-active sapbobj'"
        output=$($EC2_RUN_SCRIPT shell "$ec2id" "systemctl is-active sapbobj" "sudo systemctl is-active sapbobj" 2>/dev/null || true)
        if [[ $output != "active" ]]; then
          ec2wait="$ec2wait $ec2"
        else
          echo "${logprefix}${ec2name}: complete: sapbobj service is active"
        fi
      else
        ec2wait="$ec2wait $ec2"
      fi
    done
  done
  error "${logprefix}timed out waiting for EC2/sapbobj to start: $ec2wait"
  return 1
}

pipeline_stage_ec2_stop_or_shutdown() {
  local logprefix
  local ec2
  local ec2name
  local ec2id
  local ec2status
  local ec2s
  local ec2update
  local ec2wait
  local i
  local n
  local stop_or_shutdown

  set -eo pipefail

  logprefix="$1"
  stop_or_shutdown=$2
  ec2s=$3
  ec2wait=
  shift 2

  if ((VERBOSE == 0)); then
    export SHOW_PROGRESS=0
  else
    export SHOW_PROGRESS=1
  fi
  export TIMEOUT_SECS=120

  for ec2 in $ec2s; do
    ec2name=$(cut -d: -f1 <<< "$ec2")
    ec2id=$(cut -d: -f2 <<< "$ec2")
    ec2status=$(cut -d: -f3 <<< "$ec2")
    if [[ $ec2status == "running" ]]; then
      debug "${logprefix}${ec2name}: run_script_on_ec2.sh shell '$ec2id' 'systemctl is-active sapbobj' 'sudo systemctl is-active sapbobj'"
      output=$($EC2_RUN_SCRIPT shell "$ec2id" "systemctl is-active sapbobj" "sudo systemctl is-active sapbobj" 2>/dev/null || true)
      if [[ $output == "active" ]]; then
        if ((DRYRUN == 0 )); then
          echo "${logprefix}${ec2name}: running:  systemctl stop sapbobj"
          debug "${logprefix}${ec2name}: run_script_on_ec2.sh shell '$ec2id' 'systemctl stop sapbobj' 'sudo systemctl stop sapbobj'"
          $EC2_RUN_SCRIPT shell "$ec2id" "systemctl stop sapbobj" "sudo systemctl stop sapbobj" "${logprefix}${ec2name}: " || true
          waitec2="$waitec2 $ec2"
        else
          echo "${logprefix}${ec2name}: DRYRUN:   systemctl stop sapbobj"
        fi
      elif [[ $output == "inactive" ]]; then
        echo "${logprefix}${ec2name}: skipping: sapbobj service already stopped"
      else
        echo "${logprefix}${ec2name}: skipping: sapbobj service state unknown: $output"
      fi
    elif [[ $stop_or_shutdown == "stop" ]]; then
      echo "${logprefix}${ec2name}: skipping: cannot stop sapbobj service as EC2 in $ec2status state"
    fi
  done

  if [[ -n $ec2wait ]]; then
    echo "${logprefix}[$i/$n]: waiting for systemctl stop on $ec2wait"
    sleep 60
  fi

  if [[ $stop_or_shutdown == "stop" ]]; then
    return 0
  fi

  ec2wait=
  for ec2 in $ec2s; do
    ec2name=$(cut -d: -f1 <<< "$ec2")
    ec2id=$(cut -d: -f2 <<< "$ec2")
    ec2status=$(cut -d: -f3 <<< "$ec2")
    if [[ $ec2status != "stopped" ]]; then
      if ((DRYRUN == 0 )); then
        echo "${logprefix}${ec2name}: running:  aws ec2 stop-instances --instance-ids $ec2id"
        aws ec2 "stop-instances" --instance-ids "$ec2id" >/dev/null
        ec2wait="$ec2wait $ec2"
      else
        echo "${logprefix}${ec2name}: DRYRUN:   aws ec2 stop-instances --instance-ids $ec2id"
      fi
    else
      echo "${logprefix}${ec2name}: skipping: EC2 already stopped"
    fi
  done

  n=60
  for i in $(seq 1 $n); do
    if [[ -z $ec2wait ]]; then
      return 0
    fi
    echo "${logprefix}[$i/$n]: Waiting for $ec2wait"
    sleep 10
    ec2s="$ec2wait"
    ec2wait=
    for ec2 in $ec2s; do
      ec2name=$(cut -d: -f1 <<< "$ec2")
      ec2id=$(cut -d: -f2 <<< "$ec2")
      ec2status=$(cut -d: -f3 <<< "$ec2")
      if [[ $ec2status != "stopped" ]]; then
        if ec2update=$(get_ec2_server_info "Name" "$ec2name"); then
          ec2name=$(cut -d: -f1 <<< "$ec2update")
          ec2id=$(cut -d: -f2 <<< "$ec2update")
          ec2status=$(cut -d: -f3 <<< "$ec2update")
        fi
      fi
      if [[ $ec2status != "stopped" ]]; then
        ec2wait="$ec2wait $ec2"
      else
        echo "${logprefix}${ec2name}: complete: EC2 is stopped"
      fi
    done
  done
  error "${logprefix}timed out waiting for EC2 to stop: $ec2wait"
  return 1
}

pipeline_stage_bip() {
  local logprefix
  local ec2
  local ec2name
  local ec2id
  local ec2status
  local opts
  local stage
  local waitsecs

  set -eo pipefail

  logprefix="$1"
  bipcmd=$2
  stage=$3
  export TIMEOUT_SECS=$4
  ec2=$(echo "$5" | cut -d\  -f1)
  waitsecs=$6

  if ((VERBOSE == 0)); then
    export SHOW_PROGRESS=0
  else
    export SHOW_PROGRESS=1
  fi

  ec2name=$(cut -d: -f1 <<< "$ec2")
  ec2id=$(cut -d: -f2 <<< "$ec2")
  ec2status=$(cut -d: -f3 <<< "$ec2")
  logprefix="${logprefix}${ec2name}: "
  if [[ $ec2status == "running" ]]; then
    opts=
    if ((VERBOSE != 0)); then
      opts="$opts -v"
    fi
    if ((DRYRUN != 0)); then
      opts="$opts -d"
    fi
    if [[ -n $waitsecs ]]; then
      opts="$opts -3 $waitsecs"
      echo "${logprefix}running:  bip_control.sh $opts pipeline $bipcmd $stage (waits for up to ${waitsecs}s)"
    else
      echo "${logprefix}running:  bip_control.sh $opts pipeline $bipcmd $stage"
    fi
    debug "${logprefix}run_script_on_ec2.sh shell '$ec2id' 'bip_control.sh pipeline $bipcmd $stage' 'sudo su bobj -c \"/home/bobj/bip_control.sh $opts pipeline $bipcmd $stage\"'"
    $EC2_RUN_SCRIPT shell "$ec2id" "bip_control.sh pipeline $bipcmd" "sudo su bobj -c '/home/bobj/bip_control.sh $opts pipeline $bipcmd $stage'" "$logprefix"
  else
    echo "${logprefix}skipping: cannot run bip_control.sh as EC2 state is $ec2status"
  fi
}

do_pipeline() {
  set -eo pipefail

  set_env_ec2_info

  if [[ $1 == "start" ]]; then
    if [[ $2 == "all" || $2 == *8* ]]; then
      pipeline_stage_ec2_start "STAGE 8: " "$CMS_EC2_INFO"
      if [[ -n $APP_EC2_INFO ]]; then
        pipeline_stage_ec2_start "STAGE 8: " "$APP_EC2_INFO"
      fi
      set_env_ec2_info
    fi
    if [[ $2 == "all" || $2 == *7* ]]; then
      pipeline_stage_bip "STAGE 7: " start 7 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *6* ]]; then
      pipeline_stage_bip "STAGE 6: " start 6 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *5* ]]; then
      pipeline_stage_bip "STAGE 5: " start 5 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *4* ]]; then
      pipeline_stage_bip "STAGE 4: " start 4 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *3* ]]; then
      pipeline_stage_bip "STAGE 3: " start 3 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *2* ]]; then
      pipeline_stage_bip "STAGE 2: " start 2 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *1* ]]; then
      pipeline_stage_ec2_start "STAGE 1: " "$WEB_EC2_INFO $WEBADMIN_EC2_INFO"
      set_env_ec2_info
    fi
    if [[ $2 == "all" || $2 == *0* ]]; then
      if (( EXPECTED_WEBADMIN_EC2_COUNT != 0 )); then
        pipeline_stage_lb "STAGE 0: admin-lb:     " disable admin   "$EXPECTED_WEBADMIN_EC2_COUNT"
      fi
      pipeline_stage_lb "STAGE 0: public-lb:    " disable public  "$EXPECTED_WEB_EC2_COUNT"
      pipeline_stage_lb "STAGE 0: private-lb:   " disable private "$EXPECTED_WEB_EC2_COUNT"
    fi
  elif [[ $1 == "stop" || $1 == "shutdown" ]]; then
    if [[ $2 == "all" || $2 == *0* ]]; then
      pipeline_stage_lb "STAGE 0: private-lb:   " enable  private -1
      pipeline_stage_lb "STAGE 0: public-lb:    " enable  public  -1
      if (( EXPECTED_WEBADMIN_EC2_COUNT != 0 )); then
        pipeline_stage_lb "STAGE 0: admin-lb:     " enable  admin   -1
      fi
    fi
    if [[ $2 == "all" || $2 == *1* ]]; then
      pipeline_stage_ec2_stop_or_shutdown "STAGE 1: " "$1" "$WEB_EC2_INFO $WEBADMIN_EC2_INFO"
      set_env_ec2_info
    fi
    if [[ $2 == "all" || $2 == *2* ]]; then
      pipeline_stage_bip "STAGE 2: " stop 2 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *3* ]]; then
      pipeline_stage_bip "STAGE 3: " stop 3 $((STAGE3_WAIT_SECS+300)) "$CMS_EC2_INFO" "$STAGE3_WAIT_SECS"
    fi
    if [[ $2 == "all" || $2 == *4* ]]; then
      pipeline_stage_bip "STAGE 4: " stop 4 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *5* ]]; then
      pipeline_stage_bip "STAGE 5: " stop 5 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *6* ]]; then
      pipeline_stage_bip "STAGE 6: " stop 6 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *7* ]]; then
      pipeline_stage_bip "STAGE 7: " stop 7 300 "$CMS_EC2_INFO"
    fi
    if [[ $2 == "all" || $2 == *8* ]]; then
      if [[ -n $APP_EC2_INFO ]]; then
        pipeline_stage_ec2_stop_or_shutdown "STAGE 8: " "$1" "$APP_EC2_INFO"
      fi
      pipeline_stage_ec2_stop_or_shutdown "STAGE 8: " "$1" "$CMS_EC2_INFO"
      set_env_ec2_info
    fi
  else
    usage
  fi
}

main() {
  set -eo pipefail
  while getopts "3:de:l:v" opt; do
      case $opt in
          3)
              STAGE3_WAIT_SECS=${OPTARG}
              ;;
          d)
              DRYRUN=1
              ;;
          e)
              NCR_ENVIRONMENT=${OPTARG}
              ;;
          l)
              LBS=${OPTARG}
              ;;
          v)
              VERBOSE=1
              ;;
          :)
              error "Error: option ${OPTARG} requires an argument"
              exit 1
              ;;
          ?)
              error "Invalid option: ${OPTARG}"
              exit 1
              ;;
      esac
  done

  shift $((OPTIND-1))

  if [[ -z $1 ]]; then
    usage
  fi

  if [[ -z $NCR_ENVIRONMENT ]]; then
    error "Please specify environment"
    usage
  fi

  set_env_variables

  if [[ $1 == "env" ]]; then
    shift
    do_env "$@"
  elif [[ $1 == "ec2" ]]; then
    shift
    do_ec2 "$@"
  elif [[ $1 == "lb" ]]; then
    shift
    do_lb "$@"
  elif [[ $1 == "pipeline" ]]; then
    shift
    do_pipeline "$@"
  else
    usage
    exit 1
  fi
}

main "$@"
