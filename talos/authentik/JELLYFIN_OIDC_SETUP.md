# Jellyfin OIDC Setup with Authentik

Uses the [jellyfin-plugin-sso](https://github.com/9p4/jellyfin-plugin-sso) plugin.

## Authentik Configuration

### 1. Create OAuth2/OpenID Provider

1. Navigate to Admin → Providers → Create
2. Select **OAuth2/OpenID Provider**
3. Configure:
   - **Name**: `jellyfin`
   - **Authorization flow**: `default-provider-authorization-explicit-consent`
   - **Redirect URI**: `http://jellyfin.asandov.local/sso/OID/redirect/Authentik`
   - **Signing Key**: Select an available key
4. Save and note the **Client ID** and **Client Secret**

### 2. Create Application

1. Navigate to Admin → Applications → Create
2. Configure:
   - **Name**: `Jellyfin`
   - **Slug**: `jellyfin`
   - **Provider**: Select `jellyfin` (the provider created above)
3. Save

## Jellyfin Configuration

### 1. Install SSO Plugin

1. In Jellyfin, go to **Dashboard → Plugins → Repositories**
2. Add repository: `https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/main/manifest.json`
3. Go to **Catalog** and install **SSO Authentication**
4. Restart Jellyfin

### 2. Configure SSO Provider

1. Go to **Dashboard → Plugins → SSO Authentication**
2. Add a new OIDC provider with:
   - **Provider Name**: `Authentik`
   - **OID Endpoint**: `https://authentik.asandov.local/application/o/jellyfin/`
   - **Client ID**: *(paste from Authentik)*
   - **Client Secret**: *(paste from Authentik)*
   - **Enabled**: `true`
   - **Enable Authorization**: `true` (optional - manages user permissions via Authentik)
   - **Enable All Folders**: `true` (or configure specific folders)
3. Save

## Verification

1. Log out of Jellyfin (or open incognito)
2. Go to `http://jellyfin.asandov.local`
3. You should see a "Sign in with Authentik" button on the login page
4. Clicking it redirects to Authentik for authentication
5. After successful auth, you're redirected back and logged into Jellyfin

## Notes

- The redirect URI uses `http://` since the homelab uses internal HTTP
- The OIDC endpoint must match the application slug in Authentik (`jellyfin`)
- Users logging in via SSO for the first time will have accounts auto-created
