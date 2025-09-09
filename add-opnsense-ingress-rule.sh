#!/bin/bash

# OPNsense API configuration
OPNSENSE_HOST="10.0.1.1"
API_KEY="mjlzaIQeZQEgYyFUbMMJ0RKMNaN09cuJjihSFt0IiJlcJQLcS/IIOAi+4DI/BqyBwEGoa0uMYV/FBK3D"
API_SECRET="ax3oit85pYjcNXmVvk2ai21q/B2ENpuBssbw5AkIfikaxkmd2559KHa6tfadlLr6Z1Jpx2+P40PZOq4z"

# Firewall rule configuration
RULE_JSON='{
  "rule": {
    "enabled": "1",
    "action": "pass",
    "quick": "1",
    "interface": "lan",
    "direction": "in",
    "ipprotocol": "inet",
    "protocol": "TCP",
    "source": "10.0.1.0/24",
    "destination": "10.0.7.200",
    "destination_port": "80",
    "descr": "Allow access to Kubernetes Ingress Controller HTTP",
    "log": "0"
  }
}'

RULE_JSON_HTTPS='{
  "rule": {
    "enabled": "1",
    "action": "pass",
    "quick": "1",
    "interface": "lan",
    "direction": "in",
    "ipprotocol": "inet",
    "protocol": "TCP",
    "source": "10.0.1.0/24",
    "destination": "10.0.7.200",
    "destination_port": "443",
    "descr": "Allow access to Kubernetes Ingress Controller HTTPS",
    "log": "0"
  }
}'

# Function to make API call
make_api_call() {
    local method=$1
    local endpoint=$2
    local data=$3
    
    if [ -z "$data" ]; then
        curl -k -s -X "$method" \
            -u "$API_KEY:$API_SECRET" \
            "https://$OPNSENSE_HOST/api/$endpoint"
    else
        curl -k -s -X "$method" \
            -u "$API_KEY:$API_SECRET" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "https://$OPNSENSE_HOST/api/$endpoint"
    fi
}

echo "Adding firewall rules to allow access to Kubernetes Ingress Controller..."

# Add the HTTP firewall rule
echo "Adding HTTP rule (port 80)..."
RESPONSE=$(make_api_call "POST" "firewall/filter/addRule" "$RULE_JSON")

if echo "$RESPONSE" | grep -q '"uuid"'; then
    echo "✓ HTTP firewall rule added successfully"
    UUID_HTTP=$(echo "$RESPONSE" | grep -o '"uuid":"[^"]*"' | cut -d'"' -f4)
    echo "  Rule UUID: $UUID_HTTP"
else
    echo "✗ Failed to add HTTP firewall rule"
    echo "Response: $RESPONSE"
fi

# Add the HTTPS firewall rule
echo "Adding HTTPS rule (port 443)..."
RESPONSE_HTTPS=$(make_api_call "POST" "firewall/filter/addRule" "$RULE_JSON_HTTPS")

if echo "$RESPONSE_HTTPS" | grep -q '"uuid"'; then
    echo "✓ HTTPS firewall rule added successfully"
    UUID_HTTPS=$(echo "$RESPONSE_HTTPS" | grep -o '"uuid":"[^"]*"' | cut -d'"' -f4)
    echo "  Rule UUID: $UUID_HTTPS"
else
    echo "✗ Failed to add HTTPS firewall rule"
    echo "Response: $RESPONSE_HTTPS"
fi

# Apply the changes
echo ""
echo "Applying firewall changes..."
APPLY_RESPONSE=$(make_api_call "POST" "firewall/filter/apply" '{}')

if echo "$APPLY_RESPONSE" | grep -q '"status":"OK"'; then
    echo "✓ Firewall rules applied successfully"
    echo ""
    echo "The following rules have been added:"
    echo "  Source: 10.0.1.0/24 (LAN)"
    echo "  Destination: 10.0.7.200:80 (HTTP)"
    echo "  Destination: 10.0.7.200:443 (HTTPS)"
    echo "  Action: PASS"
    echo ""
    echo "Your media services should now be accessible at:"
    echo "  - http://jellyseerr.asandov.local"
    echo "  - http://radarr.asandov.local"
    echo "  - http://sonarr.asandov.local"
    echo "  - http://jellyfin.asandov.local"
else
    echo "⚠ Warning: Rules added but apply might have failed"
    echo "Response: $APPLY_RESPONSE"
    echo ""
    echo "You may need to apply the changes manually in the OPNsense web UI"
fi