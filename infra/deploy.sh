#!/usr/bin/env bash
# Deploys the Metro Hot Seating pilot. Run from the repo root in Azure Cloud Shell
# (or any shell where `az login` is done):
#
#   ./infra/deploy.sh                 # dev, East US
#   LOCATION=eastus2 ./infra/deploy.sh
#
# Safe to re-run: it reuses the resource group, app registration and resources.
set -euo pipefail

ENV_NAME="${ENV_NAME:-dev}"
LOCATION="${LOCATION:-eastus}"
RG="${RG:-rg-metroseating-${ENV_NAME}}"
APP_DISPLAY="Metro Hot Seating (${ENV_NAME})"
GRAPH=https://graph.microsoft.com/v1.0
ADMIN_ROLE_ID=7b2a0f1e-3c51-4a5b-9e2d-6f1c8a4d2b01

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }

cd "$(dirname "$0")/.."

say "Checking Azure sign-in"
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
TENANT_DOMAIN=$(az rest --method get --url "$GRAPH/organization?\$select=verifiedDomains" \
  --query "value[0].verifiedDomains[?isDefault].name | [0]" -o tsv 2>/dev/null || echo "unknown")
ME_ID=$(az ad signed-in-user show --query id -o tsv)
ME_UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv)
echo "Tenant:       $TENANT_DOMAIN ($TENANT_ID)"
echo "Subscription: $SUB_NAME ($SUB_ID)"
echo "Signed in as: $ME_UPN"
echo "Will deploy:  $RG in $LOCATION"
if [[ "${YES:-}" != "1" ]]; then
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Stopped."; exit 1; }
fi

SUFFIX=$(printf '%s' "$SUB_ID/$RG" | sha1sum | cut -c1-5)

say "Registering resource providers (first run only takes a minute)"
for ns in Microsoft.Web Microsoft.Sql Microsoft.SignalRService Microsoft.OperationalInsights Microsoft.Insights Microsoft.ManagedIdentity; do
  state=$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo NotRegistered)
  if [[ "$state" != "Registered" ]]; then az provider register -n "$ns" --wait; fi
done

say "Resource group $RG"
az group create -n "$RG" -l "$LOCATION" --tags app=metro-hot-seating env="$ENV_NAME" -o none

say "Entra app registration: $APP_DISPLAY"
APP_ID=$(az ad app list --display-name "$APP_DISPLAY" --query "[0].appId" -o tsv)
if [[ -z "$APP_ID" ]]; then
  APP_ID=$(az ad app create --display-name "$APP_DISPLAY" --sign-in-audience AzureADMyOrg \
    --app-roles @infra/app-roles.json --enable-id-token-issuance true --query appId -o tsv)
  echo "Created app $APP_ID"
else
  az ad app update --id "$APP_ID" --app-roles @infra/app-roles.json --enable-id-token-issuance true
  echo "Reusing app $APP_ID"
fi
# Sign-in needs Microsoft Graph User.Read (delegated)
az ad app permission add --id "$APP_ID" --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope -o none 2>/dev/null || true
SECRET=$(az ad app credential reset --id "$APP_ID" --append --display-name "app-service-$(date +%Y%m%d)" \
  --years 1 --query password -o tsv 2>/dev/null)

SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)
if [[ -z "$SP_ID" ]]; then
  SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  sleep 15   # let the new service principal replicate
fi
az ad sp update --id "$SP_ID" --set appRoleAssignmentRequired=true
az ad app permission admin-consent --id "$APP_ID" 2>/dev/null \
  || warn "Couldn't grant admin consent for User.Read; users may see a consent prompt on first sign-in."

say "Giving $ME_UPN the Seating Admin role"
HAS=$(az rest --method get --url "$GRAPH/servicePrincipals/$SP_ID/appRoleAssignedTo" \
  --query "length(value[?principalId=='$ME_ID'])" -o tsv)
if [[ "$HAS" == "0" ]]; then
  for i in 1 2 3 4 5; do
    if az rest --method post --url "$GRAPH/servicePrincipals/$SP_ID/appRoleAssignedTo" \
      --headers Content-Type=application/json \
      --body "{\"principalId\":\"$ME_ID\",\"resourceId\":\"$SP_ID\",\"appRoleId\":\"$ADMIN_ROLE_ID\"}" -o none; then
      break
    fi
    sleep 10
  done
fi

say "Deploying Azure resources (about 5 minutes)"
OUT=$(az deployment group create -g "$RG" -n "metroseating-$(date +%Y%m%d%H%M%S)" \
  -f infra/main.bicep \
  -p env="$ENV_NAME" suffix="$SUFFIX" authClientId="$APP_ID" authClientSecret="$SECRET" \
     sqlAdminObjectId="$ME_ID" sqlAdminLogin="$ME_UPN" \
  --query properties.outputs -o json)
out() { printf '%s' "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1']['value'])"; }
APP_NAME=$(out appName); APP_URL=$(out appUrl)
SQL_NAME=$(out sqlServerName); SQL_FQDN=$(out sqlServerFqdn); SQL_DB=$(out sqlDatabaseName)
ID_NAME=$(out identityName); ID_CLIENT=$(out identityClientId)

say "Setting sign-in redirect for $APP_URL"
az ad app update --id "$APP_ID" --web-redirect-uris "$APP_URL/.auth/login/aad/callback"

say "Installing app dependencies"
npm ci --omit=dev --no-audit --no-fund

say "Granting the app's managed identity access to the database"
MYIP=$(curl -s https://api.ipify.org)
az sql server firewall-rule create -g "$RG" -s "$SQL_NAME" -n deploy-shell \
  --start-ip-address "$MYIP" --end-ip-address "$MYIP" -o none
cleanup() { az sql server firewall-rule delete -g "$RG" -s "$SQL_NAME" -n deploy-shell -o none 2>/dev/null || true; }
trap cleanup EXIT
sleep 20   # firewall rules take a moment to apply
SQL_TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv) \
  node tools/sql-grant.js "$SQL_FQDN" "$SQL_DB" "$ID_NAME" "$ID_CLIENT"

say "Deploying the app code"
PKG=$(mktemp -d)/hotseat.zip
zip -qr "$PKG" package.json package-lock.json server public data db
az webapp deploy -g "$RG" -n "$APP_NAME" --src-path "$PKG" --type zip -o none

say "Waiting for the app to start"
for i in $(seq 1 30); do
  if curl -fsS "$APP_URL/healthz" 2>/dev/null; then echo; break; fi
  sleep 10
done

cat <<EOF

Done.
  App:          $APP_URL
  Sign in as:   $ME_UPN (Seating Admin)
  Resources:    $RG (delete the resource group to remove everything)

Add supervisors: Entra admin center > Enterprise applications > "$APP_DISPLAY"
  > Users and groups > Add > choose people or a group > role "Seating Supervisor".
EOF
