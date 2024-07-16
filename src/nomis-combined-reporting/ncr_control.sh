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
  local cms_names
  local processing_names
  local tomcat_names

  nomis_combined_reporting_environment=$1
  if [[ $nomis_combined_reporting_environment == "dev" ]]; then
    account_name="nomis-combined-reporting-development"
  elif [[ $nomis_combined_reporting_environment == "t1" ]]; then
    account_name="nomis-combined-reporting-test"
  elif [[ $nomis_combined_reporting_environment == "lsast" ]]; then
    account_name="nomis-combined-reporting-preproduction"
  elif [[ $nomis_combined_reporting_environment == "preprod" ]]; then
    account_name="nomis-combined-reporting-preproduction"
    cms_names=("pp-ncr-cms-a.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk", "pp-ncr-cms-b.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk")
    processing_names=("pp-ncr-processing-a.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk")
    tomcat_names=("pp-ncr-web-admin-a.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk", "pp-ncr-web-a.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk", "pp-ncr-web-b.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk")
  elif [[ $nomis_combined_reporting_environment == "prod" ]]; then
    account_name="nomis-combined-reporting-production"
    cms_names=("pd-ncr-cms-a.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk", "pd-ncr-cms-b.nomis-combined-reporting.hmpps-preproduction.modernisation-platform.service.justice.gov.uk")
  else
    echo "Unsupported nomis_combined_reporting_environment $nomis_combined_reporting_environment" >&2
    return 1
  fi
  echo "$account_name"
  echo "$cms_names"
  echo "$processing_names"
  echo "$tomcat_names"
}

start_ncr() {
  # Get environment
  # Get instance name for cms machines, processing nodes and tomcat servers
  # run start server bash script on cms machines a then b
  # run start server bash script on processing nodes
  # run start server bash script on tomcat web servers
}

stop_ncr() {
  # Get environment
  # Get instance name for cms machines, processing nodes and tomcat servers
  # run stop server bash script on tomcat web servers
  # run stop server bash script on processing nodes
  # run stop server bash script on cms machines b then a
}