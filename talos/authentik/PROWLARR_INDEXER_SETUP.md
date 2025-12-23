# Prowlarr Indexer Configuration

## Access URLs
- **Prowlarr**: https://prowlarr.asandov.local/
- **Sonarr**: https://sonarr.asandov.local/
- **Radarr**: https://radarr.asandov.local/
- **Bazarr**: https://bazarr.asandov.local/

## API Keys (for reference)
- **Prowlarr API Key**: `e5462d745721475db235a8bc4eb32a07`
- **Sonarr API Key**: `5097a715fb084ca1ab07670ef50dcd68`
- **Radarr API Key**: `1ac50a71923a4e9589e028dbc89140a3`
- **Bazarr API Key**: `6ad3e11326f41310f01942750a984825`

## Step 1: Configure Prowlarr Applications

### Add Sonarr to Prowlarr
1. Go to Prowlarr: https://prowlarr.asandov.local/
2. Navigate to Settings → Apps
3. Click the + button and select "Sonarr"
4. Configure:
   - Name: `Sonarr`
   - Sync Level: `Full Sync`
   - Prowlarr Server: `http://prowlarr:9696` (internal service)
   - Sonarr Server: `http://sonarr:8989` (internal service)
   - API Key: `5097a715fb084ca1ab07670ef50dcd68`
   - Test and Save

### Add Radarr to Prowlarr
1. In Prowlarr Settings → Apps
2. Click the + button and select "Radarr"
3. Configure:
   - Name: `Radarr`
   - Sync Level: `Full Sync`
   - Prowlarr Server: `http://prowlarr:9696` (internal service)
   - Radarr Server: `http://radarr:7878` (internal service)
   - API Key: `1ac50a71923a4e9589e028dbc89140a3`
   - Test and Save

### Add Bazarr to Prowlarr (Optional)
Note: Bazarr doesn't use indexers directly, but connects to Sonarr/Radarr for subtitle management.

## Step 2: Add Indexers to Prowlarr

### Add Usenet Indexers (if you have accounts)
Popular Usenet indexers:
1. **NZBgeek**
   - Go to Indexers → Add Indexer
   - Search for "NZBgeek"
   - Enter your API key from NZBgeek account
   - Test and Save

2. **NZBFinder**
   - Search for "NZBFinder"
   - Enter API key
   - Test and Save

3. **DrunkenSlug**
   - Search for "DrunkenSlug"
   - Enter API key
   - Test and Save

### Add Torrent Indexers (if needed)
1. **Public trackers** (use with caution):
   - The Pirate Bay
   - 1337x
   - RARBG (if still available)

2. **Private trackers** (require invites):
   - Configure with your credentials

## Step 3: Configure Bazarr for Subtitles

1. Go to Bazarr: https://bazarr.asandov.local/
2. Navigate to Settings → Sonarr
   - Address: `http://sonarr:8989`
   - API Key: `5097a715fb084ca1ab07670ef50dcd68`
   - Test and Save

3. Navigate to Settings → Radarr
   - Address: `http://radarr:7878`
   - API Key: `1ac50a71923a4e9589e028dbc89140a3`
   - Test and Save

4. Configure subtitle providers in Settings → Providers
   - OpenSubtitles (requires free account)
   - Subscene
   - Addic7ed (for TV shows)

## Step 4: Verify Integration

1. **In Prowlarr**: Check that all apps show as healthy in Settings → Apps
2. **In Sonarr/Radarr**: 
   - Go to Settings → Indexers
   - You should see all indexers synced from Prowlarr
   - They should show as healthy (green)
3. **Test search**: Try searching for a show/movie to verify indexers work

## Troubleshooting

### If apps can't connect:
- Ensure all pods are running: `kubectl -n media-v2 get pods`
- Check internal DNS resolution works
- Verify API keys are correct

### If indexers don't sync:
- Check Prowlarr logs: Settings → General → Logs
- Ensure "Full Sync" is enabled in Prowlarr app settings
- Manually trigger sync in Prowlarr: Settings → Apps → Click sync button

## Notes
- SABnzbd is already configured with Eweka and Newshosting servers
- Download clients should be configured in Sonarr/Radarr to point to SABnzbd
- All services use internal Kubernetes DNS names for communication (service-name:port)