#!/usr/bin/env bash
# One-time setup so GitHub Actions can deploy this app on every merge to main.
#
# Run in Azure Cloud Shell (Bash), signed in to the tenant that holds the app,
# after infra/deploy.sh has created the environment:
#     ./infra/setup-github-deploy.sh
#
# It creates a user-assigned managed identity that trusts only GitHub Actions
# runs from this repo's main branch (OIDC federated credential, no secret),
# lets it deploy to the web app and nothing else, and prints the five
# repository variables to add in GitHub. Safe to re-run.
set -euo pipefail

ENV_NAME="${ENV_NAME:-dev}"
RG="${RG:-rg-metroseating-${ENV_NAME}}"
REPO="${REPO:-j3interactive/Hot-Seat}"
BRANCH="${BRANCH:-main}"
ID_NAME="id-metroseating-github-${ENV_NAME}"

say() { printf '\n==> %s\n' "$*"; }

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
say "Subscription: $(az account show --query name -o tsv) ($SUB_ID)"

APP_NAME=$(az webapp list -g "$RG" --query "[0].name" -o tsv)
[[ -n "$APP_NAME" ]] || { echo "No web app found in $RG. Run ./infra/deploy.sh first." >&2; exit 1; }
APP_ID=$(az webapp show -g "$RG" -n "$APP_NAME" --query id -o tsv)
LOCATION=$(az group show -n "$RG" --query location -o tsv)
say "Web app: $APP_NAME"

say "Creating deploy identity $ID_NAME"
az identity create -g "$RG" -n "$ID_NAME" -l "$LOCATION" -o none
CLIENT_ID=$(az identity show -g "$RG" -n "$ID_NAME" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g "$RG" -n "$ID_NAME" --query principalId -o tsv)

say "Trusting GitHub Actions runs from $REPO on branch $BRANCH"
SUBJECT="repo:${REPO}:ref:refs/heads/${BRANCH}"
if ! az identity federated-credential show -g "$RG" --identity-name "$ID_NAME" -n github-main -o none 2>/dev/null; then
  az identity federated-credential create -g "$RG" --identity-name "$ID_NAME" -n github-main \
    --issuer https://token.actions.githubusercontent.com \
    --subject "$SUBJECT" \
    --audiences api://AzureADTokenExchange -o none
fi

say "Allowing it to deploy to $APP_NAME only (Website Contributor on the app)"
for i in $(seq 1 12); do   # a new identity can take a moment to appear in Entra
  if az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
       --role "Website Contributor" --scope "$APP_ID" -o none 2>/dev/null; then
    break
  fi
  [[ $i == 12 ]] && { echo "Couldn't assign the role. Re-run this script in a minute." >&2; exit 1; }
  sleep 10
done

cat <<EOF

Done. Now add these in GitHub:
  https://github.com/${REPO}/settings/variables/actions
  Variables tab > New repository variable (these are IDs, not secrets)

  AZURE_CLIENT_ID         $CLIENT_ID
  AZURE_TENANT_ID         $TENANT_ID
  AZURE_SUBSCRIPTION_ID   $SUB_ID
  AZURE_RESOURCE_GROUP    $RG
  AZURE_WEBAPP_NAME       $APP_NAME

Then run the first deploy: GitHub > Actions > "Deploy (dev)" > Run workflow.
After that, every merge to $BRANCH deploys automatically.
EOF
