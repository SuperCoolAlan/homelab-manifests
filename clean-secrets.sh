#!/bin/bash

# Script to remove API keys from git history
# WARNING: This will rewrite git history!

echo "WARNING: This will rewrite git history and force-push to the repository."
echo "Make sure no one else is working on the repository."
echo "Press Enter to continue or Ctrl+C to cancel..."
read

# Create backup branch
git branch backup-before-cleanup

# List of strings to remove from history
SECRETS=(
  "e5462d745721475db235a8bc4eb32a07"  # Prowlarr API key
  "5097a715fb084ca1ab07670ef50dcd68"  # Sonarr API key  
  "1ac50a71923a4e9589e028dbc89140a3"  # Radarr API key
  "6ad3e11326f41310f01942750a984825"  # Bazarr API key
  "VIcQhG9ELcIQRpFgPctQB2a3jHStkpeu"  # NZBgeek API key
)

# Remove each secret from history
for SECRET in "${SECRETS[@]}"; do
  echo "Removing secret: ${SECRET:0:8}..."
  git filter-branch --force --index-filter \
    "git ls-files -z | xargs -0 sed -i '' -e 's/${SECRET}/REDACTED/g'" \
    --prune-empty --tag-name-filter cat -- --all
done

echo "Cleanup complete. Review the changes and then run:"
echo "  git push --force --all"
echo "  git push --force --tags"
echo ""
echo "Also notify all team members to re-clone the repository."