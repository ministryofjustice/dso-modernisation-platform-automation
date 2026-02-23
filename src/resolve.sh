#!/bin/bash

 jq -r --arg ip "$1" '
  ._meta.hostvars
  | to_entries
  | map(select(.value.network_interfaces[]?.private_ip_address == $ip))
  | .[].key
' < <(ansible-inventory -i /inventory --list)
