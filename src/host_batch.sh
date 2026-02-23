#!/bin/bash

function host_batch {
input=$1

IFS=',' read -ra items <<< "$input"

# Array of subsets
declare -a subsets
# Track which keys appear in each subset
declare -a used

for pair in "${items[@]}"; do
    key="${pair%%:*}"
    placed=false

    # Try to place into existing subsets
    for i in "${!subsets[@]}"; do
        if [[ " ${used[$i]} " != *" $key "* ]]; then
            if [[ -z "${subsets[$i]}" ]]; then
                subsets[$i]="$pair"
            else
                subsets[$i]="${subsets[$i]},$pair"
            fi
            used[$i]="${used[$i]} $key"
            placed=true
            break
        fi
    done

    # If no subset could take it, create new subset
    if ! $placed; then
        subsets+=("$pair")
        used+=("$key")
    fi
done

# Print results
for s in "${subsets[@]}"; do
    echo "$s"
done
}

host_batch $1