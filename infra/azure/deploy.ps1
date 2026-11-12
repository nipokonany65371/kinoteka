#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Docker')]
param(
    [string]$ResourceGroup = 'rg-kinoteka',
    [string]$Location = 'francecentral',
    [string]$DatabaseVersion = '17',
    [Parameter(Mandatory, ParameterSetName = 'Docker')][string]$LocalImage,
    [Parameter(Mandatory, ParameterSetName = 'Archive')][string]$ImageArchive,
    [Parameter(Mandatory, ParameterSetName = 'Archive')][string]$Crane,
    [Parameter(Mandatory, ParameterSetName = 'Registry')]
    [ValidatePattern('^kinoteka:[A-Za-z0-9_.-]+$')][string]$PublishedTag
)

$ErrorActionPreference = 'Stop'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
$az = Get-Command az.cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (!$az) { $az = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' }

function Invoke-Az {
    $result = & $az @args --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI nie wykonał polecenia $($args[0..1] -join ' ')." }
    $result
}

function Save-Template($definition, $name) {
    $path = Join-Path $stateDirectory "$name.json"
    $definition | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    $path
}

function Get-Password($name) {
    $path = Join-Path $stateDirectory "$name.dpapi"
    if (!(Test-Path -LiteralPath $path)) {
        $password = 'Az1' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(28))
        ConvertTo-SecureString $password -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $path
    }
    ConvertTo-SecureString (Get-Content -LiteralPath $path -Raw).Trim() | ConvertFrom-SecureString -AsPlainText
}

$subscription = (Invoke-Az account show --query id -o tsv).Trim()
$tag = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$subscription/$ResourceGroup"))).Substring(0, 10).ToLowerInvariant()
$stateDirectory = Join-Path $env:LOCALAPPDATA "Kinoteka\Azure\$tag"
New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null

$regionalSuffix = "-$Location"
$environment = "kinoteka-env$regionalSuffix"
$network = "kinoteka-vnet$regionalSuffix"
$dnsZone = "$tag$regionalSuffix.private.postgres.database.azure.com"
$storage = "kinotekafiles$tag"
$registry = "kinoteka$tag"
$databaseServer = "kinoteka-pg-$tag$regionalSuffix"
$dbOwner = 'kinoteka_owner'
$dbPassword = Get-Password 'postgres-owner'
$runtimePassword = Get-Password 'postgres-runtime'
$secretKey = Get-Password 'flask'
$redisPassword = Get-Password 'redis'

Write-Host 'Tworzenie grupy zasobów i sieci prywatnej.'
if ((Invoke-Az group exists -n $ResourceGroup -o tsv) -eq 'false') {
    Invoke-Az group create -n $ResourceGroup -l $Location --tags project=kinoteka -o none
}
$networkExists = Invoke-Az network vnet list -g $ResourceGroup --query "[?name=='$network'].name | [0]" -o tsv
if (!$networkExists) {
    Invoke-Az network vnet create -g $ResourceGroup -n $network -l $Location --address-prefixes 10.56.0.0/16 -o none
}
$existingSubnets = Invoke-Az network vnet subnet list -g $ResourceGroup --vnet-name $network -o json | ConvertFrom-Json
$appSubnet = ($existingSubnets | Where-Object name -eq apps).id
if (!$appSubnet) {
    $appSubnet = Invoke-Az network vnet subnet create -g $ResourceGroup --vnet-name $network -n apps --address-prefixes 10.56.1.0/24 --delegations Microsoft.App/environments --service-endpoints Microsoft.Storage --query id -o tsv
}
$pgSubnet = ($existingSubnets | Where-Object name -eq postgres).id
if (!$pgSubnet) {
    $pgSubnet = Invoke-Az network vnet subnet create -g $ResourceGroup --vnet-name $network -n postgres --address-prefixes 10.56.2.0/27 --delegations Microsoft.DBforPostgreSQL/flexibleServers --query id -o tsv
}
$privateZone = Invoke-Az network private-dns zone list -g $ResourceGroup --query "[?name=='$dnsZone'].id | [0]" -o tsv
if (!$privateZone) {
    $privateZone = Invoke-Az network private-dns zone create -g $ResourceGroup -n $dnsZone --query id -o tsv
}
$dnsLink = Invoke-Az network private-dns link vnet list -g $ResourceGroup -z $dnsZone --query "[?name=='kinoteka'].name | [0]" -o tsv
if (!$dnsLink) {
    Invoke-Az network private-dns link vnet create -g $ResourceGroup -z $dnsZone -n kinoteka --virtual-network $network --registration-enabled false -o none
}

Write-Host 'Uruchamianie prywatnego PostgreSQL i środowiska Container Apps.'
$pgExists = Invoke-Az postgres flexible-server list -g $ResourceGroup --query "[?name=='$databaseServer'].name | [0]" -o tsv
if (!$pgExists) {
    Invoke-Az postgres flexible-server create -g $ResourceGroup -n $databaseServer -l $Location --version $DatabaseVersion --tier Burstable --sku-name Standard_B1ms --storage-size 32 --storage-auto-grow Enabled --backup-retention 7 --admin-user $dbOwner --admin-password $dbPassword --subnet $pgSubnet --private-dns-zone $privateZone -o none
}
$environmentExists = Invoke-Az containerapp env list -g $ResourceGroup --query "[?name=='$environment'].name | [0]" -o tsv
if (!$environmentExists) {
    Invoke-Az containerapp env create -g $ResourceGroup -n $environment -l $Location --infrastructure-subnet-resource-id $appSubnet --enable-workload-profiles true --logs-destination none -o none
}

Write-Host 'Konfiguracja Azure Files, rejestru obrazów i tożsamości wdrożenia.'
$storageExists = Invoke-Az storage account list -g $ResourceGroup --query "[?name=='$storage'].name | [0]" -o tsv
if (!$storageExists) {
    Invoke-Az storage account create -g $ResourceGroup -n $storage -l $Location --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false --https-only true --min-tls-version TLS1_2 -o none
}
Invoke-Az storage account network-rule add -g $ResourceGroup --account-name $storage --subnet $appSubnet -o none
Invoke-Az storage account update -g $ResourceGroup -n $storage --default-action Deny -o none
Invoke-Az storage share-rm create -g $ResourceGroup --storage-account $storage -n posters --quota 5 -o none
$storageKey = Invoke-Az storage account keys list -g $ResourceGroup -n $storage --query '[0].value' -o tsv

$registryExists = Invoke-Az acr list -g $ResourceGroup --query "[?name=='$registry'].name | [0]" -o tsv
if (!$registryExists) {
    Invoke-Az acr create -g $ResourceGroup -n $registry -l $Location --sku Basic --admin-enabled false --role-assignment-mode rbac -o none
}
$registryInfo = Invoke-Az acr show -g $ResourceGroup -n $registry -o json | ConvertFrom-Json
$identity = Invoke-Az identity create -g $ResourceGroup -n kinoteka-image-pull -l $Location -o json | ConvertFrom-Json
$pullAssignment = Invoke-Az role assignment list --scope $registryInfo.id --query "[?principalId=='$($identity.principalId)' && roleDefinitionName=='AcrPull'].id | [0]" -o tsv
if (!$pullAssignment) {
    Invoke-Az role assignment create --assignee-object-id $identity.principalId --assignee-principal-type ServicePrincipal --role AcrPull --scope $registryInfo.id -o none
}

$imageTag = if ($PublishedTag) { $PublishedTag } else { "kinoteka:$(Get-Date -AsUTC -Format 'yyyyMMddHHmmss')" }
$image = "$($registryInfo.loginServer)/$imageTag"
if ($LocalImage) {
    Write-Host 'Wgrywanie obrazu aplikacji do Azure Container Registry.'
    Invoke-Az acr login -n $registry -o none
    docker tag $LocalImage $image
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się otagować obrazu Kinoteki.' }
    docker push $image
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się wgrać obrazu Kinoteki.' }
} elseif ($ImageArchive) {
    Write-Host 'Wgrywanie obrazu aplikacji do Azure Container Registry.'
    $dockerConfig = Join-Path $stateDirectory "registry-$imageTag".Replace(':', '-')
    New-Item -ItemType Directory -Path $dockerConfig | Out-Null
    $previousConfig = $env:DOCKER_CONFIG
    $env:DOCKER_CONFIG = $dockerConfig
    try {
        $token = Invoke-Az acr login -n $registry --expose-token --query accessToken -o tsv
        $token | & $Crane auth login $registryInfo.loginServer --username '00000000-0000-0000-0000-000000000000' --password-stdin
        if ($LASTEXITCODE -ne 0) { throw 'Nie udało się zalogować do rejestru ACR.' }
        & $Crane push $ImageArchive $image
        if ($LASTEXITCODE -ne 0) { throw 'Nie udało się wgrać archiwum obrazu do ACR.' }
    } finally {
        $env:DOCKER_CONFIG = $previousConfig
        Remove-Item -LiteralPath (Join-Path $dockerConfig 'config.json') -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dockerConfig -ErrorAction SilentlyContinue
    }
}

if ((Invoke-Az postgres flexible-server show -g $ResourceGroup -n $databaseServer --query state -o tsv) -ne 'Ready') {
    throw 'Serwer PostgreSQL nie osiągnął stanu Ready.'
}
$databaseExists = Invoke-Az postgres flexible-server db list -g $ResourceGroup --server-name $databaseServer --query "[?name=='kinoteka'].name | [0]" -o tsv
if (!$databaseExists) {
    Invoke-Az postgres flexible-server db create -g $ResourceGroup --server-name $databaseServer --name kinoteka -o none
}
$envDeadline = (Get-Date).AddMinutes(12)
do {
    $containerEnv = Invoke-Az containerapp env show -g $ResourceGroup -n $environment -o json | ConvertFrom-Json
    $envStatus = $containerEnv.properties.provisioningState
    if ($envStatus -in @('Succeeded', 'Failed', 'Canceled')) { break }
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt $envDeadline)
if ($envStatus -ne 'Succeeded') { throw "Środowisko Container Apps zakończyło oczekiwanie ze statusem $envStatus." }
Invoke-Az containerapp env storage set -g $ResourceGroup -n $environment --storage-name posters --azure-file-account-name $storage --azure-file-account-key $storageKey --azure-file-share-name posters --access-mode ReadWrite -o none
$dbHost = Invoke-Az postgres flexible-server show -g $ResourceGroup -n $databaseServer --query fullyQualifiedDomainName -o tsv
$dbEndpoint = "${dbHost}:5432/kinoteka?sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt"
$adminUrl = "postgresql+psycopg://${dbOwner}:${dbPassword}@$dbEndpoint"
$runtimeUrl = "postgresql+psycopg://kinoteka_app:${runtimePassword}@$dbEndpoint"

$appIdentity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $identity.id = @{} } }
$registryConfig = @(@{ server = $registryInfo.loginServer; identity = $identity.id })
$webResources = @{ cpu = 0.25; memory = '0.5Gi' }

Write-Host 'Migracja schematu i nadanie uprawnień aplikacji.'
$job = @{
    name = 'kinoteka-migrate'; location = $Location; identity = $appIdentity
    properties = @{
        environmentId = $containerEnv.id; workloadProfileName = 'Consumption'
        configuration = @{
            triggerType = 'Manual'; replicaTimeout = 300; replicaRetryLimit = 0
            manualTriggerConfig = @{ parallelism = 1; replicaCompletionCount = 1 }
            registries = $registryConfig
            secrets = @(
                @{ name = 'db-owner-url'; value = $adminUrl }, @{ name = 'runtime-password'; value = $runtimePassword }, @{ name = 'flask-key'; value = $secretKey }
            )
        }
        template = @{ containers = @(@{
            name = 'migration'; image = $image; resources = @{ cpu = 0.5; memory = '1Gi' }
            command = @('sh', '-ec', 'python -m flask db upgrade && python infra/azure/grant_runtime.py')
            env = @(
                @{ name = 'DATABASE_URL'; secretRef = 'db-owner-url' }, @{ name = 'RUNTIME_DB_PASSWORD'; secretRef = 'runtime-password' }, @{ name = 'SECRET_KEY'; secretRef = 'flask-key' }
            )
        }) }
    }
}
$jobFile = Save-Template $job 'migration'
$jobExists = Invoke-Az containerapp job list -g $ResourceGroup --query "[?name=='kinoteka-migrate'].name | [0]" -o tsv
$operation = if ($jobExists) { 'update' } else { 'create' }
try {
    Invoke-Az containerapp job $operation -g $ResourceGroup -n kinoteka-migrate --yaml $jobFile -o none
} finally { Remove-Item -LiteralPath $jobFile -ErrorAction SilentlyContinue }
$execution = Invoke-Az containerapp job start -g $ResourceGroup -n kinoteka-migrate --query name -o tsv
$deadline = (Get-Date).AddMinutes(7)
do {
    Start-Sleep -Seconds 8
    $migrationStatus = Invoke-Az containerapp job execution show -g $ResourceGroup -n kinoteka-migrate --job-execution-name $execution --query properties.status -o tsv
} while ($migrationStatus -notin @('Succeeded', 'Failed', 'Stopped') -and (Get-Date) -lt $deadline)
if ($migrationStatus -ne 'Succeeded') { throw "Migracja zakończyła się statusem $migrationStatus (wykonanie $execution)." }

function Set-ContainerApp($definition) {
    $name = $definition.name
    $resourceId = "/subscriptions/$subscription/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$name"
    $endpoint = "https://management.azure.com${resourceId}?api-version=2025-01-01"
    $templateFile = Save-Template $definition $name
    try {
        Invoke-Az rest --method put --url $endpoint --body "@$templateFile" -o none
    } finally { Remove-Item -LiteralPath $templateFile -ErrorAction SilentlyContinue }

    $deadline = (Get-Date).AddMinutes(8)
    do {
        Start-Sleep -Seconds 8
        $status = Invoke-Az containerapp show -g $ResourceGroup -n $name --query properties.provisioningState -o tsv
    } while ($status -notin @('Succeeded', 'Failed', 'Canceled') -and (Get-Date) -lt $deadline)
    if ($status -ne 'Succeeded') { throw "Container App $name zakończyła oczekiwanie ze statusem $status." }
}

Write-Host 'Uruchamianie wewnętrznego Redis i publicznej aplikacji Kinoteka.'
$redis = @{
    name = 'kinoteka-limits'; location = $Location
    properties = @{
        managedEnvironmentId = $containerEnv.id; workloadProfileName = 'Consumption'
        configuration = @{
            activeRevisionsMode = 'Single'
            secrets = @(@{ name = 'redis-password'; value = $redisPassword })
            ingress = @{ external = $false; targetPort = 6379; exposedPort = 6379; transport = 'tcp' }
        }
        template = @{
            scale = @{ minReplicas = 1; maxReplicas = 1 }
            containers = @(@{
                name = 'redis'; image = 'docker.io/library/redis:7.4-alpine'; resources = @{ cpu = 0.25; memory = '0.5Gi' }
                command = @('sh', '-ec', 'exec docker-entrypoint.sh redis-server --requirepass "$REDIS_PASSWORD" --save "" --appendonly no')
                env = @(@{ name = 'REDIS_PASSWORD'; secretRef = 'redis-password' })
            })
        }
    }
}
Set-ContainerApp $redis
$appIngress = @{ external = $true; targetPort = 8000; transport = 'http'; allowInsecure = $false }
$existingApp = Invoke-Az containerapp list -g $ResourceGroup --query "[?name=='kinoteka'] | [0]" -o json | ConvertFrom-Json
if ($existingApp.properties.configuration.ingress.customDomains) {
    $appIngress.customDomains = $existingApp.properties.configuration.ingress.customDomains
}
$app = @{
    name = 'kinoteka'; location = $Location; identity = $appIdentity
    properties = @{
        managedEnvironmentId = $containerEnv.id; workloadProfileName = 'Consumption'
        configuration = @{
            activeRevisionsMode = 'Single'; ingress = $appIngress; registries = $registryConfig
            secrets = @(
                @{ name = 'db-url'; value = $runtimeUrl }, @{ name = 'flask-key'; value = $secretKey },
                @{ name = 'ratelimit-url'; value = "redis://:${redisPassword}@kinoteka-limits:6379/0?socket_timeout=3" }
            )
        }
        template = @{
            scale = @{ minReplicas = 2; maxReplicas = 4; rules = @(@{ name = 'http'; http = @{ metadata = @{ concurrentRequests = '10' } } }) }
            volumes = @(@{ name = 'posters'; storageType = 'AzureFile'; storageName = 'posters'; mountOptions = 'uid=10001,gid=10001,file_mode=0640,dir_mode=0750' })
            containers = @(@{
                name = 'web'; image = $image; resources = $webResources
                env = @(
                    @{ name = 'DATABASE_URL'; secretRef = 'db-url' }, @{ name = 'SECRET_KEY'; secretRef = 'flask-key' }, @{ name = 'RATELIMIT_STORAGE_URI'; secretRef = 'ratelimit-url' },
                    @{ name = 'TRUSTED_PROXIES'; value = '1' }, @{ name = 'SESSION_COOKIE_SECURE'; value = 'true' }, @{ name = 'UPLOAD_FOLDER'; value = '/app/instance/uploads' },
                    @{ name = 'DB_POOL_SIZE'; value = '2' }, @{ name = 'DB_MAX_OVERFLOW'; value = '1' }
                )
                volumeMounts = @(@{ volumeName = 'posters'; mountPath = '/app/instance/uploads' })
                probes = @(
                    @{ type = 'Liveness'; httpGet = @{ path = '/live'; port = 8000 }; periodSeconds = 10 },
                    @{ type = 'Readiness'; httpGet = @{ path = '/live'; port = 8000 }; periodSeconds = 5 }
                )
            })
        }
    }
}
Set-ContainerApp $app
$publicHost = Invoke-Az containerapp show -g $ResourceGroup -n kinoteka --query properties.configuration.ingress.fqdn -o tsv
Write-Output "https://$publicHost"
