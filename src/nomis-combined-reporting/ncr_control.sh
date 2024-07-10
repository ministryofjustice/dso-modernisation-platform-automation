#!/bin/bash
LBNAME="private-lb"
MAINTENANCE_PRIORITY=999
PORT=443
DRYRUN=0
DEPLOYMENT=enduser

usage() {
  echo "Usage $0: <opts> <nomis_combined_reporting_environment>

Where <opts>:
  -0                     Stop BIP
  -1                     Start BIP
"
}

get_account_name() {
  local nomis_combined_reporting_environment

  nomis_combined_reporting_environment=$1
  if [[ $nomis_combined_reporting_environment == "dev" ]]; then
    account_name="nomis-combined-reporting-development"
  elif [[ $nomis_combined_reporting_environment == "t1" ]]; then
    account_name="nomis-combined-reporting-test"
  elif [[ $nomis_combined_reporting_environment == "lsast" ]]; then
    account_name="nomis-combined-reporting-preproduction"
  elif [[ $nomis_combined_reporting_environment == "preprod" ]]; then
    account_name="nomis-combined-reporting-preproduction"
  elif [[ $nomis_combined_reporting_environment == "prod" ]]; then
    account_name="nomis-combined-reporting-production"
  else
    echo "Unsupported nomis_combined_reporting_environment $nomis_combined_reporting_environment" >&2
    return 1
  fi
  echo "$account_name"
}

start_ncr() {

}

stop_ncr() {
  
}