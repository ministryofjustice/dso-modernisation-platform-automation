#!/bin/bash
# 
set -e
get_accounts() {
  local applications
  local environments

  applications="$1"
  environments="$2"
  if [[ -z $applications ]]; then
    applications=$(cat $(dirname $0)/DBA_APPLICATIONS.txt)
  fi
  if [[ -z $environments ]]; then
    environments="development test preproduction production"
  fi
  for application in $applications; do
    json=$(curl -Ss "https://raw.githubusercontent.com/ministryofjustice/modernisation-platform/main/environments/${application}.json")
    if ! jq -e . >/dev/null 2>&1 <<<"$json"; then
      echo "$application environment config error: $json" >&2
      exit 1
    fi
    application_environments=$(jq -r .environments[].name <<<$json)
    for environment in $application_environments; do
      if [[ $environments == *"$environment"* ]]; then
        echo ${application}-${environment}
      fi
    done
  done
}

get_strategy_matrix() {
  accounts=$(get_accounts "$@")
  echo '{"include":['
  (
    for account in $accounts; do
      echo '{"account_name": "'$account'"},'
    done
  ) | sed '$s/,$//' 
  echo ']}'
}

if [[ $1 == "gha" ]]; then
  shift
  get_strategy_matrix "$@" | jq -r
elif [[ $1 == "text" ]]; then
  shift
  get_accounts "$@"
else
  echo "Usage: $0: gha|text <applications> <environments>" >&2
  exit 1
fi
