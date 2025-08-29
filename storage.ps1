<# ------------------------------------------------------------
    Creates/ensures a container named after 'storageCompany'
    from config.properties, then generates a CONTAINER-LEVEL
    SAS URL (no blob is created). Prints a ready upload link
    and an AzCopy example to upload files into the container.

    Parameters are loaded from config.properties
------------------------------------------------------------- #>

# Function to load configuration from properties file
function Load-Config {
    param([string]$configPath)
    
    $config = @{}
    if (Test-Path $configPath) {
        Write-Host "Loading configuration from: $configPath"
        Get-Content $configPath | ForEach-Object {
            $line = $_.Trim()
            if ($line -and !$line.StartsWith('#')) {
                $key, $value = $line -split '=', 2
                if ($key -and $value) {
                    $config[$key.Trim()] = $value.Trim()
                }
            }
        }
    } else {
        Write-Error "Configuration file not found: $configPath"
        exit 1
    }
    return $config
}

# Load configuration
$configPath = Join-Path $PSScriptRoot "config.properties"
$config = Load-Config -configPath $configPath

# Extract parameters from config
$SubscriptionId = $config.subscriptionId
$ResourceGroupName = $config.storageResourceGroupName
$Location = $config.storageLocation
$StorageAccountName = $config.storageSasAccountName
$CompanyNameRaw = $config.storageCompany
$SasDays = [int]$config.storageSasDays

# Normalize company name into a valid Azure Blob container name
function Convert-ToValidContainerName {
    param([string]$name)
    if (-not $name) { return $null }
    $n = $name.ToLower()
    $n = ($n -replace "[^a-z0-9-]", "-")
    # Collapse multiple dashes
    while ($n -match "--") { $n = $n -replace "--", "-" }
    # Trim leading/trailing dashes
    $n = $n.Trim('-')
    # Ensure length 3-63 with leading/trailing alnum
    if ($n.Length -lt 3) { $n = ($n + "-cont").PadRight(3, 'x') }
    if ($n.Length -gt 63) { $n = $n.Substring(0,63).Trim('-') }
    # Ensure starts with letter/number
    if ($n -notmatch '^[a-z0-9]') { $n = "a" + $n }
    # Ensure ends with letter/number
    if ($n -notmatch '[a-z0-9]$') { $n = $n + "0" }
    return $n
}

if (-not $CompanyNameRaw) {
    Write-Error "'storageCompany' is missing in config.properties. Please set it."
    exit 1
}

$ContainerName = Convert-ToValidContainerName -name $CompanyNameRaw

Write-Host "=== Storage SAS URL Generator ===" -ForegroundColor Green
Write-Host "Configuration loaded:" -ForegroundColor Cyan
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "  Location: $Location" -ForegroundColor White
Write-Host "  Storage Account: $StorageAccountName" -ForegroundColor White
Write-Host "  Container (derived from storageCompany): $ContainerName" -ForegroundColor White
Write-Host "  SAS Days: $SasDays" -ForegroundColor White
Write-Host ""

# Default behavior - create resources if missing
$CreateRgIfMissing = $true
$CreateStorageIfMissing = $true

# 0) Authentication and subscription
Write-Host "Checking Azure CLI..." -ForegroundColor Cyan

# Check if Azure CLI is available
try {
    $azVersion = az --version 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure CLI not found. Please install Azure CLI first."
        exit 1
    }
    Write-Host "Azure CLI is available" -ForegroundColor Green
} catch {
    Write-Error "Azure CLI not found. Please install Azure CLI first."
    exit 1
}

# Check Azure login status
Write-Host "Checking Azure CLI login status..." -ForegroundColor Cyan
try {
    $account = az account show --output json 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $account) {
        Write-Host "Not logged in to Azure CLI. Please run 'az login' first." -ForegroundColor Yellow
        Write-Error "Please login to Azure CLI using 'az login' command"
        exit 1
    } else {
        Write-Host "Already logged in to Azure CLI as: $($account.user.name)" -ForegroundColor Green
    }
    
    # Set subscription
    Write-Host "Setting subscription: $SubscriptionId" -ForegroundColor Cyan
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to set subscription: $SubscriptionId"
        exit 1
    }
    Write-Host "Subscription set successfully" -ForegroundColor Green
    
} catch {
    Write-Error "Azure CLI authentication check failed: $($_.Exception.Message)"
    exit 1
}

# 1) Resource Group
Write-Host "Checking resource group: $ResourceGroupName" -ForegroundColor Cyan
try {
    $rgJson = az group show --name $ResourceGroupName --output json 2>$null
    if ($LASTEXITCODE -ne 0 -and $CreateRgIfMissing) {
        Write-Host "Creating resource group: $ResourceGroupName" -ForegroundColor Yellow
        az group create --name $ResourceGroupName --location $Location --output none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Resource group created successfully" -ForegroundColor Green
        } else {
            Write-Error "Failed to create resource group: $ResourceGroupName"
            exit 1
        }
    } elseif ($LASTEXITCODE -eq 0) {
        Write-Host "Resource group already exists" -ForegroundColor Green
    } else {
        Write-Error "Resource group $ResourceGroupName not found and CreateRgIfMissing is false"
        exit 1
    }
} catch {
    Write-Error "Failed to handle resource group: $($_.Exception.Message)"
    exit 1
}

# 2) Storage Account
Write-Host "Checking storage account: $StorageAccountName" -ForegroundColor Cyan
try {
    $stJson = az storage account show --name $StorageAccountName --resource-group $ResourceGroupName --output json 2>$null
    if ($LASTEXITCODE -ne 0 -and $CreateStorageIfMissing) {
        Write-Host "Creating storage account: $StorageAccountName" -ForegroundColor Yellow
        az storage account create `
            --name $StorageAccountName `
            --resource-group $ResourceGroupName `
            --location $Location `
            --sku Standard_LRS `
            --kind StorageV2 `
            --https-only true `
            --output none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Storage account created successfully" -ForegroundColor Green
        } else {
            Write-Error "Failed to create storage account: $StorageAccountName"
            exit 1
        }
    } elseif ($LASTEXITCODE -eq 0) {
        Write-Host "Storage account already exists" -ForegroundColor Green
    } else {
        Write-Error "Storage account $StorageAccountName not found and CreateStorageIfMissing is false"
        exit 1
    }
} catch {
    Write-Error "Failed to handle storage account: $($_.Exception.Message)"
    exit 1
}

# 3) Container
Write-Host "Setting up storage container..." -ForegroundColor Cyan
try {
    # Get storage account key
    $keyJson = az storage account keys list --account-name $StorageAccountName --resource-group $ResourceGroupName --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to get storage account keys"
        exit 1
    }
    $keys = $keyJson | ConvertFrom-Json
    $storageKey = $keys[0].value
    
    # Check if container exists
    $containerExists = az storage container exists --name $ContainerName --account-name $StorageAccountName --account-key $storageKey --output json 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to check container existence"
        exit 1
    }
    
    if (-not $containerExists.exists) {
        Write-Host "Creating container: $ContainerName" -ForegroundColor Yellow
        az storage container create --name $ContainerName --account-name $StorageAccountName --account-key $storageKey --public-access off --output none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Container created successfully" -ForegroundColor Green
        } else {
            Write-Error "Failed to create container: $ContainerName"
            exit 1
        }
    } else {
        Write-Host "Container already exists" -ForegroundColor Green
    }
} catch {
    Write-Error "Failed to setup storage container: $($_.Exception.Message)"
    exit 1
}

# 4) SAS for container (upload permissions, no blob created)
Write-Host "Generating SAS token for container: $ContainerName" -ForegroundColor Cyan
try {
    $startTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $expiryTimeUtc = (Get-Date).ToUniversalTime().AddDays($SasDays).ToString("yyyy-MM-ddTHH:mm:ssZ")

    # Generate SAS token for container with add/create/write/list permissions
    $containerSas = az storage container generate-sas `
        --name $ContainerName `
        --account-name $StorageAccountName `
        --account-key $storageKey `
        --permissions acwl `
        --start $startTimeUtc `
        --expiry $expiryTimeUtc `
        --output tsv

    if ($LASTEXITCODE -ne 0 -or -not $containerSas) {
        Write-Error "Failed to generate container SAS token"
        exit 1
    }

    $containerSasUrl = "https://$StorageAccountName.blob.core.windows.net/$ContainerName?$containerSas"
    Write-Host "SAS token generated successfully (expires: $expiryTimeUtc)" -ForegroundColor Green
} catch {
    Write-Error "Failed to generate container SAS token: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "[OK] SAS URL for container (use this to upload new blobs):" -ForegroundColor Green
Write-Host $containerSasUrl
Write-Host ""

# Example AzCopy command to upload a local file to this container
$localFile = "C:\path\to\file.sqlbak"
$azcopyCmd = "azcopy copy `"$localFile`" `"$containerSasUrl`""
Write-Host "[INFO] Example AzCopy command (upload to container):" -ForegroundColor Cyan
Write-Host $azcopyCmd
Write-Host ""

Write-Host "=== Storage SAS URL Generator Complete ===" -ForegroundColor Green
