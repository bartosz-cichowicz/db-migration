<# =========================
  ENVIRONMENT CHECKS
========================= #>

# Azure CLI login (interactive, only if not already logged in)
$tenantId = "4181f65e-1111-440f-a4ff-531a548d36c8"
$subscriptionId = "c2fe7be1-7723-4646-84d6-9a33f7a4806c"

# Get correct temp directory for current platform
if ($IsLinux -or $IsMacOS) {
    $TempDir = $env:TMPDIR
    if (-not $TempDir) { $TempDir = "/tmp" }
} else {
    $TempDir = $env:TEMP
}

# Check if already logged in
$currentAccount = az account show 2>$null
if (-not $currentAccount) {
    Write-Host "Not logged in. Logging in to Azure CLI with tenant $tenantId..."
    
    # Clear Azure CLI state if login fails
    $azurePath = if ($IsLinux -or $IsMacOS) { "$env:HOME/.azure" } else { "$env:USERPROFILE\.azure" }
    if (Test-Path $azurePath) {
        Write-Host "Clearing Azure CLI state..."
        Get-Process -Name "az" -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2
        Remove-Item $azurePath -Recurse -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    
    az login --tenant $tenantId
} else {
    Write-Host "Already logged in to Azure CLI."
}

# Set subscription
az account set --subscription $subscriptionId

# Confirm login by listing resources in the resource group
$resourceGroup = "rg-dbimport-tst"
Write-Host "Confirming Azure login and subscription by listing resources in $resourceGroup..."
$resources = az resource list --resource-group $resourceGroup --output table
Write-Host $resources

<# =========================
  CONFIG
========================= #>
$resourceGroup = "rg-dbimport-tst"
$location = "ukwest"

# Source .BAK file in storage
$bakStorageAccountName = "stdbexportfile"
$bakContainerName = "backups"
$bakFileName = "TestBigDB.bak"

# Managed Instance for import/export
$managedInstanceName = "sql-bakimport-tst"
$tempDbName = "TestBigDB-Temp"
$miAdmin = "your-mi-admin-username"
$miPassword = "your-mi-admin-password"

# Target (Azure SQL Server)
$targetServerName = "sqlserver-target-tst"
$targetDbName = "TestBigDB-Imported"
$targetAdmin = "your-target-admin-username"
$targetPassword = "your-target-admin-password"

# Storage Account for BACPAC
$storageAccountName = "stdbexportfile"
$containerName = "bacpacs"
$bacpacFileName = "TestBigDB-export.bacpac"

# Add your database migration logic here...

<# =========================
  SQLPACKAGE CHECK & INSTALLATION
========================= #>
# Check if SqlPackage is already available in PATH
$sqlPackageExists = Get-Command sqlpackage -ErrorAction SilentlyContinue
if ($sqlPackageExists) {
    Write-Host "SqlPackage found in PATH: $($sqlPackageExists.Source)"
    $SqlPackageExe = $sqlPackageExists.Source
} else {
    Write-Host "SqlPackage not found in PATH. Checking local installation..."
    
    # Check local temp installation
    $SqlPackageDir = Join-Path $TempDir "SqlPackage"
    $SqlPackageExe = if ($IsLinux -or $IsMacOS) { 
        Join-Path $SqlPackageDir "sqlpackage" 
    } else { 
        Join-Path $SqlPackageDir "sqlpackage.exe" 
    }
    
    if (Test-Path $SqlPackageExe) {
        Write-Host "SqlPackage found in temp directory: $SqlPackageExe"
    } else {
        Write-Host "SqlPackage not found. Installing to temp directory..."
        
        # Get correct download URL for platform
        if ($IsLinux) {
            $url = "https://go.microsoft.com/fwlink/?linkid=2261798"  # Linux
        } elseif ($IsMacOS) {
            $url = "https://go.microsoft.com/fwlink/?linkid=2261799"  # macOS
        } else {
            $url = "https://go.microsoft.com/fwlink/?linkid=2261797"  # Windows
        }
        
        $zip = Join-Path $TempDir "SqlPackage.zip"
        
        try {
            # Create directory
            New-Item -ItemType Directory -Path $SqlPackageDir -Force | Out-Null
            
            # Download and extract
            Write-Host "Downloading SqlPackage..."
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $SqlPackageDir -Force
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            
            # Set execute permissions on Linux/MacOS
            if ($IsLinux -or $IsMacOS) {
                chmod +x $SqlPackageExe
            }
            
            Write-Host "SqlPackage installed successfully: $SqlPackageExe"
        } catch {
            Write-Host "Error installing SqlPackage: $_"
            exit 1
        }
    }
}

# SqlPackage environment variables
$env:SQLPACKAGEPATH = [System.IO.Path]::GetDirectoryName($SqlPackageExe)
$env:PATH = "$($env:SQLPACKAGEPATH);$($env:PATH)"

# Verify SqlPackage installation
$sqlPackageVersion = & $SqlPackageExe /version
Write-Host "SqlPackage version $sqlPackageVersion installed."

<# =========================
  STEP 1: IMPORT .BAK TO MANAGED INSTANCE
========================= #>
Write-Host "Importing .BAK file to Managed Instance..."

# Get storage account key
$storageKey = az storage account keys list --resource-group $resourceGroup --account-name $bakStorageAccountName --query "[0].value" --output tsv

# Get storage URI for .BAK file
$bakStorageUri = "https://$bakStorageAccountName.blob.core.windows.net/$bakContainerName/$bakFileName"

try {
    Write-Host "Starting BAK import to Managed Instance: $managedInstanceName"
    Write-Host "Source BAK: $bakStorageUri"
    Write-Host "Target Database: $tempDbName"
    
    # Start the restore operation
    $restoreResult = az sql midb restore `
        --resource-group $resourceGroup `
        --managed-instance $managedInstanceName `
        --name $tempDbName `
        --backup-storage-redundancy Local `
        --source-url $bakStorageUri `
        --admin-user $miAdmin `
        --admin-password $miPassword `
        --output json

    # Check restore status
    $restoreStatus = $restoreResult.provisioningState
    if ($restoreStatus -ne "Succeeded") {
        throw "BAK import failed with status: $restoreStatus"
    }
    
    Write-Host "BAK import completed successfully to Managed Instance: $managedInstanceName"
    
} catch {
    Write-Error "BAK import failed: $($_.Exception.Message)"
    exit 1
}

<# =========================
  STEP 2: EXPORT FROM MANAGED INSTANCE
========================= #>
Write-Host "Exporting database from Managed Instance using SqlPackage..."

# Local BACPAC path
$localBacpacPath = Join-Path $TempDir $bacpacFileName

# SqlPackage export arguments
$exportArgs = @(
    "/Action:Export"
    "/SourceServerName:$sourceMiName.public.c2fe7be1-7723-4646-84d6-9a33f7a4806c.database.windows.net,3342"
    "/SourceDatabaseName:$sourceDbName"
    "/SourceUser:$sourceMiAdmin"
    "/SourcePassword:$sourceMiPassword"
    "/TargetFile:$localBacpacPath"
    "/SourceEncryptConnection:True"
    "/SourceTrustServerCertificate:False"
)

Write-Host "Export command: $SqlPackageExe $($exportArgs -join ' ')"

try {
    # Execute export
    $exportProcess = Start-Process -FilePath $SqlPackageExe -ArgumentList $exportArgs -NoNewWindow -PassThru -Wait
    
    if ($exportProcess.ExitCode -ne 0) {
        throw "SqlPackage export failed with exit code: $($exportProcess.ExitCode)"
    }
    
    Write-Host "Database exported successfully to: $localBacpacPath"
    
    # Verify BACPAC file exists and has content
    if (-not (Test-Path $localBacpacPath)) {
        throw "BACPAC file was not created: $localBacpacPath"
    }
    
    $fileSize = (Get-Item $localBacpacPath).Length
    Write-Host "BACPAC file size: $([math]::Round($fileSize / 1MB, 2)) MB"
    
} catch {
    Write-Error "Export failed: $($_.Exception.Message)"
    exit 1
}

<# =========================
  STEP 3: UPLOAD BACPAC TO STORAGE
========================= #>
Write-Host "Uploading BACPAC to Azure Storage..."

try {
    # Upload BACPAC to storage account
    az storage blob upload `
        --account-name $storageAccountName `
        --account-key $storageKey `
        --container-name $containerName `
        --name $bacpacFileName `
        --file $localBacpacPath `
        --overwrite
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload BACPAC to storage"
    }
    
    Write-Host "BACPAC uploaded successfully to storage account"
    
} catch {
    Write-Error "Upload failed: $($_.Exception.Message)"
    exit 1
}

<# =========================
  STEP 4: IMPORT TO AZURE SQL SERVER
========================= #>
Write-Host "Importing BACPAC to Azure SQL Server using SqlPackage..."

# Download BACPAC from storage for import
$downloadBacpacPath = Join-Path $TempDir "download_$bacpacFileName"

try {
    # Download BACPAC from storage
    az storage blob download `
        --account-name $storageAccountName `
        --account-key $storageKey `
        --container-name $containerName `
        --name $bacpacFileName `
        --file $downloadBacpacPath
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download BACPAC from storage"
    }
    
    Write-Host "BACPAC downloaded for import"
    
    # SqlPackage import arguments
    $importArgs = @(
        "/Action:Import"
        "/TargetServerName:$targetServerName.database.windows.net"
        "/TargetDatabaseName:$targetDbName"
        "/TargetUser:$targetAdmin"
        "/TargetPassword:$targetPassword"
        "/SourceFile:$downloadBacpacPath"
        "/TargetEncryptConnection:True"
        "/TargetTrustServerCertificate:False"
    )
    
    Write-Host "Import command: $SqlPackageExe $($importArgs -join ' ')"
    
    # Execute import
    $importProcess = Start-Process -FilePath $SqlPackageExe -ArgumentList $importArgs -NoNewWindow -PassThru -Wait
    
    if ($importProcess.ExitCode -ne 0) {
        throw "SqlPackage import failed with exit code: $($importProcess.ExitCode)"
    }
    
    Write-Host "Database imported successfully to: $targetServerName/$targetDbName"
    
} catch {
    Write-Error "Import failed: $($_.Exception.Message)"
    exit 1
}

<# =========================
  CLEANUP
========================= #>
Write-Host "Cleaning up temporary files..."

# Remove local BACPAC files
if (Test-Path $localBacpacPath) {
    Remove-Item $localBacpacPath -Force
    Write-Host "Removed local export file: $localBacpacPath"
}

if (Test-Path $downloadBacpacPath) {
    Remove-Item $downloadBacpacPath -Force
    Write-Host "Removed local download file: $downloadBacpacPath"
}

# Optionally remove BACPAC from storage (uncomment if desired)
# az storage blob delete --account-name $storageAccountName --account-key $storageKey --container-name $containerName --name $bacpacFileName
# Write-Host "Removed BACPAC from storage"

Write-Host "Migration completed successfully!"
Write-Host "Source: $sourceMiName/$sourceDbName (Managed Instance)"
Write-Host "Target: $targetServerName/$targetDbName (Azure SQL Server)"
Write-Host "BACPAC stored at: https://$storageAccountName.blob.core.windows.net/$containerName/$bacpacFileName"
