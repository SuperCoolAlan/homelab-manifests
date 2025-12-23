# Jellyseerr OIDC Setup with Authentik

## Authentik Configuration

### 1. Create OAuth2/OpenID Provider

1. Navigate to Admin → Providers → Create
2. Select **OAuth2/OpenID Provider**
3. Configure:
   - **Name**: `jellyseerr`
   - **Authorization flow**: `default-provider-authorization-explicit-consent`
   - **Redirect URI**: `http://jellyseerr.asandov.local/login?provider=authentik&callback=true`
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

**Note**: Requires `preview-OIDC` Docker tag (OIDC not in stable release yet).

1. Navigate to `http://jellyseerr.asandov.local`
2. Go to **Settings → Users**
3. Enable **OpenID Connect** and add provider:
   - **Provider Name**: `authentik`
   - **Logo**: `http://authentik.asandov.local/static/dist/assets/icons/icon.svg`
   - **Issuer URL**: `http://authentik.asandov.local/application/o/jellyseerr/`
   - **Client ID**: *(paste from Authentik)*
   - **Client Secret**: *(paste from Authentik)*
   - **Scopes**: `openid profile email groups`
   - **Allow New Users**: Enabled
4. Save changes

## Verification

1. Log out of Jellyseerr
2. You should see an "Authentik" login button
3. Clicking it redirects to Authentik for authentication
4. After successful auth, you're redirected back to Jellyseerr
