# Media Stack Manual Setup Steps

This document contains manual configuration steps that must be performed after deploying the media stack. These settings are stored in application databases and cannot be easily managed via GitOps.

## Prowlarr

### Indexer Age Filtering

**Why**: Prevents downloading old Usenet releases with missing/expired articles that cause download failures.

**Steps**:
1. Navigate to Prowlarr UI: `http://prowlarr.asandov.local`
2. Go to **Settings → Indexers**
3. Click on **NZBgeek**
4. Click **Show Advanced**
5. Find **Additional Parameters** field
6. Enter: `&maxage=1500`
7. Click **Save**

**What it does**: Filters all searches to only return releases posted within the last 1500 days (~4 years), reducing failures from expired Usenet articles.

**API Command** (alternative):
```bash
# Get current config
curl -H "X-Api-Key: YOUR_API_KEY" http://prowlarr.asandov.local/api/v1/indexer/1 > indexer.json

# Edit the additionalParameters field to add &maxage=1500

# Update via API
curl -X PUT -H "X-Api-Key: YOUR_API_KEY" -H "Content-Type: application/json" \
  -d @indexer.json http://prowlarr.asandov.local/api/v1/indexer/1
```

---

## Radarr

### Indexer Age Filtering

**Why**: Prevents downloading old Usenet releases with missing/expired articles that cause download failures.

**Steps**:
1. Navigate to Radarr UI: `http://radarr.asandov.local`
2. Go to **Settings → Indexers**
3. Click on **NZBgeek (Prowlarr)**
4. Click **Show Advanced**
5. Find **Additional Parameters** field
6. Enter: `&maxage=1500`
7. Click **Save**

**What it does**: Filters all movie searches to only return releases posted within the last 1500 days (~4 years), reducing failures from expired Usenet articles.

**API Command** (alternative):
```bash
# Get current config
curl -H "X-Api-Key: YOUR_API_KEY" http://radarr.asandov.local/api/v3/indexer/1 > indexer.json

# Edit the additionalParameters field to add &maxage=1500

# Update via API
curl -X PUT -H "X-Api-Key: YOUR_API_KEY" -H "Content-Type: application/json" \
  -d @indexer.json http://radarr.asandov.local/api/v3/indexer/1
```

---

## Sonarr

### Indexer Age Filtering

**Why**: Prevents downloading old Usenet releases with missing/expired articles that cause download failures.

**Steps**:
1. Navigate to Sonarr UI: `http://sonarr.asandov.local`
2. Go to **Settings → Indexers**
3. Click on **NZBgeek (Prowlarr)**
4. Click **Show Advanced**
5. Find **Additional Parameters** field
6. Enter: `&maxage=1500`
7. Click **Save**

**What it does**: Filters all TV show searches to only return releases posted within the last 1500 days (~4 years), reducing failures from expired Usenet articles.

**API Command** (alternative):
```bash
# Get current config
curl -H "X-Api-Key: YOUR_API_KEY" http://sonarr.asandov.local/api/v3/indexer/1 > indexer.json

# Edit the additionalParameters field to add &maxage=1500

# Update via API
curl -X PUT -H "X-Api-Key: YOUR_API_KEY" -H "Content-Type: application/json" \
  -d @indexer.json http://sonarr.asandov.local/api/v3/indexer/1
```

---

## Notes

- Config jobs have been attempted and disabled due to reliability issues
- These manual steps only need to be performed on fresh deployments
- Settings persist in application databases on their respective PVCs
