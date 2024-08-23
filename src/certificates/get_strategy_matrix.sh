#!/bin/bash
config=$(dirname "$0")/certs.json
ec2s=

if [[ $1 == "ec2_hostname" ]]; then
  if [[ -z $2 ]]; then
    ec2s=$(jq -r '.certs[].ec2_hostname' "$config")
  else
    ec2s=$(jq -r '.certs[].ec2_hostname' "$config" | grep "$2")
  fi
elif [[ $1 == "schedule" ]]; then
  ec2s=$(jq -r  '.certs[] | select(.schedule == '"$2"') | .ec2_hostname' "$config")
else
  echo "Usage: $0 ec2_hostname|schedule <value>" 
  exit 1
fi
if [[ -z $ec2s ]]; then
  echo "No matching configuration for $1 $2"
  exit 1
fi

echo '{"include":['
(
  for ec2 in $ec2s; do
    echo '{"ec2_hostname": "'"$ec2"'"},'
  done
) | sed '$s/,$//'
echo ']}'
