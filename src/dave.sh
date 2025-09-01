#!/bin/bash

# Configuration
REGION="eu-west-2"
DAYS=7

# Get AWS account name/alias (fallback to account ID if no alias)
ACCOUNT_NAME=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null)

# Use alias if available, otherwise use account ID
if [ "$ACCOUNT_ALIAS" != "None" ] && [ ! -z "$ACCOUNT_ALIAS" ]; then
    DISPLAY_ACCOUNT="$ACCOUNT_ALIAS"
else
    DISPLAY_ACCOUNT="$ACCOUNT_NAME"
fi

echo "Count of New findings in last $DAYS days:"
echo
printf "%-20s %-10s %s\n" "ACCOUNT" "Critical" "Account Name"
printf "%-20s %-10s %s\n" "-------" "--------" "------------"

total_count=0

# Loop through the last 7 days
for i in $(seq 0 $((DAYS-1))); do
    # Calculate date string (works on both macOS and Linux)
    if date -v-1d > /dev/null 2>&1; then
        # macOS date command
        date_str=$(date -v-${i}d +%Y-%m-%d)
    else
        # Linux date command
        date_str=$(date -d "${i} days ago" +%Y-%m-%d)
    fi
    
    start_time="${date_str}T00:00:00.000Z"
    end_time="${date_str}T23:59:59.999Z"
    
    # Get count of critical findings for this day
    count=$(aws securityhub get-findings \
        --region "$REGION" \
        --filters "{
            \"CreatedAt\": [{
                \"Start\": \"${start_time}\", 
                \"End\": \"${end_time}\"
            }], 
            \"RecordState\": [{
                \"Value\": \"ACTIVE\", 
                \"Comparison\": \"EQUALS\"
            }], 
            \"SeverityLabel\": [{
                \"Value\": \"CRITICAL\", 
                \"Comparison\": \"EQUALS\"
            }]
        }" \
        --query 'length(Findings)' \
        --output text 2>/dev/null)
    
    # Handle potential errors
    if [ $? -ne 0 ] || [ -z "$count" ]; then
        count=0
    fi
    
    total_count=$((total_count + count))
    
    # Optional: Show daily breakdown (uncomment next line if desired)
    # echo "  $date_str: $count findings"
done

# Display summary
printf "%-20s %-10s %s\n" "$DISPLAY_ACCOUNT" "$total_count" "$DISPLAY_ACCOUNT"

echo
echo "Total Critical findings in last $DAYS days: $total_count"