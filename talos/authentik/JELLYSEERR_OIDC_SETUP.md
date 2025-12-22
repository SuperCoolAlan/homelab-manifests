# Jellyseerr OIDC Setup with Authentik

## Authentik Configuration

### 1. Create OAuth2/OpenID Provider

1. Navigate to Admin → Providers → Create
2. Select **OAuth2/OpenID Provider**
3. Configure:
   - **Name**: `jellyseerr`
   - **Authorization flow**: `default-provider-authorization-explicit-consent`
   - **Redirect URI**: `https://jellyseerr.asandov.local/api/v1/auth/oidc-callback`
   - **Signing Key**: Select an available key
4. Save and note the **Client ID** and **Client Secret**

### 2. Create Application

1. Navigate to Admin → Applications → Create
2. Configure:
   - **Name**: `Jellyseerr`
   - **Slug**: `jellyseerr`
   - **Provider**: Select `jellyseerr` (the provider created above)
3. Save

## Jellyseerr Configuration

1. Navigate to `https://jellyseerr.asandov.local`
2. Go to **Settings → Users**
3. Enable **"Enable OIDC Sign-In"**
4. Click **"Add OIDC Provider"** and configure:
   - **Provider Name**: `Authentik`
   - **Issuer URL**: `https://authentik.asandov.local/application/o/jellyseerr/`
   - **Client ID**: *(paste from Authentik)*
   - **Client Secret**: *(paste from Authentik)*
5. Save changes

## Verification

1. Log out of Jellyseerr
2. You should see an "Authentik" login button
3. Clicking it redirects to Authentik for authentication
4. After successful auth, you're redirected back to Jellyseerr
