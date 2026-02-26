#!/bin/bash
#
# Generate lists of Oracle workflow options:
#  - primary databases
#  - database systems (i.e. primary and all standby databases)

set -euo pipefail

usage() {
   echo "Usage: $0 [primary|system] <dba_applications_list> <group_vars_directory>"
}

if [[ $# -ne 3 ]]; then
   usage
   exit 1
fi

MODE=$1
DBA_APPLICATIONS_LIST=$2
GROUP_VARS_DIRECTORY=$3

if [[ ! -d ${GROUP_VARS_DIRECTORY} ]]; then
   echo "Ansible group_vars directory not found at ${GROUP_VARS_DIRECTORY}."
   exit 1
fi

if [[ ! -f ${DBA_APPLICATIONS_LIST} ]]; then
   echo "DBA applications list not found at ${DBA_APPLICATIONS_LIST}."
   exit 1
fi

case "${MODE}" in
   primary|system)
      ;;
   *)
      usage
      exit 1
      ;;
esac

# Create array of all possible target entries
declare -a TARGET_ENTRIES

for GROUP_VARS_FILE in $(ls -1 ${GROUP_VARS_DIRECTORY} | grep -f <(sed 's/.*/environment_name_&_.*.yml/' ${DBA_APPLICATIONS_LIST} | sed 's/-/_/g'));
do
   # For Delius (delius-core and delius-mis) we simply refer to the primarydb as there is only ever exactly one
   # of those per application group - the entry is the same regardless if it is a primary or system mode
   if [[ "${GROUP_VARS_FILE}" == *"delius"* ]]; then
      if [[ "${GROUP_VARS_FILE}" == *"_primarydb.yml" ]]; then
         TARGET_ENTRIES+=("$(echo ${GROUP_VARS_FILE%%_primarydb.yml} | sed 's/^environment_name_//')")
      fi
   elif [[ "${GROUP_VARS_FILE}" == *"hmpps_oem"* ]]; then
       # For OEM we refer to the primary EMREP and RCVCAT databases as there are only ever these 2
       # primary databases in the environment - the entry is the same regardless if it is a primary or system mode 
       TARGET_ENTRIES+=("$(echo ${GROUP_VARS_FILE#*environment_name_} | sed 's/.yml$//') EMREP")
       TARGET_ENTRIES+=("$(echo ${GROUP_VARS_FILE#*environment_name_} | sed 's/.yml$//') RCVCAT")
   else
      # Non-Delius applications...
      if [[ "${MODE}" == "primary" ]]; then
         # For other applications find all the databases listed in the environment
         for DATABASE in $(yq '.db_configs? | select(. != null) | keys | .[]' ${GROUP_VARS_DIRECTORY}/${GROUP_VARS_FILE});
         do
            # The RCVCAT database is referenced in all non-Delius environments but it is
            # only a real database in the hmpps_oem application environments so exclude it elsewhere
            if [[ "${DATABASE}" != "RCVCAT" ]]; then
               if [[ ! "${DATABASE}" == "DR"* ]]; then
                  # Non-Delius standby databases are identified by the DR prefix. Ignore those.
                  TARGET_ENTRIES+=("$(echo ${GROUP_VARS_FILE#*environment_name_} | sed 's/.yml$//') ${DATABASE}")
               fi
            fi
         done
      else
         # mode == system (get all databases; regardless of whether they are a primary or standby)
         if yq 'has("db_configs")' ${GROUP_VARS_DIRECTORY}/${GROUP_VARS_FILE} | grep -q true; then
            # We ignore entries which do not have a host_name as they will correspond to either obsolete databases
            # or the RMAN catalog database, which only exists in hmpps-oem* environment
            for SYSTEM in $(
               yq -o=json '.db_configs' ${GROUP_VARS_DIRECTORY}/${GROUP_VARS_FILE} \
                              | jq -r '
                              to_entries
                              | map(
                                 select(.value.host_name != null)
                                 | {key, services: (.value.service // [] | map(.name))}
                              )
                              | map(
                                 .services[] as $svc
                                 | {service:$svc, key:.key}
                              )
                              | sort_by(.service)
                              | group_by(.service)
                              | map("(\(.[0].service))=>\(map(.key) | join(","))")
                              | .[]'
                           );
            do
               TARGET_ENTRIES+=("$(echo ${GROUP_VARS_FILE#*environment_name_} | sed 's/.yml$//') ${SYSTEM}")
            done
         fi
      fi
   fi
done

# Get longest string length so we can format the array
MAX_LENGTH=0
for s in "${TARGET_ENTRIES[@]} ";
do
   (( ${#s} > MAX_LENGTH )) && MAX_LENGTH=${#s}
done

if [[ "${MODE}" == "primary" ]]; then
   echo ">>>>>>>>CUT HERE FOR TARGET DATABASE LIST>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
else
   echo ">>>>>>>>CUT HERE FOR TARGET DATABASE SYSTEMS LIST>>>>>>>>>>>>>>>>>>>>>>>"
fi

# Print all target entries in alphabetical order formatted for align together
printf '%s\n' "${TARGET_ENTRIES[@]}" | sort | awk -v MAX=${MAX_LENGTH} '{PAD=2+MAX-length($1 $2); printf("          - '\''%s%*s%s'\''\n",$1,PAD,"",$2)}'

if [[ "${MODE}" == "primary" ]]; then
   echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
else
   echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
fi
