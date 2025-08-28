<# ------------------------------------------------------------
  Creates container (if missing), then generates SAS URL
  for a SPECIFIC blob, with upload permissions (c+w).
  At the end prints ready AzCopy command to use on another host.
  
  All parameters are loaded from config.properties
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
$ContainerName = $config.storageSasContainerName
$BlobName = $config.storageSasBlobName
$SasDays = [int]$config.storageSasDays

Write-Host "=== Storage SAS URL Generator ===" -ForegroundColor Green
Write-Host "Configuration loaded:" -ForegroundColor Cyan
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "  Location: $Location" -ForegroundColor White
Write-Host "  Storage Account: $StorageAccountName" -ForegroundColor White
Write-Host "  Container: $ContainerName" -ForegroundColor White
Write-Host "  Blob Name: $BlobName" -ForegroundColor White
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

# 4) SAS for specific blob
Write-Host "Generating SAS token for blob: $BlobName" -ForegroundColor Cyan
try {
    $startTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $expiryTimeUtc = (Get-Date).ToUniversalTime().AddDays($SasDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    # Generate SAS token for blob with create and write permissions
    $sasToken = az storage blob generate-sas `
        --container-name $ContainerName `
        --name $BlobName `
        --account-name $StorageAccountName `
        --account-key $storageKey `
        --permissions cw `
        --start $startTimeUtc `
        --expiry $expiryTimeUtc `
        --output tsv
    
    if ($LASTEXITCODE -ne 0 -or -not $sasToken) {
        Write-Error "Failed to generate SAS token"
        exit 1
    }
    
    # Build the full URL with SAS token
    $blobSas = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$BlobName?$sasToken"
    
    Write-Host "SAS token generated successfully" -ForegroundColor Green
    Write-Host "Token expires:  $expiryTimeUtcUTC" -ForegroundColor Cyan
    
} catch {
    Write-Error "Failed to generate SAS token: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "[OK] SAS URL for blob:" -ForegroundColor Green
Write-Host $blobSas
Write-Host ""

# 5) Ready AzCopy command (upload to this blob)
$localFile = "C:\path\to\file"
$azcopyCmd = "azcopy copy `"$localFile`" `"$blobSas`""
Write-Host "[INFO] Example AzCopy command (upload):" -ForegroundColor Cyan
Write-Host $azcopyCmd
Write-Host ""

# 6) Upload README.md file and generate SAS for it
Write-Host "Uploading README.md file and generating SAS URL..." -ForegroundColor Cyan
$readmePath = Join-Path $PSScriptRoot "README.md"
if (Test-Path $readmePath) {
    try {
        # Upload README.md file using Azure CLI
        $uploadedBlobName = "uploaded-README.md"
        Write-Host "Step 1: Uploading README.md using Azure CLI..." -ForegroundColor Yellow
        
        az storage blob upload `
            --file $readmePath `
            --container-name $ContainerName `
            --name $uploadedBlobName `
            --account-name $StorageAccountName `
            --account-key $storageKey `
            --overwrite `
            --output none
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "File uploaded successfully using Azure CLI!" -ForegroundColor Green
            Write-Host "Uploaded to: https://$StorageAccountName.blob.core.windows.net/$ContainerName/$uploadedBlobName" -ForegroundColor Green
            
            # Generate SAS token for the uploaded file with read permissions
            Write-Host "Step 2: Generating SAS token for uploaded file..." -ForegroundColor Yellow
            
            # Generate SAS token with read permissions
            $readSasToken = az storage blob generate-sas `
                --container-name $ContainerName `
                --name $uploadedBlobName `
                --account-name $StorageAccountName `
                --account-key $storageKey `
                --permissions r `
                --start $startTimeUtc `
                --expiry $expiryTimeUtc `
                --output tsv
            
            if ($LASTEXITCODE -eq 0 -and $readSasToken) {
                # Get the proper blob URL using Azure CLI
                $blobUrl = az storage blob url `
                    --container-name $ContainerName `
                    --name $uploadedBlobName `
                    --account-name $StorageAccountName `
                    --account-key $storageKey `
                    --output tsv
                
                if ($LASTEXITCODE -eq 0 -and $blobUrl) {
                    $uploadedBlobSas = "$blobUrl" + "?" + "$readSasToken"
                } else {
                    # Fallback to manual URL construction
                    $uploadedBlobSas = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$uploadedBlobName?$readSasToken"
                }
            }
            
            if ($LASTEXITCODE -eq 0 -and $readSasToken -and $uploadedBlobSas) {
                Write-Host "SAS token generated successfully!" -ForegroundColor Green
                Write-Host ""
                Write-Host "[UPLOADED FILE] SAS URL for README.md:" -ForegroundColor Green
                Write-Host $uploadedBlobSas
                Write-Host ""
                
                # Test AzCopy download with the generated SAS URL
                Write-Host "Step 3: Testing AzCopy download with SAS URL..." -ForegroundColor Yellow
                $testDownloadPath = ".\test-downloaded-README.md"
                
                # Remove test file if it exists
                if (Test-Path $testDownloadPath) {
                    Remove-Item $testDownloadPath -Force
                }
                
                # Test AzCopy download
                Write-Host "Testing AzCopy download..." -ForegroundColor Gray
                & azcopy copy $uploadedBlobSas $testDownloadPath --output-type=json
                
                if ($LASTEXITCODE -eq 0 -and (Test-Path $testDownloadPath)) {
                    Write-Host "AzCopy download test successful!" -ForegroundColor Green
                    Write-Host "Downloaded file: $testDownloadPath" -ForegroundColor Green
                    
                    # Clean up test file
                    Remove-Item $testDownloadPath -Force -ErrorAction SilentlyContinue
                } else {
                    Write-Warning "AzCopy download test failed (exit code: $LASTEXITCODE)"
                }
                
                # Test AzCopy upload with SAS URL
                Write-Host "Step 4: Testing AzCopy upload with SAS URL..." -ForegroundColor Yellow
                $testUploadFile = ".\test-upload-file.txt"
                $testUploadBlobName = "azcopy-test-upload.txt"
                
                # Create a test file to upload
                "This is a test file created on $(Get-Date) for AzCopy upload testing." | Out-File -FilePath $testUploadFile -Encoding UTF8
                
                if (Test-Path $testUploadFile) {
                    # Generate SAS token for upload (create + write permissions)
                    $uploadSasToken = az storage blob generate-sas `
                        --container-name $ContainerName `
                        --name $testUploadBlobName `
                        --account-name $StorageAccountName `
                        --account-key $storageKey `
                        --permissions cw `
                        --start $startTimeUtc `
                        --expiry $expiryTimeUtc `
                        --output tsv
                    
                    if ($LASTEXITCODE -eq 0 -and $uploadSasToken) {
                        # Get the blob URL for upload
                        $uploadBlobUrl = az storage blob url `
                            --container-name $ContainerName `
                            --name $testUploadBlobName `
                            --account-name $StorageAccountName `
                            --account-key $storageKey `
                            --output tsv
                        
                        if ($LASTEXITCODE -eq 0 -and $uploadBlobUrl) {
                            $uploadBlobSas = "$uploadBlobUrl" + "?" + "$uploadSasToken"
                            
                            Write-Host "Testing AzCopy upload..." -ForegroundColor Gray
                            & azcopy copy $testUploadFile $uploadBlobSas --output-type=json
                            
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "AzCopy upload test successful!" -ForegroundColor Green
                                Write-Host "Uploaded file with SAS URL: $uploadBlobSas" -ForegroundColor Green
                                
                                # Verify the upload by checking if blob exists
                                $blobExists = az storage blob exists --name $testUploadBlobName --container-name $ContainerName --account-name $StorageAccountName --account-key $storageKey --output json | ConvertFrom-Json
                                if ($blobExists.exists) {
                                    Write-Host "Upload verification: Blob exists in storage!" -ForegroundColor Green
                                    
                                    # Generate read SAS for the uploaded test file to show download URL
                                    $testReadSasToken = az storage blob generate-sas `
                                        --container-name $ContainerName `
                                        --name $testUploadBlobName `
                                        --account-name $StorageAccountName `
                                        --account-key $storageKey `
                                        --permissions r `
                                        --start $startTimeUtc `
                                        --expiry $expiryTimeUtc `
                                        --output tsv
                                    
                                    if ($LASTEXITCODE -eq 0 -and $testReadSasToken) {
                                        $testDownloadSas = "$uploadBlobUrl" + "?" + "$testReadSasToken"
                                        Write-Host "Download URL for uploaded test file: $testDownloadSas" -ForegroundColor Cyan
                                    }
                                    
                                    # Clean up uploaded test blob
                                    az storage blob delete --name $testUploadBlobName --container-name $ContainerName --account-name $StorageAccountName --account-key $storageKey --output none
                                    Write-Host "Test blob cleaned up successfully" -ForegroundColor Gray
                                } else {
                                    Write-Warning "Upload verification failed: Blob not found in storage"
                                }
                            } else {
                                Write-Warning "AzCopy upload test failed (exit code: $LASTEXITCODE)"
                            }
                        } else {
                            Write-Warning "Failed to get blob URL for upload test"
                        }
                    } else {
                        Write-Warning "Failed to generate SAS token for upload test"
                    }
                    
                    # Clean up test file
                    Remove-Item $testUploadFile -Force -ErrorAction SilentlyContinue
                } else {
                    Write-Warning "Failed to create test file for upload"
                }
                
                Write-Host ""
                # Show AzCopy command examples
                Write-Host "[AZCOPY EXAMPLES] Commands for this uploaded file:" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Download file:" -ForegroundColor Yellow
                $downloadPath = "C:\Downloads\downloaded-README.md"
                $azcopyDownloadCmd = "azcopy copy `"$uploadedBlobSas`" `"$downloadPath`""
                Write-Host $azcopyDownloadCmd
                Write-Host ""
                
                Write-Host "Copy to another blob storage:" -ForegroundColor Yellow
                $azcopyBlobCopyCmd = "azcopy copy `"$uploadedBlobSas`" `"https://anotherstorageaccount.blob.core.windows.net/container/newfile.md?<destination-sas>`""
                Write-Host $azcopyBlobCopyCmd
                Write-Host ""
                
                Write-Host "Upload a new file (using create+write SAS):" -ForegroundColor Yellow
                Write-Host "# First generate SAS with 'cw' permissions for upload:"
                Write-Host "az storage blob generate-sas --container-name $ContainerName --name <new-blob-name> --account-name $StorageAccountName --account-key <key> --permissions cw --start <start-time> --expiry <expiry-time> --output tsv"
                Write-Host "# Then use AzCopy:"
                Write-Host "azcopy copy `"C:\path\to\local\file.txt`" `"https://$StorageAccountName.blob.core.windows.net/$ContainerName/<new-blob-name>?<upload-sas-token>`""
                Write-Host ""
                
            } else {
                Write-Warning "Failed to generate SAS token for uploaded file"
            }
            
        } else {
            Write-Warning "Failed to upload README.md file using Azure CLI"
        }
        
    } catch {
        Write-Warning "Upload process failed: $($_.Exception.Message)"
    }
} else {
    Write-Warning "README.md file not found at: $readmePath - skipping upload"
}

Write-Host ""
Write-Host "=== Storage SAS URL Generator Complete ===" -ForegroundColor Green
