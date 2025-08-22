#!/bin/bash

# Gumroad Bounty Monitor Script
# This script checks for new bounty issues on the Gumroad repository

REPO="antiwork/gumroad"
CACHE_FILE=".bounty_cache"
NOTIFY_FILE="new_bounties.md"

echo "🔍 Checking for Gumroad bounty issues..."
echo "========================================="

# Get all open issues with dollar amounts in labels
gh issue list --repo $REPO --state open --json number,title,labels,createdAt,assignees,url | \
jq -r '.[] | select(.labels[].name | contains("$")) | 
  "\(.number)|\(.title)|\(.labels | map(.name) | join(","))|\(.createdAt)|\(.assignees | map(.login) | join(","))|\(.url)"' > current_bounties.txt

# Check if cache file exists
if [ ! -f "$CACHE_FILE" ]; then
    echo "First run - creating cache file..."
    cp current_bounties.txt "$CACHE_FILE"
else
    # Compare with cache to find new issues
    NEW_ISSUES=$(comm -13 <(sort "$CACHE_FILE") <(sort current_bounties.txt))
    
    if [ ! -z "$NEW_ISSUES" ]; then
        echo "🎉 NEW BOUNTY ISSUES FOUND!"
        echo ""
        echo "$NEW_ISSUES" | while IFS='|' read -r number title labels created assignees url; do
            echo "Issue #$number: $title"
            echo "  Labels: $labels"
            echo "  Created: $created"
            echo "  Assignees: ${assignees:-None}"
            echo "  URL: $url"
            echo ""
        done
        
        # Save to notification file
        echo "# New Bounty Issues - $(date)" > "$NOTIFY_FILE"
        echo "" >> "$NOTIFY_FILE"
        echo "$NEW_ISSUES" | while IFS='|' read -r number title labels created assignees url; do
            echo "## Issue #$number: $title" >> "$NOTIFY_FILE"
            echo "- **Labels:** $labels" >> "$NOTIFY_FILE"
            echo "- **Created:** $created" >> "$NOTIFY_FILE"
            echo "- **Assignees:** ${assignees:-None}" >> "$NOTIFY_FILE"
            echo "- **URL:** $url" >> "$NOTIFY_FILE"
            echo "" >> "$NOTIFY_FILE"
        done
        
        echo "✅ New issues saved to $NOTIFY_FILE"
    else
        echo "No new bounty issues found."
    fi
    
    # Update cache
    cp current_bounties.txt "$CACHE_FILE"
fi

# Display current status
echo ""
echo "📊 Current Bounty Status:"
echo "------------------------"

while IFS='|' read -r number title labels created assignees url; do
    # Extract bounty amount from labels
    bounty=$(echo "$labels" | grep -oE '\$[0-9]+\.?[0-9]*K?' | head -1)
    
    # Check if assigned
    if [ -z "$assignees" ]; then
        status="✅ Available"
    else
        status="⚠️ Assigned to: $assignees"
    fi
    
    echo "• #$number: $title ($bounty) - $status"
done < current_bounties.txt

echo ""
echo "Total issues with bounties: $(wc -l < current_bounties.txt | tr -d ' ')"

# Clean up
rm -f current_bounties.txt

echo ""
echo "💡 Tip: Run this script regularly or add it to cron for automatic monitoring"
echo "   Example for hourly checks: */60 * * * * cd $(pwd) && ./monitor_bounties.sh"
