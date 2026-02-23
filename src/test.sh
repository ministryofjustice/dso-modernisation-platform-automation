#!/bin/bash

TARGET_ENTITIES=$1

declare -A IP_CACHE

function resolve_ip {
 local ip="$1"
 
  echo "C: ${IP_CACHE[*]}" >&2

 if [[ -n "${IP_CACHE[$ip]}" ]]; then
   echo " Cache hit!" >&2
    RESOLVED_IP="${IP_CACHE[$ip]}"
    return
 fi
 
 local result
 result=$(jq -r --arg ip "$ip" '
  ._meta.hostvars
  | to_entries
  | map(select(.value.network_interfaces[]?.private_ip_address == $ip))
  | .[].key
' < <(ansible-inventory -i /inventory --list))
 
 IP_CACHE[$ip]="$result"
 RESOLVED_IP="$result"
}


         TARGET_ENVIRONMENT=${TARGET_ENTITIES%%[[:space:]]*}
          # The last field in the input will either be a single database (if primary database targets)
          # or a comma-separated list of databases following the delimiter => (if system targets)
          # We convert both forms to a comma-separated list, since a primary database is simply
          # a comma-separated list with only one element.
          TARGET_DATABASES=$(echo ${TARGET_ENTITIES} | awk '{last=$NF; sub(/.*=>/,"",last); print last}')
          TARGET_GROUP=environment_name_${TARGET_ENVIRONMENT}
          case "${TARGET_ENVIRONMENT}" in
            delius_core*|delius_mis*)
                    case "${TARGET_ENVIRONMENT}" in
                        delius_core*) APPLICATION=delius-core ;;
                        delius_mis*)  APPLICATION=delius-mis  ;;
                    esac
                    if [ ${TARGET_ENTITIES_TYPE} == "primary" ]
                    then
                       TARGET_GROUP=environment_name_${TARGET_ENVIRONMENT}_primarydb
                    else
                       TARGET_GROUP=environment_name_${TARGET_ENVIRONMENT}_dbs
                    fi
                    ;;
            nomis*|corporate_staff_rostering*|oasys*|hmpps-oem*)
                    # For these applications the target hosts for the databases can be found in
                    # the Ansible configuration files
                    case "${TARGET_ENVIRONMENT}" in
                        nomis_combined_reporting*)
                            APPLICATION=nomis-combined-reporting
                            ;;
                        nomis*)
                            APPLICATION=nomis
                            ;;
                        oasys_national_reporting*)
                            APPLICATION=oasys-national-reporting
                            ;;
                        oasys*)
                            APPLICATION=oasys
                            ;;
                        corporate_staff_rostering*)
                            APPLICATION=corporate-staff-rostering
                            ;;
                        hmpps-oem*)
                            APPLICATION=hmpps-oem
                            ;;
                    esac
                    YQ_QUERY='.db_configs as $db | ["'"${TARGET_DATABASES//,/\",\"}"'"] | map($db[.] .host_name + ":" + .) | join(",")'
                    echo "Q: $YQ_QUERY"
                    TARGET_PAIRS=$(yq "${YQ_QUERY}" ../../modernisation-platform-configuration-management/ansible/group_vars/environment_name_${TARGET_ENVIRONMENT}.yml)
                    # The host_name variable in the Ansible configuration has been set in one of 3 ways:
                    # (1) Using the inventory_hostname
                    # (2) Using a fully qualified hostname.  We can simply strip off the 
                    #     domain name to get the inventory_hostname.
                    # (3) Using an IP address.  We will need to lookup the Ansible inventory
                    #     to find out which host is using this as a private IPv4 address
                    # FQ Host:
                    TARGET_PAIRS=$(echo $TARGET_PAIRS | \
                        awk -F',' 'BEGIN{OFS=","}{
                            for (i=1; i<=NF; i++) {
                                n = split($i, p, ":"); # p[1]=host, p[2]=database
                                h = p[1]
                                if (h ~ /[A-Za-z]/) # contains a letter => hostname, not IP
                                sub(/\..*/, "", h)  # strip domain from the first dot
                                $i = h ":" p[2]
                            }
                            print
                            }'
                    )
                    RESOLVED_PAIRS=""
                    for PAIR in ${TARGET_PAIRS//,/ }
                    do
                       HOST_NAME=$(echo $PAIR | cut -f1 -d:)
                       DATABASE=$(echo $PAIR | cut -f2 -d:)
                       echo "HN: ${HOST_NAME}"
                       if [[ $HOST_NAME =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(:|$) ]]; then
                          echo "${HOST_NAME} is an IP!"
                                  resolve_ip "${HOST_NAME}"
                                  HOST_NAME="$RESOLVED_IP"
                          echo "${HOST_NAME}"
                       fi
                       if [ -z "$RESOLVED_PAIRS" ]; then
                          RESOLVED_PAIRS="${HOST_NAME}:${DATABASE}"
                       else
                          RESOLVED_PAIRS="${RESOLVED_PAIRS},${HOST_NAME}:${DATABASE}"
                       fi
                    done
                    TARGET_PAIRS=$RESOLVED_PAIRS
                    ;;
            *)      echo "Unknown application type"
                    ;;
          esac
          # ENVIRONMENT_TYPE is one of development|test|preproduction|production
          ENVIRONMENT_TYPE=$(echo ${TARGET_ENVIRONMENT} \
                              | sed 's/_/-/g' | awk -F${APPLICATION}- '{print $2}' \
                              | awk -F- '{print $1}' )
          echo "target_environment=${TARGET_ENVIRONMENT}"       
          echo "target_group=${TARGET_GROUP}"                   
          echo "application=${APPLICATION}"                      
          echo "environment_type=${ENVIRONMENT_TYPE}"           
          echo "account_name=${APPLICATION}-${ENVIRONMENT_TYPE}"
          echo "target_pairs=${TARGET_PAIRS}"                    

