#!/bin/bash
# Don't forget to set your default profile
# export AWS_DEFAULT_PROFILE=nomis-development
SAS_TOKEN_EXPIRY_DAYS=7
DRYRUN=0

set -eo pipefail

usage() {
  echo "Usage $0: [<opts>] gha|refresh

Where <opts>:
  -a <application>       Specify which application for images in code, e.g. nomis
  -d                     Dryrun, i.e. get SAS but don't update SSM parameter
  -e <environment>       Specify which AWS environment, e.g. development
  -c <config>            JSON containing Azure Account Ids and Storage Account Names
"
  echo 'Example <config>:
{
  "account_config": [
    {
      "aws_account_name": "nomis-data-hub-production",
      "storage_accounts": [
        {
          "azure_subscription_id": "foo",
          "storage_account_name": "bar",
          "sas_permissions": "acrluw",
          "sas_resource_types": "oc",
          "sas_services": "b"
        }
      ]
    }
  ]
}
'
}

get_accounts() {
  local accounts
  local applications
  local environments
  local config_json

  applications="$1"
  environments="$2"
  config_json="$3"
  accounts=$(jq -r '.account_config[].aws_account_name' <<< "$config_json")
  if [[ -z $applications ]]; then
    applications=$(echo "$accounts" | rev | cut -d- -f2- | rev | sort -u)
  fi
  if [[ -z $environments ]]; then
    environments="development test preproduction production"
  fi
  for application in $applications; do
    for environment in $environments; do
      grep -w "${application}-${environment}" <<< "$accounts" || true
    done
  done
}

get_strategy_matrix() {
  local accounts

  accounts=$(get_accounts "$@")
  if [[ -z $accounts ]]; then
    echo "No matching accounts $1 $2" >&2
    exit 1
  fi
  echo '{"include":['
  (
    for account in $accounts; do
      echo '{"account_name": "'"$account"'"},'
    done
  ) | sed '$s/,$//'
  echo ']}'
}

get_azure_sas_tokens() {
  local account
  local account_json
  local azure_subscription_id
  local config_json
  local expiry
  local generate_sas_args
  local sas_permissions
  local sas_resource_types
  local sas_services
  local storage_account_name
  local num_storage_accounts

  config_json="$3"
  account=$(get_accounts "$@")
  if [[ -z $account ]]; then
    echo "No matching accounts $1 $2" >&2
    exit 1
  fi
  if (($(wc -l <<< "$account") != 1)); then
    echo "$account" >&2
    echo "Must specify single account only $1 $2" >&2
    exit 1
  fi
  account_json=$(jq '.account_config[] | select(.aws_account_name == "'"$account"'")' <<< "$config_json")
  num_storage_accounts=$(jq ".storage_accounts | length" <<< "$account_json")
  if ((num_storage_accounts != 1)); then
    echo "$account_json" >&2
    echo "Only 1 storage account per account is supported by the script at the moment" >&2
    exit 1
  fi
  if [[ "$(uname)" == "Darwin" ]]; then
    expiry=$(date "-jv+${SAS_TOKEN_EXPIRY_DAYS}d" +"%Y-%m-%d")
  else
    expiry=$(date -d "+$SAS_TOKEN_EXPIRY_DAYS days" +"%Y-%m-%d")
  fi
  azure_subscription_id=$(jq -r ".storage_accounts[0].azure_subscription_id" <<< "$account_json")
  storage_account_name=$(jq -r ".storage_accounts[0].storage_account_name" <<< "$account_json")
  sas_permissions=$(jq -r ".storage_accounts[0].sas_permissions" <<< "$account_json")
  sas_resource_types=$(jq -r ".storage_accounts[0].sas_resource_types" <<< "$account_json")
  sas_services=$(jq -r ".storage_accounts[0].sas_services" <<< "$account_json")
  generate_sas_args="--permissions $sas_permissions --resource-types $sas_resource_types --services $sas_services --https-only"
  echo "az account set --subscription '$azure_subscription_id'" >&2
  az account set --subscription "$azure_subscription_id"
  echo "az storage account generate-sas --account-name '$storage_account_name' --expiry '$expiry' $generate_sas_args" >&2
  az storage account generate-sas --account-name "$storage_account_name" --expiry "$expiry" -o tsv $generate_sas_args
}

refresh_azure_sas_tokens() {
  local existing_sas_token
  local new_sas_token

  set -eo pipefail

  echo "aws ssm get-parameter --name /azure/sas_token" >&2
  existing_sas_token=$(aws ssm get-parameter --name /azure/sas_token || true)
  if [[ -z $existing_sas_token ]]; then
    echo "Error: please ensure /azure/sas_token SSM parameter has been creatd in AWS account"
    exit 1
  fi
  new_sas_token=$(get_azure_sas_tokens "$@")
  if [[ -z $new_sas_token ]]; then
    echo "Error creating sas token" >&2
    exit 1
  fi
  if (( DRYRUN == 1 )); then
    echo "DRYRUN: aws ssm put-parameter --name /azure/sas_token --value xxxx --type SecureString --overwrite" >&2
  else
    echo "aws ssm put-parameter --name /azure/sas_token --value xxxx --type SecureString --overwrite"
    aws ssm put-parameter --name /azure/sas_token --value "$new_sas_token" --type SecureString --overwrite
  fi
}

main() {
  application=
  config_json=
  environment=
  while getopts "a:c:de:" opt; do
      case $opt in
          a)
              application="${OPTARG}"
              ;;
          c)
              config_json="${OPTARG}"
              ;;
          d)
              DRYRUN=1
              ;;
          e)
              environment=${OPTARG}
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
    echo "Unexpected argument: $1 $2" >&2
    usage >&2
    exit 1
  fi

  if [[ -z $config_json ]]; then
    echo "-c option must be specified" >&2
    usage >&2
    exit 1
  fi

  if [[ $1 == "gha" ]]; then
    get_strategy_matrix "$application" "$environment" "$config_json"
  elif [[ $1 == "refresh" ]]; then
    refresh_azure_sas_tokens "$application" "$environment" "$config_json"
  else
    usage >&2
    exit 1
  fi
}

main "$@"
