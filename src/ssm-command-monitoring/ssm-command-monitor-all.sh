#!/bin/bash
basedir=$(dirname "$0")
applications=$1
environments=$2
interval=$3
if [[ -z $interval ]]; then
  echo "Usage: $0 <applications> <environments> <interval>" >&2
  echo >&2
  echo "e.g. $0 nomis '' 86400" >&2
  exit 1
fi
shift 3
accounts=$("$basedir"/../get_dso_aws_accounts.sh text "$applications" "$environments")

echo "Account,DocumentName,SuccessCount,FailedCount,IgnoreCount"
for account in $accounts; do
  echo "$account: ssm-command-monitor.py --interval $interval --profile $account" >&2
  python3 "$basedir"/ssm-command-monitor.py --interval "$interval" --profile "$account" "$@" | tail -n +2 | sed -e "s/^/$account,/"
done
