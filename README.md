# Azure Database Migration Script

This PowerShell script automates the migration of SQL Server databases from .BAK files to Azure SQL Database using Azure SQL Managed Instance as an intermediate step.

## Overview

The migration process consists of 4 main steps:
1. **Import .BAK to Managed Instance** - Restore the .BAK file to Azure SQL Managed Instance using T-SQL
2. **Export to BACPAC** - Export the database from Managed Instance to a BACPAC file using SqlPackage
3. **Upload to Storage** - Upload the BACPAC file to Azure Blob Storage
4. **Import to Azure SQL Database** - Import the BACPAC file to Azure SQL Database using SqlPackage

## Prerequisites

### Required Tools
- **PowerShell 5.1+** or **PowerShell Core 7+**
- **Azure CLI** - For Azure authentication and resource management
- **SqlPackage** - Will be automatically installed if not found
- **SqlServer PowerShell Module** - Will be automatically installed if not found

### Azure Resources
- **Azure SQL Managed Instance** - With public endpoint enabled
- **Azure SQL Server** - Target for the final database
- **Azure Storage Account** - For storing .BAK and BACPAC files
- **Azure Blob Container** - For file storage

### Permissions
- **Azure Subscription Contributor** - For resource management
- **SQL Admin Access** - To both Managed Instance and SQL Server
- **Storage Account Access** - For file upload/download operations

## Configuration

### 1. Setup Configuration File

Copy `config.properties.example` to `config.properties` and update the values:

```properties
# Azure Configuration
tenantId=your-tenant-id
subscriptionId=your-subscription-id
resourceGroup=your-resource-group
location=your-azure-region

# Source .BAK file in storage
bakStorageAccountName=your-storage-account
bakContainerName=your-container-name
bakFileName=your-database.bak

# Managed Instance for import/export
managedInstanceName=your-managed-instance
tempDbName=TempDatabase
miAdmin=your-mi-admin-user
miPassword=your-mi-password

# Target (Azure SQL Server)
targetServerName=your-sql-server
targetDbName=YourTargetDatabase
targetAdmin=your-sql-admin-user
targetPassword=your-sql-password

# Storage Account for BACPAC
storageAccountName=your-storage-account
containerName=your-container-name
bacpacFileName=your-export.bacpac
```

### 2. Configuration Properties Description

| Property | Description | Example |
|----------|-------------|---------|
| `tenantId` | Azure AD Tenant ID | `12345678-1234-1234-1234-123456789012` |
| `subscriptionId` | Azure Subscription ID | `87654321-4321-4321-4321-210987654321` |
| `resourceGroup` | Resource group containing all resources | `rg-database-migration` |
| `location` | Azure region | `eastus`, `westeurope`, `ukwest` |
| `bakStorageAccountName` | Storage account containing .BAK file | `mystorageaccount` |
| `bakContainerName` | Container with .BAK file | `backups` |
| `bakFileName` | Name of the .BAK file | `MyDatabase_FULL.bak` |
| `managedInstanceName` | Azure SQL Managed Instance name | `my-managed-instance` |
| `tempDbName` | Temporary database name for import | `TempMigrationDB` |
| `miAdmin` | Managed Instance admin username | `sqladmin` |
| `miPassword` | Managed Instance admin password | `YourSecurePassword123!` |
| `targetServerName` | Target Azure SQL Server name | `my-sql-server` |
| `targetDbName` | Final database name | `MyProductionDatabase` |
| `targetAdmin` | SQL Server admin username | `sqladmin` |
| `targetPassword` | SQL Server admin password | `YourSecurePassword123!` |
| `storageAccountName` | Storage account for BACPAC | `mystorageaccount` |
| `containerName` | Container for BACPAC file | `exports` |
| `bacpacFileName` | BACPAC export filename | `MyDatabase-export.bacpac` |

## Usage

### 1. Quick Start

```powershell
# Clone or download the script
git clone https://github.com/your-repo/db-migration.git
cd db-migration

# Configure your settings
cp config.properties.example config.properties
# Edit config.properties with your values

# Run the migration
.\migration.ps1
```

### 2. Detailed Steps

1. **Prepare your environment:**
   ```powershell
   # Install Azure CLI (if not installed)
   winget install Microsoft.AzureCLI
   
   # Login to Azure
   az login
   ```

2. **Upload your .BAK file to Azure Storage:**
   ```powershell
   az storage blob upload \
     --account-name mystorageaccount \
     --container-name backups \
     --name MyDatabase_FULL.bak \
     --file "C:\path\to\your\backup.bak"
   ```

3. **Configure the script:**
   - Edit `config.properties` with your Azure resource details
   - Ensure all connection strings and credentials are correct

4. **Run the migration:**
   ```powershell
   .\migration.ps1
   ```

### 3. Command Line Options

The script currently loads all configuration from `config.properties`. Future versions may support command-line overrides.

## Security Considerations

### 1. Protect Sensitive Information
- **Never commit `config.properties` to version control**
- Use Azure Key Vault for production environments
- Consider using Managed Identity when possible

### 2. Network Security
- Ensure Managed Instance public endpoint is properly secured
- Configure firewall rules to allow only necessary IP addresses
- Use VPN or private endpoints for enhanced security

### 3. Access Control
- Use least-privilege access for service accounts
- Regularly rotate passwords and access keys
- Monitor access logs and activities

## Troubleshooting

### Common Issues

#### Connection Errors
```
ERROR: Connection to managed instance failed
```
**Solutions:**
- Verify public endpoint is enabled on Managed Instance
- Check firewall rules allow your IP address
- Validate connection string format
- Confirm credentials are correct

#### SqlPackage Installation Issues
```
ERROR: SqlPackage not found
```
**Solutions:**
- The script will automatically install SqlPackage
- Manually install: `winget install Microsoft.SqlPackage`
- Ensure .NET Framework 4.7.2+ is installed

#### .BAK File Access Issues
```
ERROR: Could not access BAK file
```
**Solutions:**
- Verify storage account credentials
- Check blob container and file names
- Ensure .BAK file is not corrupted
- Verify storage account allows public access or configure SAS tokens

#### Import/Export Timeouts
```
ERROR: Operation timed out
```
**Solutions:**
- Increase timeout values in the script
- Check database size and complexity
- Monitor Azure resource performance
- Consider breaking large databases into smaller parts

### Logging and Monitoring

The script provides detailed logging output including:
- Connection status and progress
- File sizes and transfer times
- SQL operation results
- Error details with troubleshooting hints

## Performance Considerations

### Database Size Impact
- **Small databases (< 1GB)**: ~5-15 minutes total
- **Medium databases (1-10GB)**: ~15-60 minutes total  
- **Large databases (10GB+)**: Several hours depending on size

### Optimization Tips
- Use the closest Azure region to reduce transfer times
- Ensure adequate bandwidth for large file transfers
- Monitor Azure resource performance during migration
- Consider off-peak hours for large migrations

## Examples

### Example 1: Simple Migration
```properties
# config.properties
tenantId=12345678-1234-1234-1234-123456789012
subscriptionId=87654321-4321-4321-4321-210987654321
resourceGroup=rg-migration-demo
managedInstanceName=mi-demo
targetServerName=sql-demo
bakFileName=SampleDB.bak
targetDbName=SampleDB-Migrated
```

### Example 2: Production Migration
```properties
# config.properties for production
tenantId=prod-tenant-id
subscriptionId=prod-subscription-id
resourceGroup=rg-prod-migration
managedInstanceName=mi-prod-migration
targetServerName=sql-prod-server
bakFileName=ProductionDB_20250820.bak
targetDbName=ProductionDB
# Use strong passwords and consider Key Vault integration
```

## Support and Contributions

### Getting Help
- Check the troubleshooting section above
- Review Azure documentation for SQL Managed Instance and SQL Database
- Open an issue in the repository for bugs or feature requests

### Contributing
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Changelog

### Version 1.0
- Initial release with full migration pipeline
- Automatic SqlPackage installation
- Comprehensive error handling and logging
- Configuration file support
