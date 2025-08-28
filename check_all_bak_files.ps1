<# =========================
  ENHANCED RESTORE FILELISTONLY FOR ALL .BAK FILES WITH DIAGNOSTICS
========================= #>

# Start process timer
$startTime = Get-Date
Write-Host "=== ENHANCED RESTORE FILELISTONLY Started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Green

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

# Function to format file size
function Format-FileSize {
    param([long]$bytes)
    
    if ($bytes -ge 1TB) {
        return "{0:N2} TB" -f ($bytes / 1TB)
    } elseif ($bytes -ge 1GB) {
        return "{0:N2} GB" -f ($bytes / 1GB)
    } elseif ($bytes -ge 1MB) {
        return "{0:N2} MB" -f ($bytes / 1MB)
    } elseif ($bytes -ge 1KB) {
        return "{0:N2} KB" -f ($bytes / 1KB)
    } else {
        return "$bytes bytes"
    }
}

# Load configuration
$configPath = Join-Path $PSScriptRoot "config.properties"
$config = Load-Config -configPath $configPath

# Assign configuration values to variables
$tenantId = $config.tenantId
$subscriptionId = $config.subscriptionId
$resourceGroup = $config.resourceGroup
$bakStorageAccountName = $config.bakStorageAccountName
$bakContainerName = $config.bakContainerName
$managedInstanceName = $config.managedInstanceName
$miAdmin = $config.miAdmin
$miPassword = $config.miPassword

# Check if already logged in
$currentAccount = az account show 2>$null
if (-not $currentAccount) {
    Write-Host "Not logged in. Logging in to Azure CLI with tenant $tenantId..."
    az login --tenant $tenantId
} else {
    Write-Host "Already logged in to Azure CLI."
}

# Set subscription
az account set --subscription $subscriptionId

# Get storage account key
Write-Host "Retrieving storage account key for: $bakStorageAccountName"
$storageKey = az storage account keys list --resource-group $resourceGroup --account-name $bakStorageAccountName --query "[0].value" --output tsv

if (-not $storageKey -or $storageKey.Trim() -eq "") {
    Write-Error "Failed to retrieve storage account key for '$bakStorageAccountName'"
    exit 1
}

Write-Host "Storage account key retrieved successfully." -ForegroundColor Green

# Get detailed blob information for all .bak files
Write-Host "Getting detailed information about .bak files in container: $bakContainerName" -ForegroundColor Cyan
$blobsJson = az storage blob list --account-name $bakStorageAccountName --account-key $storageKey --container-name $bakContainerName --query "[?ends_with(name, '.bak')]" --output json

if (-not $blobsJson) {
    Write-Host "No .bak files found in container: $bakContainerName" -ForegroundColor Yellow
    exit 0
}

$blobs = $blobsJson | ConvertFrom-Json
Write-Host "Found $($blobs.Count) .bak file(s):" -ForegroundColor Green

# Display blob information
foreach ($blob in $blobs) {
    $sizeFormatted = Format-FileSize -bytes $blob.properties.contentLength
    $lastModified = [DateTime]::Parse($blob.properties.lastModified).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "  - $($blob.name)" -ForegroundColor White
    Write-Host "    Size: $sizeFormatted" -ForegroundColor Gray
    Write-Host "    Last Modified: $lastModified" -ForegroundColor Gray
    Write-Host "    Content Type: $($blob.properties.contentType)" -ForegroundColor Gray
    Write-Host "    ETag: $($blob.properties.etag)" -ForegroundColor DarkGray
}

# Try to import SqlServer module
try {
    Import-Module SqlServer -ErrorAction Stop
    Write-Host "SqlServer PowerShell module imported successfully." -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to import SqlServer PowerShell module." -ForegroundColor Red
    Write-Host "You need to install SqlServer module first with command:" -ForegroundColor Yellow
    Write-Host "Install-Module -Name SqlServer -Force" -ForegroundColor Cyan
    exit 1
}

# Managed Instance connection details
$miServerInstance = "sql-bakimport-tst.public.91d4a0fcc021.database.windows.net,3342"

# Test connection to managed instance
Write-Host "Testing connection to managed instance: $miServerInstance" -ForegroundColor Cyan
try {
    $connectionTest = Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query "SELECT GETDATE() as CurrentTime, @@VERSION as SqlVersion" -ConnectionTimeout 30 -QueryTimeout 30 -ErrorAction Stop
    Write-Host "Connection to managed instance successful!" -ForegroundColor Green
    Write-Host "Server Time: $($connectionTest.CurrentTime)" -ForegroundColor Gray
    Write-Host "SQL Version: $($connectionTest.SqlVersion.Substring(0, 100))..." -ForegroundColor Gray
} catch {
    Write-Error "Failed to connect to managed instance: $($_.Exception.Message)"
    exit 1
}

# Check if Managed Instance can access the storage account
Write-Host "Checking Managed Instance access to storage account..." -ForegroundColor Cyan
$testAccessQuery = @"
SELECT 
    CASE 
        WHEN EXISTS (
            SELECT 1 
            FROM sys.credentials 
            WHERE name = 'https://$bakStorageAccountName.blob.core.windows.net/$bakContainerName'
        ) 
        THEN 'Credential exists' 
        ELSE 'No credential found' 
    END as CredentialStatus
"@

try {
    $credentialCheck = Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query $testAccessQuery -ConnectionTimeout 30 -QueryTimeout 30
    Write-Host "Credential Status: $($credentialCheck.CredentialStatus)" -ForegroundColor $(if ($credentialCheck.CredentialStatus -eq 'Credential exists') { 'Green' } else { 'Yellow' })
} catch {
    Write-Host "Could not check credential status: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Ensure SAS-based credential exists (re-create with fresh SAS to avoid access issues)
$credentialName = "https://$bakStorageAccountName.blob.core.windows.net/$bakContainerName"
Write-Host "(Re)creating SAS-based credential: $credentialName" -ForegroundColor Cyan
$sasExpiry = (Get-Date).AddHours(24).ToString("yyyy-MM-ddTHH:mm:ssZ")
$sasToken = az storage container generate-sas --account-name $bakStorageAccountName --account-key $storageKey --name $bakContainerName --permissions rl --expiry $sasExpiry --output tsv
if (-not $sasToken) {
    Write-Host "Failed to generate SAS token for container $bakContainerName" -ForegroundColor Red
} else {
    $dropCredentialQuery = @"
IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = '$credentialName')
    DROP CREDENTIAL [$credentialName];
"@
    $createSasCredentialQuery = @"
CREATE CREDENTIAL [$credentialName]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
SECRET = '$sasToken'
"@
    try {
        Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query $dropCredentialQuery -ConnectionTimeout 30 -QueryTimeout 60
    } catch {}
    try {
        Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query $createSasCredentialQuery -ConnectionTimeout 30 -QueryTimeout 60
        Write-Host "SAS-based credential ensured." -ForegroundColor Green
    } catch {
        Write-Host "Warning: Could not create SAS credential: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Execute RESTORE FILELISTONLY for each .bak file
$results = @()
foreach ($blob in $blobs) {
    $bakFile = $blob.name
    Write-Host ""
    Write-Host "=== Processing file: $bakFile ===" -ForegroundColor Yellow
    
    # Get storage URI for .BAK file
    $bakStorageUri = "https://$bakStorageAccountName.blob.core.windows.net/$bakContainerName/$bakFile"
    Write-Host "Storage URI: $bakStorageUri" -ForegroundColor Gray
    
    # First, check header to detect multiple backup sets in a single .bak
    $backupSetInfo = @()
    $backupSetCount = 0
    $headerErrorMessage = $null
    $headerQuery = @"
RESTORE HEADERONLY
FROM URL = '$bakStorageUri'
"@
    try {
        Write-Host "Checking backup header (RESTORE HEADERONLY)..." -ForegroundColor Gray
        $headerResult = Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query $headerQuery -ConnectionTimeout 60 -QueryTimeout 300
        if ($headerResult) {
            $rows = @($headerResult)
            $backupSetCount = $rows.Count
            if ($backupSetCount -gt 1) {
                Write-Host "Multiple backup sets detected: $backupSetCount" -ForegroundColor Yellow
            } else {
                Write-Host "Single backup set detected." -ForegroundColor Green
            }
            # Collect concise details per set
            $idx = 0
            foreach ($row in $rows) {
                $idx++
                $backupSetInfo += [PSCustomObject]@{
                    Index = $idx
                    DatabaseName = $row.DatabaseName
                    BackupType   = $row.BackupType
                    Position     = $row.Position
                    StartDate    = $row.BackupStartDate
                    FinishDate   = $row.BackupFinishDate
                }
            }
            if ($backupSetCount -gt 1) {
                $backupSetInfo | Format-Table Index,DatabaseName,BackupType,Position,StartDate,FinishDate -AutoSize
            }
        } else {
            Write-Host "No header information returned." -ForegroundColor Yellow
        }
    } catch {
        $headerErrorMessage = $_.Exception.Message
        Write-Host "Header check failed: $headerErrorMessage" -ForegroundColor Yellow
    }

    # Build T-SQL RESTORE FILELISTONLY command
    $fileListQuery = @"
RESTORE FILELISTONLY
FROM URL = '$bakStorageUri'
"@
    
    $attemptStart = Get-Date
    try {
        Write-Host "Executing RESTORE FILELISTONLY for: $bakFile"
        $fileListResult = Invoke-Sqlcmd -ServerInstance $miServerInstance -Database "master" -Username $miAdmin -Password $miPassword -Query $fileListQuery -ConnectionTimeout 60 -QueryTimeout 300
        $attemptEnd = Get-Date
        $attemptDuration = ($attemptEnd - $attemptStart).TotalSeconds
        
        if ($fileListResult) {
            Write-Host "File list for ${bakFile} (took $([math]::Round($attemptDuration, 1))s):" -ForegroundColor Green
            $fileListResult | Format-Table -AutoSize
            
            # Calculate total size of files in backup
            $totalSize = ($fileListResult | Measure-Object -Property Size -Sum).Sum
            $totalSizeFormatted = Format-FileSize -bytes $totalSize
            
            Write-Host "Total size of files in backup: $totalSizeFormatted" -ForegroundColor Cyan
            
            # Store results for summary
            $results += @{
                BakFile = $bakFile
                BlobSize = $blob.properties.contentLength
                BlobSizeFormatted = Format-FileSize -bytes $blob.properties.contentLength
                FileCount = $fileListResult.Count
                TotalFileSize = $totalSize
                TotalFileSizeFormatted = $totalSizeFormatted
                Files = $fileListResult
                Status = "Success"
                Duration = $attemptDuration
                LastModified = $blob.properties.lastModified
                BackupSetCount = $backupSetCount
                BackupSets = $backupSetInfo
                HeaderError = $headerErrorMessage
            }
        } else {
            Write-Host "No file list returned for $bakFile" -ForegroundColor Yellow
            $results += @{
                BakFile = $bakFile
                BlobSize = $blob.properties.contentLength
                BlobSizeFormatted = Format-FileSize -bytes $blob.properties.contentLength
                FileCount = 0
                TotalFileSize = 0
                TotalFileSizeFormatted = "0 bytes"
                Files = @()
                Status = "No Results"
                Duration = $attemptDuration
                LastModified = $blob.properties.lastModified
                BackupSetCount = $backupSetCount
                BackupSets = $backupSetInfo
                HeaderError = $headerErrorMessage
            }
        }
    } catch {
        $attemptEnd = Get-Date
        $attemptDuration = ($attemptEnd - $attemptStart).TotalSeconds
        Write-Error "Failed to get file list for ${bakFile}: $($_.Exception.Message)"
        $results += @{
            BakFile = $bakFile
            BlobSize = $blob.properties.contentLength
            BlobSizeFormatted = Format-FileSize -bytes $blob.properties.contentLength
            FileCount = 0
            TotalFileSize = 0
            TotalFileSizeFormatted = "0 bytes"
            Files = @()
            Status = "Error"
            Duration = $attemptDuration
            ErrorMessage = $_.Exception.Message
            LastModified = $blob.properties.lastModified
            BackupSetCount = $backupSetCount
            BackupSets = $backupSetInfo
            HeaderError = $headerErrorMessage
        }
    }
}

# Generate summary report
$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "    ENHANCED RESTORE FILELISTONLY SUMMARY" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Total Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
Write-Host "Files Processed: $($results.Count)" -ForegroundColor White
Write-Host "Successful: $(($results | Where-Object { $_.Status -eq 'Success' }).Count)" -ForegroundColor Green
Write-Host "Failed: $(($results | Where-Object { $_.Status -eq 'Error' }).Count)" -ForegroundColor Red
Write-Host "No Results: $(($results | Where-Object { $_.Status -eq 'No Results' }).Count)" -ForegroundColor Yellow
Write-Host ""

# Detailed results
foreach ($result in $results) {
    Write-Host "File: $($result.BakFile)" -ForegroundColor Cyan
    Write-Host "  Status: $($result.Status)" -ForegroundColor $(if ($result.Status -eq "Success") { "Green" } elseif ($result.Status -eq "Error") { "Red" } else { "Yellow" })
    Write-Host "  Blob Size: $($result.BlobSizeFormatted)" -ForegroundColor White
    Write-Host "  Duration: $([math]::Round($result.Duration, 1))s" -ForegroundColor White
    Write-Host "  Last Modified: $([DateTime]::Parse($result.LastModified).ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
    
    if ($result.Status -eq "Success") {
        Write-Host "  Files in Backup: $($result.FileCount)" -ForegroundColor White
        Write-Host "  Total File Size: $($result.TotalFileSizeFormatted)" -ForegroundColor White
    }
    Write-Host "  Backup Sets: $($result.BackupSetCount)" -ForegroundColor White
    if ($result.BackupSetCount -gt 1) {
        Write-Host "  Multiple backup sets detected!" -ForegroundColor Yellow
        $result.BackupSets | Format-Table Index,DatabaseName,BackupType,Position,StartDate,FinishDate -AutoSize
    }
    if ($result.HeaderError) {
        Write-Host "  Header Check Error: $($result.HeaderError)" -ForegroundColor Yellow
    }
    
    if ($result.Status -eq "Error") {
        Write-Host "  Error: $($result.ErrorMessage)" -ForegroundColor Red
    }
    
    if ($result.Files -and $result.Files.Count -gt 0) {
        Write-Host "  File Details:" -ForegroundColor White
        foreach ($file in $result.Files) {
            $sizeFormatted = Format-FileSize -bytes $file.Size
            Write-Host "    - $($file.LogicalName) ($($file.Type)) - $sizeFormatted" -ForegroundColor Gray
            Write-Host "      Physical: $($file.PhysicalName)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

# Create enhanced detailed log file
$logFileName = "enhanced-filelistonly-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$logFilePath = Join-Path $PSScriptRoot $logFileName

$logContent = @"
========================================
    ENHANCED RESTORE FILELISTONLY RESULTS
========================================

SUMMARY:
   - Total Duration: $($duration.ToString('hh\:mm\:ss'))
   - Started: $(Get-Date $startTime -Format 'yyyy-MM-dd HH:mm:ss')
   - Completed: $(Get-Date $endTime -Format 'yyyy-MM-dd HH:mm:ss')
   - Files Processed: $($results.Count)
   - Successful: $(($results | Where-Object { $_.Status -eq 'Success' }).Count)
   - Failed: $(($results | Where-Object { $_.Status -eq 'Error' }).Count)
   - No Results: $(($results | Where-Object { $_.Status -eq 'No Results' }).Count)

DETAILED RESULTS:
$(($results | ForEach-Object {
    $result = $_
    $output = @"

FILE: $($result.BakFile)
STATUS: $($result.Status)
BLOB SIZE: $($result.BlobSizeFormatted)
DURATION: $([math]::Round($result.Duration, 1))s
LAST MODIFIED: $([DateTime]::Parse($result.LastModified).ToString('yyyy-MM-dd HH:mm:ss'))
"@
    
    if ($result.Status -eq "Success") {
        $output += "`nFILES IN BACKUP: $($result.FileCount)"
        $output += "`nTOTAL FILE SIZE: $($result.TotalFileSizeFormatted)"
    }
    $output += "`nBACKUP SETS: $($result.BackupSetCount)"
    if ($result.BackupSetCount -gt 1 -and $result.BackupSets) {
        $output += "`nBACKUP SET DETAILS:"
        foreach ($set in $result.BackupSets) {
            $output += "`n  - Set #$($set.Index): DB=$($set.DatabaseName), Type=$($set.BackupType), Pos=$($set.Position), Start=$($set.StartDate), Finish=$($set.FinishDate)"
        }
    }
    if ($result.HeaderError) {
        $output += "`nHEADER CHECK ERROR: $($result.HeaderError)"
    }
    
    if ($result.Status -eq "Error") {
        $output += "`nERROR: $($result.ErrorMessage)"
    }
    
    if ($result.Files -and $result.Files.Count -gt 0) {
        $output += "`nFILE DETAILS:"
        foreach ($file in $result.Files) {
            $sizeFormatted = Format-FileSize -bytes $file.Size
            $output += "`n  - $($file.LogicalName) ($($file.Type)) - $sizeFormatted"
            $output += "`n    Physical: $($file.PhysicalName)"
            $output += "`n    FileGroup: $($file.FileGroupName)"
            $output += "`n    File ID: $($file.FileId)"
        }
    }
    
    $output
}) -join "`n")

CONFIGURATION USED:
   - Storage Account: $bakStorageAccountName
   - Container: $bakContainerName
   - Managed Instance: $miServerInstance
   - Tenant ID: $tenantId
   - Subscription ID: $subscriptionId
   - Resource Group: $resourceGroup

DIAGNOSTICS:
   - Credential Status: $($credentialCheck.CredentialStatus)
   - SQL Version: $($connectionTest.SqlVersion.Substring(0, 100))...
   - Server Time: $($connectionTest.CurrentTime)

PROCESS COMPLETED AT: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@

# Write log to file
$logContent | Out-File -FilePath $logFilePath -Encoding UTF8
Write-Host "Enhanced detailed log saved to: $logFilePath" -ForegroundColor Yellow

# Success summary
$successfulFiles = $results | Where-Object { $_.Status -eq 'Success' }
if ($successfulFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "SUCCESSFULLY ANALYZED FILES:" -ForegroundColor Green
    foreach ($file in $successfulFiles) {
        Write-Host "  $($file.BakFile) - $($file.FileCount) files, $($file.TotalFileSizeFormatted)" -ForegroundColor White
    }
}

$failedFiles = $results | Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'No Results' }
if ($failedFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "FILES WITH ISSUES:" -ForegroundColor Red
    foreach ($file in $failedFiles) {
        Write-Host "  $($file.BakFile) - $($file.Status)" -ForegroundColor Yellow
        if ($file.ErrorMessage) {
            Write-Host "    Error: $($file.ErrorMessage)" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "ENHANCED RESTORE FILELISTONLY operation completed!" -ForegroundColor Green
