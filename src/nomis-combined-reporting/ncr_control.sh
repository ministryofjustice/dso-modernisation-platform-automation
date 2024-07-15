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

get_instance_names() {
  local nomis_combined_reporting_environment
  local cms_urls
  local processing_urls
  local tomcat_urls

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
    cms_names=("pd-ncr-cms-a.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk", "pd-ncr-cms-b.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk")
  else
    echo "Unsupported nomis_combined_reporting_environment $nomis_combined_reporting_environment" >&2
    return 1
  fi
  echo "$account_name"
}

get_instance_names() {
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
  # Get environment
  # Get instance name for cms machines, processing nodes and tomcat servers
  # run start server bash script on cms machines a then b
  # run stop server bash script on 

}

stop_ncr() {
# Get instance name for cms machines
}