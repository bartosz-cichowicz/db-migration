<# =========================
  CONFIG LOADING
========================= #>

# Start overall process timer
$overallStartTime = Get-Date
Write-Host "=== Azure Database Migration Started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Green

# Function to format time elapsed
function Format-TimeElapsed {
    param([DateTime]$startTime, [DateTime]$endTime)
    $elapsed = $endTime - $startTime
    if ($elapsed.TotalHours -ge 1) {
        return "{0:hh\:mm\:ss}" -f $elapsed
    } else {
        return "{0:mm\:ss}" -f $elapsed
    }
}

# Function to log step completion with timing
function Write-StepComplete {
    param([string]$stepName, [DateTime]$stepStartTime)
    $stepEndTime = Get-Date
    $stepDuration = Format-TimeElapsed -startTime $stepStartTime -endTime $stepEndTime
    Write-Host "[OK] $stepName completed in $stepDuration" -ForegroundColor Green
    
    # Store step duration for logging
    $global:stepDurations += @{
        StepName = $stepName
        Duration = $stepDuration
        StartTime = $stepStartTime
        EndTime = $stepEndTime
    }
    
    return $stepEndTime
}

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

# Initialize step duration tracking
$global:stepDurations = @()

# Assign configuration values to variables
$tenantId = $config.tenantId
$subscriptionId = $config.subscriptionId
$resourceGroup = $config.resourceGroup
$location = $config.location

# Source .BAK file in storage
$bakStorageAccountName = $config.bakStorageAccountName
$bakContainerName = $config.bakContainerName
$bakFileName = $config.bakFileName

# Managed Instance for import/export
$managedInstanceName = $config.managedInstanceName
$tempDbName = $config.tempDbName
$miAdmin = $config.miAdmin
$miPassword = $config.miPassword

# Target (Azure SQL Server)
$targetServerName = $config.targetServerName
$targetDbName = $config.targetDbName
$targetAdmin = $config.targetAdmin
$targetPassword = $config.targetPassword

# Storage Account for BACPAC
$storageAccountName = $config.storageAccountName
$containerName = $config.containerName
$bacpacFileName = $config.bacpacFileName

<# =========================
  ENVIRONMENT CHECKS
========================= #>

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

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Host "Installing SqlServer PowerShell module..."
    Install-Module -Name SqlServer -Force -Scope CurrentUser
}
Import-Module SqlServer

<# =========================
  STEP 1: IMPORT .BAK TO MANAGED INSTANCE
========================= #>
$step1StartTime = Get-Date
Write-Host "=== STEP 1: Importing .BAK file to Managed Instance ===" -ForegroundColor Cyan

# Get storage account key
$storageKey = az storage account keys list --resource-group $resourceGroup --account-name $bakStorageAccountName --query "[0].value" --output tsv

# Get storage URI for .BAK file
$bakStorageUri = "https://$bakStorageAccountName.blob.core.windows.net/$bakContainerName/$bakFileName"

try {
    Write-Host "Starting BAK import to Managed Instance: $managedInstanceName via T-SQL RESTORE DATABASE"
    Write-Host "Source BAK: $bakStorageUri"
    Write-Host "Target Database: $tempDbName"
    # Build T-SQL RESTORE DATABASE command for Azure SQL Managed Instance
    $restoreQuery = @"
RESTORE DATABASE [$tempDbName]
FROM URL = '$bakStorageUri'
"@
    # Connect to the managed instance using its fully qualified domain name
    $miServerInstance = "sql-bakimport-tst.public.91d4a0fcc021.database.windows.net,3342"
    Write-Host "Connecting to: $miServerInstance"
    
    # Test connection with 1 minute timeout
    Write-Host "Testing connection to managed instance..."
    $connectionTest = $null
    $timeout = 60 # 1 minute
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    do {
        try {
            $connectionTest = Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query "SELECT 1" -ConnectionTimeout 10 -QueryTimeout 10 -ErrorAction Stop
            Write-Host "Connection successful!"
            break
        } catch {
            Write-Host "Connection attempt failed, retrying..."
            Start-Sleep -Seconds 5
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $timeout)
    
    $stopwatch.Stop()
    
    if (-not $connectionTest) {
        throw "Connection to $miServerInstance failed after 1 minute. Please check: 1) Public endpoint is enabled, 2) Firewall allows your IP, 3) Connection string is correct, 4) Credentials are valid"
    }
    
    # Check if database exists and drop it if it does
    $checkDbQuery = "SELECT COUNT(*) as DbCount FROM sys.databases WHERE name = '$tempDbName'"
    $dbExists = Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query $checkDbQuery -ConnectionTimeout 30 -QueryTimeout 30
    
    if ($dbExists.DbCount -gt 0) {
        Write-Host "Database '$tempDbName' already exists. Dropping it first..."
        $dropDbQuery = "DROP DATABASE [$tempDbName]"
        Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query $dropDbQuery -ConnectionTimeout 30 -QueryTimeout 30
        Write-Host "Database '$tempDbName' dropped successfully."
    }
    
    Write-Host "Starting RESTORE DATABASE operation..."
    Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query $restoreQuery -ConnectionTimeout 300 -QueryTimeout 3600
    Write-Host "BAK import completed successfully to Managed Instance: $managedInstanceName"
    Write-StepComplete -stepName "STEP 1: BAK Import to Managed Instance" -stepStartTime $step1StartTime
} catch {
    Write-Error "BAK import failed: $($_.Exception.Message)"
    exit 1
}

<# =========================
  STEP 2: EXPORT FROM MANAGED INSTANCE
========================= #>
$step2StartTime = Get-Date
Write-Host "=== STEP 2: Exporting database from Managed Instance using SqlPackage ===" -ForegroundColor Cyan

# Local BACPAC path
$localBacpacPath = Join-Path $TempDir $bacpacFileName

# SqlPackage export arguments
$exportArgs = @(
    "/Action:Export"
    "/SourceServerName:$miServerInstance"
    "/SourceDatabaseName:$tempDbName"
    "/SourceUser:$miAdmin"
    "/SourcePassword:$miPassword"
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
    Write-StepComplete -stepName "STEP 2: Export to BACPAC" -stepStartTime $step2StartTime
    
} catch {
    Write-Error "Export failed: $($_.Exception.Message)"
    exit 1
}

<# =========================
  STEP 3: UPLOAD BACPAC TO STORAGE
========================= #>
$step3StartTime = Get-Date
Write-Host "=== STEP 3: Uploading BACPAC to Azure Storage ===" -ForegroundColor Cyan

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
    Write-StepComplete -stepName "STEP 3: Upload BACPAC to Storage" -stepStartTime $step3StartTime
    
} catch {
    Write-Error "Upload failed: $($_.Exception.Message)"
    exit 1
}

<# =========================
  STEP 4: IMPORT TO AZURE SQL SERVER
========================= #>
$step4StartTime = Get-Date
Write-Host "=== STEP 4: Importing BACPAC to Azure SQL Server using SqlPackage ===" -ForegroundColor Cyan

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
    
    # Add database size and service tier parameters if specified
    if ($config.ContainsKey('targetEdition') -and $config['targetEdition']) {
        $importArgs += "/p:DatabaseEdition=$($config['targetEdition'])"
    }
    if ($config.ContainsKey('targetServiceObjective') -and $config['targetServiceObjective']) {
        $importArgs += "/p:DatabaseServiceObjective=$($config['targetServiceObjective'])"
    }
    if ($config.ContainsKey('targetMaxSize') -and $config['targetMaxSize']) {
        # SqlPackage expects size with proper unit specification
        # For 250GB, we need to specify "250GB" not the MB equivalent
        $maxSizeValue = "$($config['targetMaxSize'])"
        $importArgs += "/p:DatabaseMaximumSize=$maxSizeValue"
    }
    
    Write-Host "Import command: $SqlPackageExe $($importArgs -join ' ')"
    
    # Execute import
    $importProcess = Start-Process -FilePath $SqlPackageExe -ArgumentList $importArgs -NoNewWindow -PassThru -Wait
    
    if ($importProcess.ExitCode -ne 0) {
        throw "SqlPackage import failed with exit code: $($importProcess.ExitCode)"
    }
    
    Write-Host "Database imported successfully to: $targetServerName/$targetDbName"
    Write-StepComplete -stepName "STEP 4: Import to Azure SQL Database" -stepStartTime $step4StartTime
    
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

# Optionally remove BACPAC from storage
az storage blob delete --account-name $storageAccountName --account-key $storageKey --container-name $containerName --name $bacpacFileName
Write-Host "Removed BACPAC from storage"

# Calculate and display overall migration time
$overallEndTime = Get-Date
$totalDuration = Format-TimeElapsed -startTime $overallStartTime -endTime $overallEndTime

# Create log file with migration summary
$logFileName = "migration-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$logFilePath = Join-Path $PSScriptRoot $logFileName

$logContent = @"
========================================
    MIGRATION COMPLETED SUCCESSFULLY!
========================================

MIGRATION SUMMARY:
   - Total Duration: $totalDuration
   - Started: $(Get-Date $overallStartTime -Format 'yyyy-MM-dd HH:mm:ss')
   - Completed: $(Get-Date $overallEndTime -Format 'yyyy-MM-dd HH:mm:ss')

STEP DURATIONS:
$(($global:stepDurations | ForEach-Object { "   - $($_.StepName): $($_.Duration)" }) -join "`n")

MIGRATION DETAILS:
   - Source: .BAK file -> Azure SQL Managed Instance
   - Target: $targetServerName/$targetDbName (Azure SQL Database)
   - Temp Database: $managedInstanceName/$tempDbName
   - BACPAC Location: https://$storageAccountName.blob.core.windows.net/$containerName/$bacpacFileName
   - Log File Location: https://$bakStorageAccountName.blob.core.windows.net/$bakContainerName/$logFileName

CONFIGURATION USED:
   - Tenant ID: $tenantId
   - Subscription ID: $subscriptionId
   - Resource Group: $resourceGroup
   - BAK Storage Account: $bakStorageAccountName
   - BAK Container: $bakContainerName
   - BAK File: $bakFileName
   - Managed Instance: $managedInstanceName
   - Target SQL Server: $targetServerName

PROCESS COMPLETED AT: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@

# Write log to file
$logContent | Out-File -FilePath $logFilePath -Encoding UTF8
Write-Host "Migration log saved to: $logFilePath" -ForegroundColor Yellow

# Upload log file to Azure Storage
try {
    Write-Host "Uploading migration log to Azure Storage..." -ForegroundColor Cyan
    az storage blob upload `
        --account-name $bakStorageAccountName `
        --account-key $storageKey `
        --container-name $bakContainerName `
        --name $logFileName `
        --file $logFilePath `
        --overwrite
    
    if ($LASTEXITCODE -eq 0) {
        $logStorageUrl = "https://$bakStorageAccountName.blob.core.windows.net/$bakContainerName/$logFileName"
        Write-Host "Migration log uploaded to: $logStorageUrl" -ForegroundColor Green
    } else {
        Write-Host "Warning: Failed to upload log file to storage" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Warning: Could not upload log file to storage: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "    MIGRATION COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host ">> MIGRATION SUMMARY:" -ForegroundColor Cyan
Write-Host "   - Total Duration: $totalDuration" -ForegroundColor White
Write-Host "   - Started: $(Get-Date $overallStartTime -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "   - Completed: $(Get-Date $overallEndTime -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host ""
Write-Host ">> MIGRATION DETAILS:" -ForegroundColor Cyan
Write-Host "   - Source: .BAK file -> Azure SQL Managed Instance" -ForegroundColor White
Write-Host "   - Target: $targetServerName/$targetDbName (Azure SQL Database)" -ForegroundColor White
Write-Host "   - Temp Database: $managedInstanceName/$tempDbName" -ForegroundColor White
Write-Host "   - BACPAC Location: https://$storageAccountName.blob.core.windows.net/$containerName/$bacpacFileName" -ForegroundColor White
