// Metro Hot Seating — pilot environment.
// Deployed by infra/deploy.sh (which creates the Entra app registration first).

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Environment name used in resource names.')
@allowed([ 'dev', 'prod' ])
param env string = 'dev'

@description('Short unique suffix for globally unique names (computed by deploy.sh).')
param suffix string

@description('Client ID of the Entra app registration used for sign-in.')
param authClientId string

@secure()
@description('Client secret of the Entra app registration.')
param authClientSecret string

@description('Object ID of the Entra user or group that administers the SQL server.')
param sqlAdminObjectId string

@description('Display name / UPN of that SQL admin.')
param sqlAdminLogin string

@description('User or Group.')
@allowed([ 'User', 'Group' ])
param sqlAdminPrincipalType string = 'User'

var tenantId = subscription().tenantId
var base = 'metroseating-${env}'
var appName = 'app-${base}-${suffix}'
var tags = {
  app: 'metro-hot-seating'
  env: env
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}'
  location: location
  tags: tags
}

resource logs 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${base}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${base}'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

resource sqlServer 'Microsoft.Sql/servers@2021-11-01' = {
  name: 'sql-${base}-${suffix}'
  location: location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: sqlAdminPrincipalType
      login: sqlAdminLogin
      sid: sqlAdminObjectId
      tenantId: tenantId
      azureADOnlyAuthentication: true
    }
  }
}

// Lets Azure services (the App Service) reach the server. The app still has to
// authenticate with its managed identity.
resource sqlAllowAzure 'Microsoft.Sql/servers/firewallRules@2021-11-01' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2021-11-01' = {
  parent: sqlServer
  name: 'sqldb-${base}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
}

resource pubsub 'Microsoft.SignalRService/webPubSub@2024-03-01' = {
  name: 'wps-${base}-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Free_F1'
    tier: 'Free'
    capacity: 1
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-${base}'
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    keyVaultReferenceIdentity: identity.id
    siteConfig: {
      linuxFxVersion: 'NODE|22-lts'
      appCommandLine: 'npm start'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      healthCheckPath: '/healthz'
      appSettings: [
        { name: 'SQL_SERVER', value: sqlServer.properties.fullyQualifiedDomainName }
        { name: 'SQL_DATABASE', value: sqlDb.name }
        { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
        { name: 'WEBPUBSUB_CONNECTION_STRING', value: pubsub.listKeys().primaryConnectionString }
        { name: 'WEBPUBSUB_HUB', value: 'seating' }
        { name: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET', value: authClientSecret }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
        { name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: '~3' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'WEBSITE_HEALTHCHECK_MAXPINGFAILURES', value: '10' }
      ]
    }
  }
}

resource auth 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: site
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
      excludedPaths: [ '/healthz' ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: 'https://login.microsoftonline.com/${tenantId}/v2.0'
          clientId: authClientId
          clientSecretSettingName: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
        }
        validation: {
          allowedAudiences: [ authClientId, 'api://${authClientId}' ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: true
      }
    }
    httpSettings: {
      requireHttps: true
    }
  }
}

output appName string = site.name
output appUrl string = 'https://${site.properties.defaultHostName}'
output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDb.name
output identityName string = identity.name
output identityClientId string = identity.properties.clientId
output webPubSubName string = pubsub.name
