#!/usr/bin/env bash
# Read-only check of a Genesys OAuth client stored in Key Vault: finds its
# region, then reports whether it can read users and WFM management units.
# Prints status codes and unit names only; never prints the secret or token.
#   ./tools/genesys-check.sh <vault> <secret-name>
set -uo pipefail
VAULT="$1"; NAME="$2"
CFG=$(az keyvault secret show --vault-name "$VAULT" -n "$NAME" --query value -o tsv)
ID=$(jq -r '.clientId // .ClientId // .ClientID // .client_id // .CLIENT_ID // empty' <<<"$CFG" 2>/dev/null)
SECRET=$(jq -r '.Secret // .secret // .clientSecret // .ClientSecret // .client_secret // .CLIENT_SECRET // empty' <<<"$CFG" 2>/dev/null)
if [[ -z "$ID" || -z "$SECRET" ]]; then
  echo "$NAME: couldn't find a client ID and secret. Field names present: $(jq -r 'keys|join(", ")' <<<"$CFG" 2>/dev/null || echo 'not JSON')"
  exit 1
fi
unset CFG
for host in mypurecloud.com usw2.pure.cloud use2.us-gov-pure.cloud cac1.pure.cloud mypurecloud.ie euw2.pure.cloud mypurecloud.de mypurecloud.com.au mypurecloud.jp apne2.pure.cloud aps1.pure.cloud sae1.pure.cloud; do
  TOKEN=$(curl -s -u "$ID:$SECRET" -d grant_type=client_credentials "https://login.$host/oauth/token" | jq -r '.access_token // empty')
  if [[ -n "$TOKEN" ]]; then REGION=$host; break; fi
done
unset SECRET
if [[ -z "${REGION:-}" ]]; then echo "$NAME: could not get a token in any region"; exit 1; fi
echo "$NAME: region $REGION"
api() { curl -s -o /tmp/gc.json -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "https://api.$REGION$1"; }
echo "  users (read):            HTTP $(api '/api/v2/users?pageSize=1')"
echo "  WFM business units:      HTTP $(api '/api/v2/workforcemanagement/businessunits')"
jq -r '.entities[]?.name | "      - " + .' /tmp/gc.json 2>/dev/null
echo "  WFM management units:    HTTP $(api '/api/v2/workforcemanagement/managementunits?pageSize=100')"
jq -r '.entities[]?.name | "      - " + .' /tmp/gc.json 2>/dev/null
rm -f /tmp/gc.json
