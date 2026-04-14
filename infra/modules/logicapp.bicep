@description('Azure region for all resources')
param location string

@description('Tags to apply to all resources')
param tags object

@description('Name for the Logic App plan')
param planName string

@description('Name for the Logic App')
param appName string

@description('Name for the user-assigned managed identity')
param identityName string

@description('Resource ID of the subnet for VNet integration')
param subnetId string

@description('Resource ID of the storage account to grant RBAC on')
param storageAccountId string

@description('Blob service endpoint of the storage account')
param storageBlobEndpoint string

@description('Queue service endpoint of the storage account')
param storageQueueEndpoint string

@description('Table service endpoint of the storage account')
param storageTableEndpoint string

@description('Application Insights connection string')
param appInsightsConnectionString string

@description('Resource ID of the Key Vault for content storage connection string')
param keyVaultId string

@description('Resource ID of the content storage account')
param contentStorageAccountId string

@description('Key Vault reference for content storage connection string')
param contentStorageConnectionStringReference string

@description('Name of the content file share')
param contentShareName string

//
// User-Assigned Managed Identity
//
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: identityName
  location: location
  tags: tags
}

//
// Storage RBAC for this identity
//
var storageRoleIds = [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
  '17d1049b-9a84-46fb-8f53-869881c3d3ab' // Storage Account Contributor
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
  '69566ab7-960f-475b-8e7c-b3118f30c6bd' // Storage File Data Privileged Contributor
]

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: last(split(storageAccountId, '/'))
}

resource storageRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in storageRoleIds: {
    scope: storageAccount
    name: guid(identity.id, storageAccountId, roleId)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalType: 'ServicePrincipal'
      principalId: identity.properties.principalId
    }
  }
]

//
// Key Vault RBAC — Key Vault Secrets User for the user-assigned identity
//
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(keyVaultId, '/'))
}

resource kvRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(identity.id, keyVaultId, '4633458b-17de-408a-b874-0445c86b69e6')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalType: 'ServicePrincipal'
    principalId: identity.properties.principalId
  }
}

//
// Logic App Plan (Workflow Standard WS1)
//
resource plan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'elastic'
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
    size: 'WS1'
    family: 'WS'
    capacity: 1
  }
}

//
// Logic App Standard
//
resource app 'Microsoft.Web/sites@2022-09-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  properties: {
    serverFarmId: plan.id
    publicNetworkAccess: 'Enabled'
    httpsOnly: true
    virtualNetworkSubnetId: subnetId
    keyVaultReferenceIdentity: identity.id
    siteConfig: {
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'node' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION', value: '22' }
        // Workflow storage via managed identity
        { name: 'AzureWebJobsStorage__blobServiceUri', value: storageBlobEndpoint }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: storageQueueEndpoint }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: storageTableEndpoint }
        // Storage via user-assigned identity
        { name: 'AzureWebJobsStorage__managedIdentityResourceId', value: identity.id }
        { name: 'AzureWebJobsStorage__credential', value: 'managedIdentity' }
        // VNet routing
        { name: 'vnetRouteAllEnabled', value: '1' }
        { name: 'WEBSITE_CONTENTOVERVNET', value: '1' }
        { name: 'AzureFunctionsJobHost__extensionBundle__id', value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows' }
        { name: 'AzureFunctionsJobHost__extensionBundle__version', value: '${'[1.*,'}${' 2.0.0)'}' }
        { name: 'APP_KIND', value: 'workflowApp' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
        // Content file share via Key Vault reference
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: contentStorageConnectionStringReference }
        { name: 'WEBSITE_CONTENTSHARE', value: contentShareName }
        { name: 'WORKFLOWS_RESOURCE_GROUP_NAME', value: resourceGroup().name }
        { name: 'WORKFLOWS_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'WORKFLOWS_LOCATION_NAME', value: location }
        { name: 'WORKFLOWS_TENANT_ID', value: subscription().tenantId }
        { name: 'WORKFLOWS_MANAGEMENT_BASE_URI', value: 'https://management.azure.com/' }
      ]
    }
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
}

output name string = app.name
output identityPrincipalId string = identity.properties.principalId
