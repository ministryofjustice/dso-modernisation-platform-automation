#!/bin/bash
#
# Generate a list of database systems
# * For Delius these are member of the respective _dbs groups
# * For other applications these are a collection of database names

# List of applications supported by DBAs
DBA_APPLICATIONS_LIST=$1

# Path to the Ansible Group Vars files directory
GROUP_VARS_DIRECTORY=$2

if [[ ! -d ${GROUP_VARS_DIRECTORY} ]];
then
   echo "Ansible group_vars directory not found at ${GROUP_VARS_DIRECTORY}."
   exit 1
fi

# Create array of all possible target database systems
declare -a TARGET_DATABASE_SYSTEMS

for GROUP_VARS_FILE in $(ls -1 ${GROUP_VARS_DIRECTORY} | grep  -f <(sed 's/.*/environment_name_&_.*.yml/' ${DBA_APPLICATIONS_LIST} | sed 's/-/_/g' ));
do
   # For Delius (delius-core and delius-mis) we are only identify systems using the *all files
   # for the environment
   if [[ "$GROUP_VARS_FILE" == *"delius"* ]];
   then
      if [[ "$GROUP_VARS_FILE" == *"_all.yml" ]];
      then
        TARGET_DATABASE_SYSTEMS+=("$(echo ${GROUP_VARS_FILE%%_all.yml} | sed 's/^environment_name_//')")
      fi
   else
         if yq 'has("db_configs")' ${GROUP_VARS_DIRECTORY}/${GROUP_VARS_FILE} | grep -q true
         then
            for SYSTEM in $(
                     yq -o=json '.db_configs' ${GROUP_VARS_DIRECTORY}/${GROUP_VARS_FILE} \
                  | jq -r '
                        def tafs: (.services | map(select(test("_TAF$"))) | unique);

                        to_entries as $entries
                        | [ $entries[] | {key, services:(.value.service // [] | map(.name) | unique)} ] as $items

                        | (
                           [ range(0; $items|length) as $i
                              | range($i+1; $items|length) as $j
                              | ($items[$i].services) as $s1
                              | ($items[$j].services) as $s2
                              | (($s1 + $s2) | sort | group_by(.) | map(select(length>1) | .[0])) as $shared
                              | select($shared|length>0)
                              | "(\($shared | join(",")))=>\($items[$i].key),\($items[$j].key)"
                           ]
                        ) as $pairs

                        | (
                           [ $items[] | {key, services} | {key, tafs:(tafs)} ] as $taf
                           | ($taf | reduce .[] as $i ({}; reduce $i.tafs[] as $s (. ; .[$s] = ((.[$s] // []) + [$i.key])))) as $index
                           | $taf
                           | map(select((.tafs|length)==0 or (all(.tafs[]; ($index[.]|length)==1))))
                           | map(.key)
                        ) as $no_match

                        | $pairs + $no_match
                        | .[]'
                       )

            do 
            # The RCVCAT database is referenced in all non-Delius environments but it is
            # only a real database in the hmpps_oem application environments so exclude it elsewhere.
            # RCVCAT is only ever a primary database so it can be included in a system by itself
               if [[ "$SYSTEM" == "RCVCAT" ]];
               then
                  if [[ "$GROUP_VARS_FILE" == *"hmpps_oem"* ]];
                  then
                     TARGET_DATABASE_SYSTEMS+=("$(echo ${GROUP_VARS_FILE#*environment_name_} | sed 's/.yml$//') $SYSTEM")
                  fi
               else    
                  TARGET_DATABASE_SYSTEMS+=("$(echo ${GROUP_VARS_FILE#*environment_name_} | sed 's/.yml$//') $SYSTEM")
               fi
            done
      fi
   fi
done

# Get longest string length so we can format the array 
MAX_LENGTH=0
for s in "${TARGET_DATABASE_SYSTEMS[@]} ";
do
    (( ${#s} > MAX_LENGTH )) && MAX_LENGTH=${#s}
done

echo ">>>>>>>>CUT HERE FOR TARGET DATABASE SYSTEMS LIST>>>>>>>>>>>>>>>>>>>>>>>"
# Print all target databases in alphabetical order formatted for align together
printf '%s\n' "${TARGET_DATABASE_SYSTEMS[@]}" | sort | awk -v MAX=${MAX_LENGTH} '{PAD=2+MAX-length($1 $2); printf("          - '"'"'%s%*s%s'"'"'\n",$1,PAD,"",$2)}' 
echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"