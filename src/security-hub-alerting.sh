#!/bin/bash

# Configuration
REGION="eu-west-2"
DAYS=7

# Get AWS account ID and name/alias
# ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
# ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases' --output text 2>/dev/null)
ACCOUNT_ID=%2
ACCOUNT_ALIAS=%1

# Use alias if available, otherwise use account ID for display name
# if [ "$ACCOUNT_ALIAS" != "None" ] && [ ! -z "$ACCOUNT_ALIAS" ]; then
#     ACCOUNT_NAME="$ACCOUNT_ALIAS"
# else
#     ACCOUNT_NAME="$ACCOUNT_ID"
# fi

echo "Count of New findings in last $DAYS days:"
echo
printf "%-15s %-10s %-8s %s\n" "ACCOUNT ID" "Critical" "High" "Account Name"
printf "%-15s %-10s %-8s %s\n" "----------" "--------" "----" "------------"

total_critical=0
total_high=0

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
    critical_count=$(aws securityhub get-findings \
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
    
    # Get count of high findings for this day
    high_count=$(aws securityhub get-findings \
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
                \"Value\": \"HIGH\", 
                \"Comparison\": \"EQUALS\"
            }]
        }" \
        --query 'length(Findings)' \
        --output text 2>/dev/null)
    
    # Handle potential errors
    if [ $? -ne 0 ] || [ -z "$critical_count" ]; then
        critical_count=0
    fi
    
    if [ $? -ne 0 ] || [ -z "$high_count" ]; then
        high_count=0
    fi
    
    total_critical=$((total_critical + critical_count))
    total_high=$((total_high + high_count))
    
    # Optional: Show daily breakdown (uncomment next lines if desired)
    # echo "  $date_str: $critical_count critical, $high_count high findings"
done

# Outputs
OUTPUT_FILE=account-"$ACCOUNT_ALIAS".txt

printf "%-15s %-10s %-8s %s\n" "$ACCOUNT_ID" "$total_critical" "$total_high" "$ACCOUNT_NAME"
echo
echo "Report saved to: $OUTPUT_FILE"

# Write formatted output to file and display results
# {
#     echo "Count of New findings in last $DAYS days:"
#     echo
#     printf "%-15s %-10s %-8s %s\n" "ACCOUNT ID" "Critical" "High" "Account Name"
#     printf "%-15s %-10s %-8s %s\n" "----------" "--------" "----" "------------"
#     printf "%-15s %-10s %-8s %s\n" "$ACCOUNT_ID" "$total_critical" "$total_high" "$ACCOUNT_NAME"
# } >> "$OUTPUT_FILE"
{
    printf "%-15s %-10s %-8s %s\n" "$ACCOUNT_ID" "$total_critical" "$total_high" "$ACCOUNT_NAME"
} >> "$OUTPUT_FILE"