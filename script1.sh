#!/usr/bin/env bash
set -euo pipefail

# --- CHECK AUTOMÁTICO DE LOGIN E DEPENDÊNCIAS -------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Erro: comando '$1' não encontrado. Instale e tente novamente." >&2
    exit 1
  }
}
require_cmd az
require_cmd jq

ensure_az_login() {
  if az account show -o none 2>/dev/null; then
    echo ">> Azure CLI: sessão já autenticada."
  else
    echo ">> Azure CLI: não autenticado. Iniciando 'az login --use-device-code'..."
    if [[ -n "${AZ_TENANT_ID:-}" ]]; then
      az login --tenant "$AZ_TENANT_ID" --use-device-code -o none
    else
      az login --use-device-code -o none
    fi
  fi

  if [[ -n "${AZ_SUBSCRIPTION:-}" ]]; then
    echo ">> Selecionando subscription: $AZ_SUBSCRIPTION"
    az account set --subscription "$AZ_SUBSCRIPTION"
  fi

  echo ">> Contexto atual:"
  az account show --query "{name:name, subscriptionId:id, tenant:tenantId}" -o tsv \
    | awk -v OFS='\t' '{print "   - Name: "$1, "   - Sub: "$2, "   - Tenant: "$3}'
}
ensure_az_login
# ---------------------------------------------------------------------------

########################
# VARIÁVEIS EDITÁVEIS  #
########################
LOCATION="brazilsouth"
RG_TARGET="RG-ACT-BKP"                     # RG de WebApp/Plan/Storage
RG_SQL="RG-ONR-ACT"                        # RG do servidor SQL existente
SQL_SERVER_NAME="onr-act-sql"              # sem .database.windows.net
DB_NAME="restpkiact-backup"
ASP_NAME="asp-restpki-act-bkp"
PLAN_SKU="P1v3"
WEBAPP_NAME="restpki-act-backup"

# Imagem privada no ACR
CONTAINER_IMAGE="acronract.azurecr.io/restpkicore:stable"
DOCKER_REGISTRY_SERVER_URL="https://acronract.azurecr.io/"
DOCKER_REGISTRY_SERVER_USERNAME="acronract"

# Rede (já existente e delegada a Microsoft.Web/serverFarms)
VNET_NAME="vnet-onr-act-bkp"
SUBNET_NAME="subnet-act-restpki"

# Storage (nome globalmente único; ajuste se já existir)
STG_PREFIX="strestpkiactbkp001"      # <=24 chars, minúsculo, sem hífen
STG_NAME="${STG_PREFIX}"
STG_CONTAINER="appdata"

#################################
# RESOURCE GROUP
#################################
echo ">> Verificando Resource Group $RG_TARGET..."
if az group exists -n "$RG_TARGET" | grep -qi true; then
  echo ">> RG $RG_TARGET já existe. Seguindo..."
else
  echo ">> Criando RG $RG_TARGET em $LOCATION..."
  az group create -n "$RG_TARGET" -l "$LOCATION" -o none
fi

#################################
# STORAGE ACCOUNT + CONTAINER
#################################
echo ">> Criando/garantindo Storage Account $STG_NAME..."
az storage account create \
  -g "$RG_TARGET" -n "$STG_NAME" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 -o none || true

echo ">> Criando container '$STG_CONTAINER' (idempotente)..."
STG_KEY=$(az storage account keys list -g "$RG_TARGET" -n "$STG_NAME" --query "[0].value" -o tsv)
az storage container create -n "$STG_CONTAINER" --account-name "$STG_NAME" --account-key "$STG_KEY" -o none

#################################
# APP SERVICE PLAN (LINUX) + WEB APP (CONTAINER)
#################################
echo ">> Criando App Service Plan $ASP_NAME ($PLAN_SKU)..."
az appservice plan create -g "$RG_TARGET" -n "$ASP_NAME" --is-linux --sku "$PLAN_SKU" -o none || true

echo ">> Criando Web App $WEBAPP_NAME (Linux/Container)..."
# tenta flag nova
if az webapp create -g "$RG_TARGET" -p "$ASP_NAME" -n "$WEBAPP_NAME" \
  --deployment-container-image-name "$CONTAINER_IMAGE" -o none 2>/dev/null; then
  echo ">> Web App criado com --deployment-container-image-name"
else
  # tenta flag antiga (para CLI antigos)
  az webapp create -g "$RG_TARGET" -p "$ASP_NAME" -n "$WEBAPP_NAME" \
    --container-image-name "$CONTAINER_IMAGE" -o none
  echo ">> Web App criado com --container-image-name"
fi

#################################
# INTEGRAÇÃO COM VNET/SUBNET
#################################
echo ">> Integrando Web App à VNET $VNET_NAME / $SUBNET_NAME..."
az webapp vnet-integration add -g "$RG_TARGET" -n "$WEBAPP_NAME" \
  --vnet "$VNET_NAME" --subnet "$SUBNET_NAME" -o none

#################################
# DATABASE NO SQL EXISTENTE (no RG do servidor)
#################################
echo ">> Criando database $DB_NAME no servidor $SQL_SERVER_NAME (RG $RG_SQL)..."
az sql db create -g "$RG_SQL" -s "$SQL_SERVER_NAME" -n "$DB_NAME" \
  --service-objective S0 -o none || true

#################################
# MANAGED IDENTITY + AAD NO SQL
#################################
echo ">> Ativando Managed Identity (system-assigned) no Web App..."
IDENTITY_JSON=$(az webapp identity assign -g "$RG_TARGET" -n "$WEBAPP_NAME" -o json)
WEBAPP_PRINCIPAL_ID=$(echo "$IDENTITY_JSON" | jq -r '.principalId')

# Verifica AAD Admin do servidor
set +e
AAD_ADMIN_JSON=$(az sql server ad-admin show -g "$RG_SQL" -s "$SQL_SERVER_NAME" -o json 2>/dev/null)
HAS_AAD_ADMIN=$?
set -e

if [[ $HAS_AAD_ADMIN -ne 0 || -z "$AAD_ADMIN_JSON" ]]; then
  echo "!! AVISO: O servidor SQL '$SQL_SERVER_NAME' não tem Azure AD admin configurado."
  echo "   Configure um AAD admin antes de criar o usuário do MI no banco."
  SKIP_DB_USER_CREATION=1
else
  SKIP_DB_USER_CREATION=0
fi

if [[ "$SKIP_DB_USER_CREATION" -eq 0 ]]; then
  echo ">> Criando usuário AAD do Managed Identity no DB e concedendo permissões..."
  az extension add -n sql >/dev/null || true
  TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
  DB_USER="$WEBAPP_NAME"

  TSQL=$(cat <<'EOSQL'
DECLARE @user sysname = N'__DB_USER__';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @user)
BEGIN
    EXEC(N'CREATE USER [' + @user + N'] FROM EXTERNAL PROVIDER;');
END;
EXEC sp_addrolemember N'db_datareader', @user;
EXEC sp_addrolemember N'db_datawriter', @user;
EOSQL
)
  TSQL="${TSQL/__DB_USER__/${DB_USER}}"

  az sql db query -g "$RG_SQL" -s "$SQL_SERVER_NAME" -n "$DB_NAME" \
    --access-token "$TOKEN" --querytext "$TSQL" -o none
fi

#################################
# ACR: CREDENCIAIS + (RE)DEFINIR IMAGEM
#################################
echo ">> Configurando credenciais do ACR no Web App..."
az webapp config appsettings set -g "$RG_TARGET" -n "$WEBAPP_NAME" --settings \
  DOCKER_REGISTRY_SERVER_URL="$DOCKER_REGISTRY_SERVER_URL" \
  DOCKER_REGISTRY_SERVER_USERNAME="$DOCKER_REGISTRY_SERVER_USERNAME" \
  DOCKER_REGISTRY_SERVER_PASSWORD="$DOCKER_REGISTRY_SERVER_PASSWORD" -o none

echo ">> (Re)definindo imagem $CONTAINER_IMAGE no Web App..."
az webapp config container set -g "$RG_TARGET" -n "$WEBAPP_NAME" \
  -i "$CONTAINER_IMAGE" -r "$DOCKER_REGISTRY_SERVER_URL" \
  -u "$DOCKER_REGISTRY_SERVER_USERNAME" -p "$DOCKER_REGISTRY_SERVER_PASSWORD" -o none

#################################
# CONNECTION STRINGS E APP SETTINGS
#################################
echo ">> Configurando connection strings e app settings..."
AZURE_STORAGE_CONNECTION_STRING=$(az storage account show-connection-string -g "$RG_TARGET" -n "$STG_NAME" -o tsv)
SQL_CONN_STR="Server=tcp:${SQL_SERVER_NAME}.database.windows.net,1433;Initial Catalog=${DB_NAME};Encrypt=True;Connection Timeout=30;Authentication=Active Directory Managed Identity;"

az webapp config connection-string set -g "$RG_TARGET" -n "$WEBAPP_NAME" \
  --settings "DefaultConnection=${SQL_CONN_STR}" --connection-string-type SQLAzure -o none

az webapp config appsettings set -g "$RG_TARGET" -n "$WEBAPP_NAME" --settings \
  "AZURE_STORAGE_CONNECTION_STRING=${AZURE_STORAGE_CONNECTION_STRING}" \
  "AZURE_STORAGE_CONTAINER=${STG_CONTAINER}" -o none

#################################
# SAÍDA FINAL
#################################
echo "------------------------------------------------------------"
echo "Web App:            https://${WEBAPP_NAME}.azurewebsites.net"
echo "Resource Group:     ${RG_TARGET}"
echo "App Service Plan:   ${ASP_NAME} (${PLAN_SKU})"
echo "Storage Account:    ${STG_NAME}"
echo "Storage Container:  ${STG_CONTAINER}"
echo "SQL Server (exist.):${SQL_SERVER_NAME} (RG ${RG_SQL})"
echo "Database:           ${DB_NAME}"
echo "Container Image:    ${CONTAINER_IMAGE}"
echo "VNET/Subnet:        ${VNET_NAME}/${SUBNET_NAME}"
echo "Managed Identity:   principalId=${WEBAPP_PRINCIPAL_ID}"
echo "------------------------------------------------------------"
echo "OBS:"
echo "- Sem firewall 0.0.0.0 no SQL; acesso via subnet integrada."
echo "- Connection string usa 'Active Directory Managed Identity'."
echo "- Se o Storage name já existir globalmente, ajuste STG_PREFIX/STG_NAME."