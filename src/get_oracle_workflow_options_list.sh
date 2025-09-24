#!/bin/bash

# List of applications supported by DBAs
DBA_APPLICATIONS_LIST=$1

# Path to the Ansible Group Vars files directory
GROUP_VARS_DIRECTORY=$2

# Create array of all possible target primary databases
declare -a TARGET_DATABASES

for GROUP_VARS_FILE in $(ls -1 ${GROUP_VARS_DIRECTORY} | grep  -f <(sed 's/.*/environment_name_&_.*.yml/' ${DBA_APPLICATIONS_LIST} | sed 's/-/_/g' ));
do
   # For Delius (delius-core and delius-mis) we are only interested in the primary databases hosts
   # and we do not need the database name as there is only one per host
   if [[ "$GROUP_VARS_FILE" == *"delius"* ]];
   then 
      if [[ "$GROUP_VARS_FILE" == *"_primarydb.yml" ]];
      then
        TARGET_DATABASES+=("$(echo ${GROUP_VARS_FILE%%_primarydb.yml} | sed 's/^environment_name_//')")
      fi
   else
      # For other applications find all the databases listed in the environment
      for DATABASE in $(yq '.db_configs? | select(. != null) | keys | .[]' /root/data/modernisation-platform-configuration-management/ansible/group_vars/${GROUP_VARS_FILE})
      do
         # The RCVCAT database is referenced in all non-Delius environments but it is
         # only a real database in the hmpps_oem application environments so exclude it elsewhere
         if [[ "$DATABASE" == "RCVCAT" ]];
         then
            if [[ "$GROUP_VARS_FILE" == *"hmpps_oem"* ]];
            then
               TARGET_DATABASES+=("$(echo ${GROUP_VARS_FILE#*environment_name_} | sed 's/.yml$//') $DATABASE")
            fi
         else      
            if [[ ! "$DATABASE" == "DR"* ]];
            then
               # Non-Delius standby databases are identified by the DR prefix.  Ignore those.
               TARGET_DATABASES+=("$(echo ${GROUP_VARS_FILE#*environment_name_} | sed 's/.yml$//') $DATABASE")
            fi
         fi
      done
   fi
done

# Get longest string length so we can format the array 
MAX_LENGTH=0
for s in "${TARGET_DATABASES[@]} ";
do
    (( ${#s} > MAX_LENGTH )) && MAX_LENGTH=${#s}
done

# Print all target databases in alphabetical order formatted for align together
printf '%s\n' "${TARGET_DATABASES[@]}" | sort | awk -v MAX=${MAX_LENGTH} '{PAD=2+MAX-length($1 $2); printf("%s%*s%s\n",$1,PAD,"",$2)}' 
