﻿#Requires -modules TervisPowerShellJobs,InvokeSQL,TervisPasswordstatePowershell,TervisSQLPS

function Get-HeadquartersServers {
    param(
        [Switch]$Online
    )

    $RMSHQServersOU = Get-ADOrganizationalUnit -Filter { Name -eq "RMSHQ Servers" } 
    $HeadquartersServersNames = Get-ADComputer -SearchBase $RMSHQServersOU -Filter { Name -like "*RMSHQ*" } |
    Select-Object -ExpandProperty name

    $ClusterResources = Get-ClusterGroup -Cluster hypervcluster5 | 
    Where-Object grouptype -eq "VirtualMachine" |
    Where-Object Name -In $HeadquartersServersNames

    Get-VM -ClusterObject $ClusterResources

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        [pscustomobject][ordered]@{
            BackOfficeComputerName = $Parameter;
            Online = $(Test-Connection -ComputerName $Parameter -Count 1 -Quiet);        
        }
    } -Parameters $BackOfficeComputerNames

    $Responses | 
    Where-Object Online -EQ $true |
    Select-Object -ExpandProperty BackOfficeComputerName
}

function Get-BackOfficeComputers {
    param(
        [switch]$Enabled,
        [switch]$Online
    )

    $Filter = if ($Enabled) {
        'Enabled -eq $true'
    } else {'*'}

    $BackOfficeComputerNames = Get-ADComputer -Filter:$Filter -SearchBase "OU=Back Office Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" |
        Sort-Object Name |
        Select-Object -ExpandProperty Name

    if ($Online) {
        $Responses = Start-ParallelWork -ScriptBlock {
            param($Parameter)
            [pscustomobject][ordered]@{
                BackOfficeComputerName = $Parameter;
                Online = $(Test-Connection -ComputerName $Parameter -Count 1 -Quiet);        
            }
        } -Parameters $BackOfficeComputerNames

        $Responses | 
        Where-Object Online -EQ $true |
        Select-Object -ExpandProperty BackOfficeComputerName
    } else {
        $BackOfficeComputerNames
    }
}

function Get-RegisterComputers {
    param(
        [switch]$Enabled,
        [switch]$Online
    )

    $Filter = if ($Enabled) {
        'Enabled -eq $true'
    } else {'*'}

    $RegisterComputerNames = Get-ADComputer -Filter:$Filter -SearchBase "OU=Register Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" |
        Sort-Object Name |
        Select-Object -ExpandProperty Name  

    if ($Online) {
        Start-ParallelWork -ScriptBlock {
            param($Parameter)
            [pscustomobject][ordered]@{
                RegisterComputerName = $Parameter;
                Online = $(Test-Connection -ComputerName $Parameter -Count 1 -Quiet);        
            }
        } -Parameters $RegisterComputerNames | 
        Where-Object Online -EQ $true |
        Select-Object -ExpandProperty RegisterComputerName
    } else {
        $RegisterComputerNames
    }
}

function Get-RegisterComputerObjects {
    param (
        [System.UInt16]$MaxAgeInDays = 31
    )

    Get-ADComputer -Filter {Enabled -EQ $true} -SearchBase "OU=Register Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" -Properties LastLogonDate,IPv4Address |
        Where-Object {$_.LastLogonDate -GT (Get-Date).AddDays(-1*$MaxAgeInDays)} |
        Add-Member -MemberType AliasProperty -Name ComputerName -Value Name -Force -PassThru |
        Sort-Object -Property ComputerName
}

function Get-BackOfficeComputerObjects {
    param (
        [System.UInt16]$MaxAgeInDays = 31
    )

    Get-ADComputer -Filter {Enabled -EQ $true} -SearchBase "OU=Back Office Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" -Properties LastLogonDate,IPv4Address |
        Where-Object {$_.LastLogonDate -GT (Get-Date).AddDays(-1*$MaxAgeInDays)} |
        Add-Member -MemberType AliasProperty -Name ComputerName -Value Name -Force -PassThru |
        Sort-Object -Property ComputerName
}

function Get-OmittedRegisterComputers {
    param (
        $OnlineRegisterComputers = (Get-RegisterComputers -Online -Enabled)
    )
    $AllRegisterComputers = Get-ADComputer -Filter * -SearchBase "OU=Register Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" |
        Select-Object -ExpandProperty Name
    Compare-Object $AllRegisterComputers $OnlineRegisterComputers -PassThru
}

function Get-BackOfficeComputersWhereConditionTrue {
    param(
        $BackOfficeComputerNames,
        $ConditionScriptBlock
    )

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        $ConditionResult = & $ConditionScriptBlock -Parameter $Parameter

        [pscustomobject][ordered]@{
            BackOfficeComputerName = $Parameter;
            ConditionResult = $ConditionResult;        
        }        
    } -Parameters $BackOfficeComputerNames
    
    $Responses | 
    Where-Object ConditionResult -EQ $true | 
    Select-Object -ExpandProperty BackOfficeComputerName
}

function Get-BackOfficeComputersRunningSQL {
    $BackOfficeComputerNames = Get-BackOfficeComputers -Online
    
    #Get-BackOfficeComputersWhereConditionTrue -BackOfficeComputerNames $BackOfficeComputerNames -ConditionScriptBlock {
    #    param($Parameter)
    #    Test-NetConnection -ComputerName $Parameter -Port 1433 -InformationLevel Quiet
    #}

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        [pscustomobject][ordered]@{
            BackOfficeComputerName = $Parameter;
            RunningSQL = $(Test-NetConnection -ComputerName $Parameter -Port 1433 -InformationLevel Quiet);        
        }        
    } -Parameters $BackOfficeComputerNames
    
    $Responses | 
    Where-Object RunningSQL -EQ $true | 
    Select-Object -ExpandProperty BackOfficeComputerName
}

function Get-RMSBackOfficeDatabaseName {
    param(
        $BackOfficeComputerName
    )

    $Query = @"
    with fs
    as
    (
        select database_id, type, size * 8.0 / 1024 size
        from sys.master_files
    )
    select 
        name,
        (select sum(size) from fs where type = 0 and fs.database_id = db.database_id) DataFileSizeMB,
        (select sum(size) from fs where type = 1 and fs.database_id = db.database_id) LogFileSizeMB,
	    (select sum(size) from fs where type = 0 and fs.database_id = db.database_id) + (select sum(size) from fs where type = 1 and fs.database_id = db.database_id) TotalSizeMB
    from sys.databases db
    order by TotalSizeMB desc
"@
    $Results = Invoke-RMSSQL -DataBaseName "master" -SQLServerName $BackOfficeComputerName -Query $Query

    $RMSDatabaseName = $Results | 
    Sort-Object TotalSizeMB -Descending | 
    Select-Object -First 1 -ExpandProperty Name

    [pscustomobject][ordered]@{
        BackOfficeComputerName = $BackOfficeComputerName
        RMSDatabaseName = $RMSDatabaseName
    }
}

function New-RMSSQLDatabaseCredentials {
    param (
        [pscredential]$Credential = $(Get-credential -Message "Enter RMS back office SQL server databse user credentials" ) 
    )

    $Credential | Export-Clixml -Path "$env:USERPROFILE\RMSSQLCredential.txt"
}

function Invoke-RMSSQL {
    param(
        $DataBaseName,
        $SQLServerName,
        $Query
    )
    $Credential = Get-PasswordstatePassword -AsCredential -ID 56
    Invoke-MSSQL -Server $SQLServerName -Database $DataBaseName -SQLCommand $Query -Credential $Credential -ConvertFromDataRow
}

function Get-RMSBatchNumber {
    param(
        $LastDBTimeStamp,
        $DataBaseName,
        $SQLServerName
    )
    $Query = "select BatchNumber from [batch] where dbtimestamp > $LastDBTimeStamp AND Status = 7"

    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query | 
    Select-Object -ExpandProperty BatchNumber
}

function Get-RMSBatch {
    param(
        $BatchNumber,
        $DataBaseName,
        $SQLServerName
    )
    $BatchNumberAsCommanSepratedList = $BatchNumber -join ","

    $Query = "select * from [batch] where BatchNumber in ($BatchNumberAsCommanSepratedList)"

    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
}

function Get-RMSSalesBatch {
    $BackOfficeServerAndDatabaseNames = Get-BackOfficeDatabaseNames
    #$BackOfficeServerAndDatabaseNames = Get-ComputerDatabaseNames -OUPath "OU=Back Office Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv"

    #$Responses = Start-ParallelWork -ScriptBlock {
    #    param($Parameter)
    #    Get-RMSBatch -DataBaseName $Parameter.RMSDatabasename -SQLServerName $Parameter.backofficecomputername
    #} -Parameters $BackOfficeServerAndDatabaseName
    #
    #$Responses | 
    #Where-Object ConditionResult -EQ $true | 
    #Select-Object -ExpandProperty BackOfficeComputerName

    foreach ($BackOfficeServerAndDatabaseName in $BackOfficeServerAndDatabaseNames) {
        Get-RMSBatch -DataBaseName $BackOfficeServerAndDatabaseName.RMSDatabasename -SQLServerName $BackOfficeServerAndDatabaseName.backofficecomputername -LastDBTimeStamp
        #Get-RMSBatch -DataBaseName $BackOfficeServerAndDatabaseName.RMSDatabasename -SQLServerName $BackOfficeServerAndDatabaseName.ComputerName -LastDBTimeStamp
    }

    $BatchNumbers = Get-RMSBatchNumber -LastDBTimeStamp "0x000000000639A82E" -SQLServerName "3023MYBO1-PC" -DataBaseName "MontereyStore"
    $Batches = Get-RMSBatch -BatchNumber $BatchNumbers -DataBaseName "MontereyStore" -SQLServerName "3023MYBO1-PC"
    $Transactions = Get-RMSTransaction -BatchNumber $BatchNumbers -DataBaseName "MontereyStore" -SQLServerName "3023MYBO1-PC"


     $XXOE_HEADERS_IFACE_ALL = @{
        ORDER_SOURCE_ID = 1022
        ORIG_SYS_DOCUMENT_REF = "111-111" #//sales batch + "-" + storecode
        ORG_ID = 82
        ORDERED_DATE = Get-Date
        ORDER_TYPE = "Store Order"
        SOLD_TO_ORG_ID = 1 # Store code? 22060
        SHIP_FROM_ORG = "STO"
        CUSTOMER_NUMBER = "1131597"# // Not sure
        BOOKED_FLAG = "Y"
        ATTRIBUTE6 = "Y"# // No idea
        CREATED_BY = -1 # // Not sure
        CREATION_DATE = Get-Date
        LAST_UPDATED_BY = -1
        LAST_UPDATE_DATE = Get-Date
        #//REQUEST_ID = 1# // Not sure how to generate
        OPERATION_CODE = "INSERT"
        PROCESS_FLAG = "N"
        SOURCE_NAME = "RMS"
        OPERATING_UNIT_NAME = "Tervis Operating Unit"
        CREATED_BY_NAME = "BIZTALK"
        LAST_UPDATED_BY_NAME = "BIZTALK"
    }

}

function Get-RMSTransaction {
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True, ValueFromPipelineByPropertyName = $True)]$BatchNumber,
        [Parameter(Mandatory = $True)]$DataBaseName,
        [Parameter(Mandatory = $True)]$SQLServerName
    )
    process {
        $BatchNumberAsCommanSepratedList = $BatchNumber -join ","

        $Query = "select * from [Transaction] where BatchNumber in ($BatchNumberAsCommanSepratedList)"

        Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
    }
}

function Get-RMSTransactionEntry {
    param(
        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]$TransactionNumber,
        [Parameter(Mandatory = $True)]$DataBaseName,
        [Parameter(Mandatory = $True)]$SQLServerName
    )
    process {
        $TransactionNumberAsCommanSepratedList = $TransactionNumber -join ","

        $Query = "select * from [TransactionEntry] where TransactionNumber in ($TransactionNumberAsCommanSepratedList)"

        Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
    }
}

function Get-BackOfficeDatabaseNames {
    $BackOfficeComputerNames = Get-BackOfficeComputersRunningSQL

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        Get-RMSBackOfficeDatabaseName -BackOfficeComputerName $Parameter
    } -Parameters $BackOfficeComputerNames
    
    $Responses | 
    Select-Object backofficecomputername, RMSDatabasename
}

function Get-ComputersInOU {
    param(
        [Switch]$Online,
        [Parameter(Mandatory)]$OUPath
    )

    $ComputerNames = Get-ADComputer -Filter * -SearchBase $OUPath |
        Select-Object -ExpandProperty name

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        [pscustomobject][ordered]@{
            ComputerName = $Parameter;
            Online = $(Test-Connection -ComputerName $Parameter -Count 1 -Quiet);        
        }
    } -Parameters $ComputerNames

    $Responses | 
        Where-Object Online -EQ $true |
        Select-Object -ExpandProperty ComputerName
}

function Get-ComputersWhereConditionTrue {
    param(
        $ComputerNames,
        $ConditionScriptBlock
    )

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        $ConditionResult = & $ConditionScriptBlock -Parameter $Parameter

        [pscustomobject][ordered]@{
            ComputerName = $Parameter;
            ConditionResult = $ConditionResult;        
        }        
    } -Parameters $ComputerNames
    
    $Responses | 
        Where-Object ConditionResult -EQ $true | 
        Select-Object -ExpandProperty ComputerName
}

function Get-ComputersRunningSQL {
    param (
        [Parameter(Mandatory)]$OUPath
    )
    
    $ComputerNames = Get-ComputersInOU -Online -OUPath $OUPath

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        [pscustomobject][ordered]@{
            ComputerName = $Parameter;
            RunningSQL = $(Test-NetConnection -ComputerName $Parameter -Port 1433 -InformationLevel Quiet);        
        }        
    } -Parameters $ComputerNames
    
    $Responses | 
        Where-Object RunningSQL -EQ $true | 
        Select-Object -ExpandProperty ComputerName
}

function Get-RMSDatabaseName {
    param(
       [Parameter(Mandatory)]$ComputerName
    )

    $Query = @"
    with fs
    as
    (
        select database_id, type, size * 8.0 / 1024 size
        from sys.master_files
    )
    select 
        name,
        (select sum(size) from fs where type = 0 and fs.database_id = db.database_id) DataFileSizeMB,
        (select sum(size) from fs where type = 1 and fs.database_id = db.database_id) LogFileSizeMB,
	    (select sum(size) from fs where type = 0 and fs.database_id = db.database_id) + (select sum(size) from fs where type = 1 and fs.database_id = db.database_id) TotalSizeMB
    from sys.databases db
    order by TotalSizeMB desc
"@
    $Results = Invoke-RMSSQL -DataBaseName "master" -SQLServerName $ComputerName -Query $Query

    $RMSDatabaseName = $Results | 
        Sort-Object TotalSizeMB -Descending | 
        Select-Object -First 1 -ExpandProperty Name

    [pscustomobject][ordered]@{
        ComputerName = $ComputerName
        RMSDatabaseName = $RMSDatabaseName
    }
}

function Get-ComputerDatabaseNames {
    param(
       [Parameter(Mandatory)]$OUPath
    )

    $ComputerNames = Get-ComputersRunningSQL -OUPath $OUPath

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        Get-RMSDatabaseName -ComputerName $Parameter
    } -Parameters $ComputerNames
    
    $Responses | 
        Select-Object ComputerName, RMSDatabasename
}

function Stop-SOPOSUSERProcess {
    $RegisterComputers = Get-RegisterComputers -Online

    foreach ($RegisterComputer in $RegisterComputers) {
        $RegisterComputer
        (Get-WmiObject Win32_Process -ComputerName $RegisterComputer | Where-Object { $_.ProcessName -match "soposuser" }).Terminate()
    }

}

function Stop-SOPOSUSERProcessParallel {
    param (
        $RegisterComputers = (Get-RegisterComputers -Online)
    )

    Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        $Credential = Get-PasswordstatePassword -AsCredential -ID 417
        Invoke-Command -ComputerName $Parameter -Credential $Credential -ScriptBlock {
            Get-Process -Name SOPOSUSER | Stop-Process -Force
        }
    } -Parameters $RegisterComputers
}

function Get-PersonalizeItConfigFileInfo {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$ComputerName
    )
    begin {
        $LocalXMLPath = "C:\Program Files\nChannel\Personalize\PersonalizeItConfig.xml"
    }
    process {
        $RemoteXMLPath = $LocalXMLPath | ConvertTo-RemotePath -ComputerName $ComputerName
        $FileInfo = Get-ChildItem $RemoteXMLPath
        [PSCustomObject][Ordered]@{
            ComputerName = $ComputerName
            LastWriteTime = $FileInfo.LastWriteTime
        }
    }
}

function Get-PersonalizeItDllFileInfo {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$ComputerName
    )
    begin {
        $LocalXMLPath = "C:\Program Files\nChannel\Personalize\Personalize.dll"
    }
    process {
        $RemoteXMLPath = $LocalXMLPath | ConvertTo-RemotePath -ComputerName $ComputerName
        $FileInfo = Get-ChildItem $RemoteXMLPath
        [PSCustomObject][Ordered]@{
            ComputerName = $ComputerName
            LastWriteTime = $FileInfo.LastWriteTime
            Version = $FileInfo.VersionInfo.FileVersion
        }
    }
}

function Get-PersonalizeItDllFileInfoParallel {
    param (
        $RegisterComputers = (Get-RegisterComputers -Online)
    )

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        
        $PersonalizeDLLFileInfo = Invoke-Command -ComputerName $Parameter { 
            $FileInfo = Get-ChildItem "C:\Program Files\nChannel\Personalize\Personalize.dll"
            Add-Member -InputObject $FileInfo -MemberType NoteProperty -Name "Version" -Value $FileInfo.VersionInfo.FileVersion
            $FileInfo
        } -ErrorAction SilentlyContinue
        Add-Member -InputObject $PersonalizeDLLFileInfo -MemberType NoteProperty -Name "ComputerName" -Value $Parameter
        $PersonalizeDLLFileInfo
    } -Parameters $RegisterComputers

    $Responses | Select-Object ComputerName,Name,Version,LastWriteTime
}

function Get-PersonalizeItConfigFileInfoParallel {
    param (
        $RegisterComputers = (Get-RegisterComputers -Online)
    )

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        
        $PersonalizeItConfigFileInfo = Invoke-Command -ComputerName $Parameter { 
            Get-ChildItem "C:\Program Files\nChannel\Personalize\PersonalizeItConfig.xml"
        } -ErrorAction SilentlyContinue
        Add-Member -InputObject $PersonalizeItConfigFileInfo -MemberType NoteProperty -Name "ComputerName" -Value $Parameter
        $PersonalizeItConfigFileInfo
    } -Parameters $RegisterComputers

    $Responses | Select-Object ComputerName,Name,LastWriteTime
}

function Invoke-TervisRegisterComputerGPUpdate {
    $RegisterComputers = Get-RegisterComputers -Online

    foreach ($RegisterComputer in $RegisterComputers) {
        Invoke-GPUpdate -Computer $RegisterComputer -RandomDelayInMinutes 0 -Force
    }
}

function Invoke-TervisRegisterComputerGPUpdateParallel {
    param (
        $RegisterComputers = (Get-RegisterComputerObjects | Select-Object -ExpandProperty ComputerName)
    )

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        $Parameter
        Invoke-GPUpdate -Computer $Parameter -RandomDelayInMinutes 0
    } -Parameters $RegisterComputers

    $Responses
}

function Invoke-TervisRegisterComputerRestart {
    param (
        $RegisterComputers = (Get-RegisterComputerObjects | Select-Object -ExpandProperty ComputerName)
    ) 

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        Restart-Computer -ComputerName $Parameter -Force -Verbose 
    } -Parameters $RegisterComputers

    $Responses
}

function Invoke-TervisRegisterClosePOSParallel {
    param (
        $RegisterComputers = (Get-RegisterComputerObjects | Select-Object -ExpandProperty ComputerName)
    ) 

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        Invoke-Command -ComputerName $Parameter -ScriptBlock {Get-Process SOPOSUSER | Stop-Process -Force}
    } -Parameters $RegisterComputers

    $Responses
}

function Invoke-ConvertOfflineDBToSimpleRecoverModel {
    [CmdletBinding()]
    param (
        $RegisterComputers
    )

    #Write-Verbose -Message "Getting online registers"
    #$OnlineRegisters = Get-RegisterComputers -Online

    Start-ParallelWork -Parameters $RegisterComputers -ScriptBlock {
        param(
            $Parameter
        )
        $RegisterComputer = $Parameter
        if (!(Get-SQLRemoteAccessEnabled -ComputerName $RegisterComputer)) {
            Enable-SQLRemoteAccess -ComputerName $RegisterComputer
        }    
        $FreeSpaceBefore = Invoke-Command -ComputerName $RegisterComputer -ScriptBlock {
            Get-PSDrive -Name C | Select-Object -ExpandProperty Free
        }
        $OfflineDBTransactionLog = Get-OfflineDBTransactionLogName -ComputerName $RegisterComputer
        $SQLResponse = Invoke-RMSSQL -DataBaseName OfflineDB -SQLServerName $RegisterComputer -Query @"
USE [master]
ALTER DATABASE [OfflineDB] SET RECOVERY SIMPLE WITH NO_WAIT
BACKUP DATABASE [OfflineDB] TO DISK = N'NUL' WITH NOFORMAT, NOINIT, NAME = N'OfflineDB-Full Database Backup', SKIP, NOREWIND, NOUNLOAD, STATS = 10
USE [OfflineDB]
DBCC SHRINKFILE (N'$OfflineDBTransactionLog' , 0, TRUNCATEONLY)
"@
        $FreeSpaceAfter = Invoke-Command -ComputerName $RegisterComputer -ScriptBlock {
            Get-PSDrive -Name C | Select-Object -ExpandProperty Free
        } 
        $SpaceReclaimed = $FreeSpaceAfter - $FreeSpaceBefore
        [pscustomobject][ordered]@{
            Name = $RegisterComputer
            TransactionLogName = $OfflineDBTransactionLog
            DatabaseSize = $SQLResponse.CurrentSize
            GigabytesReclaimed = [math]::Round(($SpaceReclaimed/1GB),2)
        }
    }
}

function Get-SQLRemoteAccessEnabled {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]$ComputerName
    )
    Write-Verbose "Getting current SQL remote access policy"
    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        $SQLTCPKeyPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL10_50.MSSQLSERVER\MSSQLServer\SuperSocketNetLib\Tcp"
        $SQLTCPKey = Get-ItemProperty -Path $SQLTCPKeyPath
        $SQLTCPKey.Enabled
    }
}

function Get-OfflineDBTransactionLogName {
    [CmdletBinding()]
    param (
        [pscredential]$Credential = (Get-PasswordstatePassword -AsCredential -ID 56),
        [Parameter(Mandatory=$true)]$ComputerName
    )

    Write-Verbose "Getting OfflineDB transaction log name"
    $TransactionLogFileNameSQLQuery = @"
SELECT name
FROM sys.master_files
WHERE name LIKE '%\_Log' ESCAPE '\';
"@

    Invoke-RMSSQL -SQLServerName $ComputerName -DataBaseName OfflineDB -Query $TransactionLogFileNameSQLQuery |
        Select-Object -ExpandProperty Name
}

function Get-OfflineDBRecoveryModel {
    param (
        #[Parameter(Mandatory=$true)]$ComputerName
    )
    $Registers = Get-RegisterComputers -Online

    Start-ParallelWork -Parameters $Registers -ScriptBlock {
        param($parameter)
        $SQLResponse = Invoke-RMSSQL -DataBaseName offlinedb -SQLServerName $parameter -Query @"
SELECT name, recovery_model_desc  
   FROM sys.databases  
      WHERE name = 'OfflineDB'
"@ 
        Add-Member -InputObject $SQLResponse -MemberType NoteProperty -Name ComputerName -Value $parameter
        $SQLResponse
    } | Select-Object ComputerName,name,recovery_model_desc
}

function Get-TervisRMSShift4UTGVersion {
    [cmdletbinding()]
    param()

    Write-Verbose "Getting register computers"
    $Registers = Get-RegisterComputers -Online
    Write-Verbose "Getting version numbers for Shift4 UTG"
    Start-ParallelWork -Parameters $Registers -ScriptBlock {
        param($parameter)
        $UTGProductInformation = Invoke-Command -ComputerName $parameter -ScriptBlock {
             Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* | 
                Where-Object {$_.DisplayName -match "Shift4 Universal Transaction Gateway"} |
                Select-Object -Property DisplayName,DisplayVersion,InstallDate
        }
        if (!$UTGProductInformation) {
            Write-Warning "Could not get UTG install information from $parameter"
        } else {
            Add-Member -InputObject $UTGProductInformation -MemberType NoteProperty -Name ComputerName -Value $parameter
        }
        $UTGProductInformation 
    } | Select-Object ComputerName,DisplayName,DisplayVersion,InstallDate
}

function Get-TervisRMSShift4RMSPluginVersion {
    [cmdletbinding()]
    param(
        $Registers = (Get-RegisterComputers)
    )
    Write-Verbose "Getting version numbers for Shift4 RMS"
    <#
    Start-ParallelWork -Parameters $Registers -ScriptBlock {
        param($parameter)
        $S4RMSProductInformation = Invoke-Command -ComputerName $parameter -ScriptBlock {
             Get-ChildItem -Path "C:\Program Files\Shift4\S4RMS\s4rms.dll"
        }
        if ($S4RMSProductInformation) {
            [PSCustomObject][Ordered]@{
                ComputerName = $parameter
                DisplayName = "S4RMS"
                DisplayVersion = $S4RMSProductInformation.VersionInfo.FileVersion
            }
        } else {
            Write-Warning "Could not get S4RMS install information from $parameter"
            #Add-Member -InputObject $UTGProductInformation -MemberType NoteProperty -Name ComputerName -Value $parameter
        }
    } | Select-Object ComputerName,DisplayName,DisplayVersion
    #>
    $S4RmsLocalPath = "C:\Program Files\Shift4\S4RMS\s4rmsconfig.exe"
    foreach ($Register in $Registers) {
        try {
            $S4RmsRemotePath = $S4RmsLocalPath | ConvertTo-RemotePath -ComputerName $Register
            $S4RmsFileInfo = Get-ChildItem -Path $S4RmsRemotePath -ErrorAction Stop
            [PSCustomObject][Ordered]@{
                ComputerName = $Register
                DisplayName = "S4RMS"
                Version = $S4RmsFileInfo.VersionInfo.FileVersion
            }
        } catch {
            Write-Warning "Could not reach $Register"
        }
    }
}

function Enable-SQLRemoteAccessForAllRegisterComputers {    
    Write-Verbose -Message "Getting online registers"
    $OnlineRegisters = Get-RegisterComputers -Online

    Start-ParallelWork -Parameters $OnlineRegisters -ScriptBlock {
        param(
            $Parameter
        )
        $RegisterComputer = $Parameter
        if (!(Get-SQLRemoteAccessEnabled -ComputerName $RegisterComputer)) {
            Enable-SQLRemoteAccess -ComputerName $RegisterComputer
            $RegisterComputer
        }    
    }
}

function Invoke-DeployPersonalizeDLLToAllEpsilonRegisters {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]$PathToPersonalizeDLLtoDeploy
    )

    if (!(Test-Path $PathToPersonalizeDLLtoDeploy)) {
        throw "Personalize.dll not found on local system"
    }

    $EPSRMSComputers = Get-ADComputer -Filter {Name -like "EPS-RMSPOS*"}
    $CurrentDate = Get-Date -Format yyyyMMdd.HHmmss

    foreach ($POS in $EPSRMSComputers) {
        Write-Verbose "$($POS.Name)"
        
        $RemotePersonalizeDLL = "\\$($POS.Name)\c$\Program Files\nChannel\Personalize\Personalize.dll"

        if (Test-Connection -ComputerName $POS.Name -Count 1 -Quiet) {
            $HashesMatch = try {
                (Get-FileHash $RemotePersonalizeDLL -ErrorAction Stop).Hash -eq (Get-FileHash -Path $PathToPersonalizeDLLtoDeploy).Hash
            } catch {$false}
                               
            if (!$HashesMatch) {
                Write-Verbose "Copying Personalize.dll to $($POS.Name)"
                Rename-Item -Path $RemotePersonalizeDLL -NewName "Personalize.$CurrentDate.dll"            
                Copy-Item -Path $PathToPersonalizeDLLtoDeploy -Destination $RemotePersonalizeDLL -Force
            } else {
                Write-Warning "Files are identical. Files were not copied."
            }
        } else {
            Write-Warning "Could not connect"
        }
    }

    Write-Verbose "Restarting Epsilon registers"
    Start-ParallelWork -Parameters $EPSRMSComputers -ScriptBlock {
        param ($Parameter)
        try {
            Restart-Computer -ComputerName $Parameter.Name -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not restart $($Parameter.Name)"
        }
    }
}

function Invoke-DeployPersonalizeItConfigXMLToAllEpsilonRegisters {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]$PathToPersonalizeItConfigXMLtoDeploy
    )

    if (!(Test-Path $PathToPersonalizeItConfigXMLtoDeploy)) {
        throw "PersonalizeItConfig.xml not found on local system"
    }

    $EPSRMSComputers = Get-ADComputer -Filter {Name -like "EPS-RMSPOS*"}
    $CurrentDate = Get-Date -Format yyyyMMdd.HHmmss

    foreach ($POS in $EPSRMSComputers) {
        Write-Verbose "$($POS.Name)"
        
        $RemotePersonalizeItConfigXML = "\\$($POS.Name)\c$\Program Files\nChannel\Personalize\PersonalizeItConfig.xml"

        if (Test-Connection -ComputerName $POS.Name -Count 1 -Quiet) {
            $HashesMatch = try {
                (Get-FileHash $RemotePersonalizeItConfigXML -ErrorAction Stop).Hash -eq (Get-FileHash -Path $PathToPersonalizeItConfigXMLtoDeploy).Hash
            } catch {$false}
                               
            if (!$HashesMatch) {
                Write-Verbose "Copying PersonalizeItConfig.xml to $($POS.Name)"
                Rename-Item -Path $RemotePersonalizeItConfigXML -NewName "Personalize.$CurrentDate.dll"            
                Copy-Item -Path $PathToPersonalizeItConfigXMLtoDeploy -Destination $RemotePersonalizeItConfigXML -Force
            } else {
                Write-Warning "Files are identical. Files were not copied."
            }
        } else {
            Write-Warning "Could not connect"
        }
    }

    Write-Verbose "Restarting Epsilon registers"
    Start-ParallelWork -Parameters $EPSRMSComputers -ScriptBlock {
        param ($Parameter)
        try {
            Restart-Computer -ComputerName $Parameter.Name -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not restart $($Parameter.Name)"
        }
    }
}

function Set-RMSClientNetworkConfiguration {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName,
        [ValidateSet("BackOffice","POS1","POS2")][string]$RMSClientRole,
        [ValidateRange(0,255)][int]$StoreNetworkIdentifier,
        [Switch]$UseWMI
    )
    Begin {
        $ADDomain = Get-ADDomain
        $ADDNSRoot = $ADDomain | Select-Object -ExpandProperty DNSRoot
    }
    Process {
        if ($RMSClientRole -eq "BackOffice") {
            $StaticIPAddress = '10.64.' + $StoreNetworkIdentifier + '.5'
        } elseif ($RMSClientRole -eq "POS1") {
            $StaticIPAddress = '10.64.' + $StoreNetworkIdentifier + '.11'
        } elseif ($RMSClientRole -eq "POS2") {
            $StaticIPAddress = '10.64.' + $StoreNetworkIdentifier + '.12'
        }
        $DefaultGateway = '10.64.' + $StoreNetworkIdentifier + '.1'
        $DNSServerIPAddresses = @()
        $DNSServerIPAddresses += Get-DhcpServerv4OptionValue -ComputerName $(Get-DhcpServerInDC | `
            Select-Object -First 1 -ExpandProperty DNSName) | `
            Where-Object OptionID -eq 6 | `
            Select-Object -ExpandProperty Value
        $DNSServerIPAddresses += '208.67.220.220','8.8.4.4'
        if ($UseWMI) {
            $IPConfiguration = Get-WmiObject win32_networkadapterconfiguration -ComputerName $ComputerName | Where-Object IPEnabled
            $InterfaceIndex = $IPConfiguration | Select-Object -ExpandProperty InterfaceIndex
            $SubnetMask = ($IPConfiguration).IPSubnet[0]
            $IPConfiguration.SetDNSDomain($ADDNSRoot)
            $IPConfiguration.SetDynamicDNSRegistration($true)
            $IPConfiguration.SetDNSServerSearchOrder($DNSServerIPAddresses)
            Invoke-Command -ComputerName $ComputerName -AsJob -ScriptBlock {netsh interface ip set address $Using:InterfaceIndex static $Using:StaticIPAddress $Using:SubnetMask $Using:DefaultGateway 1}
        } else {
            $CimSession = New-CimSession -ComputerName $ComputerName
            $CurrentNicConfiguration = Get-NetIPConfiguration `
                -InterfaceAlias $(Get-NetAdapter -CimSession $CimSession).Name `
                -CimSession $CimSession
            $InterfaceName = $CurrentNicConfiguration | Select-Object -ExpandProperty InterfaceAlias
            Set-DnsClientServerAddress `
                -InterfaceAlias ($CurrentNicConfiguration).InterfaceAlias `
                -ServerAddresses $DNSServerIPAddresses `
                -CimSession $CimSession
            $IPConfiguration = Get-WmiObject win32_networkadapterconfiguration -ComputerName $ComputerName | Where-Object Description -eq ($CurrentNicConfiguration).InterfaceDescription
            $SubnetMask = ($IPConfiguration).IPSubnet[0]
            $IPConfiguration.SetDNSDomain($ADDNSRoot)
            $IPConfiguration.SetDynamicDNSRegistration($true)
            Invoke-Command -ComputerName $ComputerName -AsJob -ScriptBlock {netsh interface ip set address $Using:InterfaceName static $Using:StaticIPAddress $Using:SubnetMask $Using:DefaultGateway 1}
        }
    }
    End {
        if (-NOT ($UseWMI)) {
            Remove-CimSession $CimSession
        }
    }
}

function Invoke-PushFileToAllBackOfficeComputers {
    param (
        [Parameter(Mandatory)]$SourceFile,
        [Parameter(Mandatory)]$DestinationFile,
        $BackOfficeComputers = (Get-BackOfficeComputers -Online),
        [Switch]$Force
    )
    $TotalComputers = $BackOfficeComputers | Measure-Object | Select-Object -ExpandProperty Count
    $i = 0
    foreach ($Computer in $BackOfficeComputers) {
        Write-Progress -Activity "Pushing file to Back Office computers" -PercentComplete ($i * 100 / $TotalComputers) -CurrentOperation $Computer
        $RemoteDestinationFile = $DestinationFile | ConvertTo-RemotePath -ComputerName $Computer
        try {
            if ($Force) {
                Copy-Item -Path $SourceFile -Destination $RemoteDestinationFile -Force -ErrorAction Stop
                $Result = $true
            } else {
                Copy-Item -Path $SourceFile -Destination $RemoteDestinationFile -ErrorAction Stop
                $Result = $true
            }
        } catch {$Result = $false}
        [PSCustomObject][Ordered]@{
            ComputerName = $Computer
            Status = $Result
        }
        $i++       
    }
    Write-Progress -Activity "Pushing file to Back Office computers" -Completed
}

function Get-NetshCommandsToSetDNSOnStoreEndpoint {
    @"
netsh interface ip set dns name="Local Area Connection" static 10.172.44.235
netsh interface ip add dns name="Local Area Connection" addr=10.172.44.237 index=2
netsh interface ip add dns name="Local Area Connection" addr=208.67.220.220 index=3
netsh interface ip add dns name="Local Area Connection" addr=8.8.4.4 index=4    
"@
}

function Get-NetShCommandsToRunOnRMSClientComputer {
    param (        
        [Parameter(Mandatory)][ValidateRange(0,255)][int]$StoreNetworkIdentifier,
        [Parameter(Mandatory)][ValidateSet("BackOffice","POS1","POS2")][string]$RMSClientRole,
        $InterfaceName = "Local Area Connection"
    )
    process {
        if ($RMSClientRole -eq "BackOffice") {
            $StaticIPAddress = '10.64.' + $StoreNetworkIdentifier + '.5'
        } elseif ($RMSClientRole -eq "POS1") {
            $StaticIPAddress = '10.64.' + $StoreNetworkIdentifier + '.11'
        } elseif ($RMSClientRole -eq "POS2") {
            $StaticIPAddress = '10.64.' + $StoreNetworkIdentifier + '.12'
        }
        $DefaultGateway = '10.64.' + $StoreNetworkIdentifier + '.1'
        $NetshDNSCommands = Get-NetshCommandsToSetDNSOnStoreEndpoint
        $NetshCommands = $NetshDNSCommands + @"
`r`nnetsh interface ip set address "$InterfaceName" static $StaticIPAddress 255.255.255.0 $DefaultGateway
"@
        $NetshCommands
    }
}

function Invoke-RMSHQManagerRemoteAppProvision {
    param (
        $EnvironmentName
    )
    Invoke-ApplicationProvision -ApplicationName RMSHQManagerRemoteApp -EnvironmentName $EnvironmentName
    $Nodes = Get-TervisApplicationNode -ApplicationName RMSHQManagerRemoteApp -EnvironmentName $EnvironmentName
    $Nodes | Copy-TervisRMSCustomReportsToNode
}

function Get-TervisBackOfficeDefaultUserName {
    param (
        [Parameter(Mandatory)]$ComputerName
    )
    invoke-command -ComputerName $ComputerName -ScriptBlock {
        Get-Itemproperty "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\winlogon"
    } | 
    Select-Object defaultusername -ExpandProperty defaultusername
}

function Invoke-NewBackOfficeRDPShorcuts {
    $BackOfficeComputers = Get-BackOfficeComputers
    $ADDomain = Get-ADDomain

    foreach ($ComputerName in $BackOfficeComputers) {
        $UserName = (Get-TervisBackOfficeDefaultUserName -ComputerName $ComputerName) -replace "$($ADDomain.Name)\\", ""
        New-BackOfficeRemoteDesktopRDPFile -ComputerName $ComputerName -UserName $UserName
        New-BackOfficeRemoteDesktopRDPFile -ComputerName $ComputerName -ManagerRDPFile
    }
}

function Copy-TervisRMSCustomReportsToNode {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$ComputerName
    )
    begin {
        $LocalDestinationPath = "C:\Program Files (x86)\Microsoft Retail Management System\Headquarters\Reports"
        $LocalSourcePath = "$PSScriptRoot\RMSReportsToBeCopied\*"
    }
    process {
        $RemoteDestinationPath = $LocalDestinationPath | ConvertTo-RemotePath -ComputerName $ComputerName
        Copy-Item -Path $LocalSourcePath -Destination $RemoteDestinationPath -Force
    }
}

function Copy-PersonalizeItConfigXmlFile {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$ComputerName,
        [Parameter(Mandatory)]$SourceFile
    )
    begin {
        $LocalXMLPath = "C:\Program Files\nChannel\Personalize\PersonalizeItConfig.xml"
    }
    process {
        $RemoteXMLPath = $LocalXMLPath | ConvertTo-RemotePath -ComputerName $ComputerName
        $RemoteXMLPathBackup = $RemoteXMLPath + ".bak"
        Copy-item -Path $RemoteXMLPath -Destination $RemoteXMLPathBackup -Force
        Copy-Item -Path $SourceFile -Destination $RemoteXMLPath -Force
    }       
}

function Invoke-RMSIntegrationSalesBatch{
    $DBTimeStamp = "0x0000000011C0F5CD"
    $DataBaseName = "Charleston"
    $SQLServerName = "DLT-RMSBO3"


    $InvokeSQLParameters = @{
        DataBaseName = $DataBaseName
        SQLServerName = $SQLServerName
    }
    
    #$DBTimeStamp = Get-RMSIntegrationGetSaleBatchSQLListenerListenerSQL @InvokeSQLParameters
    
    $BatchNumbers = Get-RMSIntegrationGetSaleBatchSQLListenerDataSQL -DBTimeStamp $DBTimeStamp @InvokeSQLParameters |
        Select-Object -ExpandProperty BatchNumber

    foreach ($BatchNumber in $BatchNumbers){
        Get-RMSIntegrationGetSalesBatchBatchLookup -BatchNumber $BatchNumber @InvokeSQLParameters
    }
}

function Get-RMSIntegrationGetSalesBatchBatchLookup {
    param(
        [parameter(mandatory)]$BatchNumber,
        [parameter(mandatory)]$DataBaseName,
        [parameter(mandatory)]$SQLServerName
    )
    # $BatchNumberAsCommanSepratedList = $BatchNumber -join ","
    # https://sharepoint.tervis.com/InformationTechnology/RMS/Pages/RMSIntegrations/TER/Sample-SQL-Output-by-rms.batchlookup.xslt_15728964.html

    $Query = @"
SELECT * 
FROM   batch 
WHERE  batchnumber IN ($BatchNumber);

SELECT tt.*, 
        tender.description 
FROM   tendertotals tt 
        JOIN batch 
            ON tt.storeid = batch.storeid 
            AND tt.batchnumber = batch.batchnumber 
        JOIN tender 
            ON tt.tenderid = tender.id 
            WHERE  batch.batchnumber IN ($BatchNumber) 
        AND count > 0; 

SELECT b.batchnumber, 
        Min(t.description) AS Description, 
        t.code, 
        Min(t.percentage)  AS Percentage, 
        Sum(total)         AS Total 
FROM   taxtotals tt 
        INNER JOIN tax t 
                ON tt.taxid = t.id 
        INNER JOIN batch b 
                ON tt.batchnumber = b.batchnumber 
WHERE  b.batchnumber IN ($BatchNumber) 
GROUP  BY b.batchnumber, 
            t.code; 

SELECT 'Batch' AS TableName 
UNION ALL 
SELECT 'TenderTotals' AS TableName 
UNION ALL 
SELECT 'TaxTotals' AS TableName 
"@

    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
}

function Get-RMSIntegrationGetSaleBatchSQLListenerListenerSQL{ 
    param(
        [parameter(mandatory)]$DataBaseName,
        [parameter(mandatory)]$SQLServerName
    )

    $Query = @"
select top 1 dbtimestamp from [batch] order by dbtimestamp desc
"@
    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
}

function Get-RMSIntegrationGetSaleBatchSQLListenerDataSQL{ 
    param(
        [parameter(mandatory)]$DBTimeStamp,
        [parameter(mandatory)]$DataBaseName,
        [parameter(mandatory)]$SQLServerName
    )

    $Query = @"
select BatchNumber from [batch] where dbtimestamp > $DBTimeStamp
"@
    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
}

function Invoke-RMSIntegrationSalesTransaction{
    $DBTimeStamp = "0x0000000011C0F5CD"
    $DataBaseName = "Charleston"
    $SQLServerName = "DLT-RMSBO3"


    $InvokeSQLParameters = @{
        DataBaseName = $DataBaseName
        SQLServerName = $SQLServerName
    }
    
    #$DBTimeStamp = Get-RMSIntegrationGetSalesTransactionSQLListenerListenerSQL @InvokeSQLParameters
    
    $TransactionNumbers = Get-RMSIntegrationGetSalesTransactionSQLListenerDataSQL -DBTimeStamp $DBTimeStamp @InvokeSQLParameters |
        Select-Object -ExpandProperty TransactionNumber

    foreach ($TransactionNumber in $TransactionNumbers){
        Get-RMSIntegrationGetSalesTransactionTransactionLookup -TransactionNumber $TransactionNumber @InvokeSQLParameters
    }

}

function Get-RMSIntegrationGetSalesTransactionTransactionLookup{
    param(
        [parameter(mandatory)]$TransactionNumber,
        [parameter(mandatory)]$DataBaseName,
        [parameter(mandatory)]$SQLServerName
    )
    $DataBaseName = "Charleston"
    $SQLServerName = "DLT-RMSBO3"

    #https://sharepoint.tervis.com/InformationTechnology/RMS/Pages/RMSIntegrations/TER/MSRMSStoreOps---Get-Sales-Transaction_15729034.html

    $Query = @"
        select * from [Transaction] where TransactionNumber = ($TransactionNumber)
        select te.*, item.ItemLookupCode ,  item.Description 
        from transactionentry te join item on te.ItemID=item.ID
        where te.TransactionNumber in ($TransactionNumber)
        
        select * from Customer where ID in (select customerid from [Transaction] where TransactionNumber = ($TransactionNumber))
        select top 10 * from ShipTo where CustomerID in (select customerid from [Transaction] where TransactionNumber = ($TransactionNumber)) order by dbtimestamp desc
        select * from TenderEntry where TransactionNumber = $TransactionNumber
        select te.*, t.* from taxentry te inner join tax t on te.taxid = t.id where te.transactionnumber in ($TransactionNumber)
        select s.*
        from shipping s
        where transactionnumber in ($TransactionNumber)
        
        Declare @refNumber nvarchar(50)
        set @refNumber = (select ReferenceNumber from [Transaction] where TransactionNumber = ($TransactionNumber))
        Select * from [Order] where ReferenceNumber = '@refNumber'
        select 'Transaction' as TableName
        union all
        select 'TransactionEntry' as TableName
        union all
        select 'Customer' as TableName
        union all
        select 'ShipTo' as TableName
        union all
        select 'TenderEntry' as TableName
        union all
        select 'Tax' as TableName
        union all
        select 'Shipping' as TableName
        union all
        select 'Order' as TableName -- Using this to pulling tracking number out, shipping table doesn't seem to have it.
"@

    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
}

function Get-RMSIntegrationGetSalesTransactionSQLListenerListenerSQL{
    param(
        [parameter(mandatory)]$DataBaseName,
        [parameter(mandatory)]$SQLServerName
    )
    $Query = @"
select top 1 dbtimestamp from [transaction] order by dbtimestamp desc
"@

    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
}

function Get-RMSIntegrationGetSalesTransactionSQLListenerDataSQL{
    param(
        [parameter(mandatory)]$DBTimeStamp,
        [parameter(mandatory)]$DataBaseName,
        [parameter(mandatory)]$SQLServerName
    )

    $Query = @"
select transactionnumber,customerid from [transaction] where dbtimestamp > $DBTimeStamp;
"@

    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
}

function Invoke-RMSUpdateLiddedItemQuantityFromDBUnliddedItemQuantity {
    [CmdletBinding()]
    param(
        [parameter(mandatory)]$ComputerName,
        [parameter(mandatory)]$PathToCSV,
        [parameter(mandatory)]$LiddedItemColumnName,
        [parameter(mandatory)]$UnliddedItemColumnName,
        [parameter(mandatory)]$LidItemColumnName,
        [switch]$PrimeSQL,
        [switch]$ExecuteSQL
    )

    Write-Verbose "Importing CSV"
    $CSVObject = Import-Csv -Path $PathToCSV
    
    Write-Verbose "Getting RMS database name on $ComputerName"
    $DatabaseName = Get-RMSDatabaseName -ComputerName $ComputerName -ErrorAction Stop | Select-Object -ExpandProperty RMSDatabaseName
    
    $InvokeRMSSQLParameters = @{
        DatabaseName = $DatabaseName
        SQLServerName = $ComputerName
    }
    $SetSizeInterval = 500
    $TimeDelay = 10

    Write-Verbose "Getting RMS data from $DatabaseName"
    $UnliddedItemResult = Get-RMSItemsUsingCSV -CSVObject $CSVObject -CSVColumnName $UnliddedItemColumnName @InvokeRMSSQLParameters
    $LiddedItemResult = Get-RMSItemsUsingCSV -CSVObject $CSVObject -CSVColumnName $LiddedItemColumnName @InvokeRMSSQLParameters

    Write-Verbose "Indexing RMS data"
    $IndexedCSV = $CSVObject | ConvertTo-IndexedHashtable -PropertyToIndex $UnliddedItemColumnName
    $IndexedLiddedItemResult = $LiddedItemResult | ConvertTo-IndexedHashtable -PropertyToIndex ItemLookupCode

    Write-Verbose "Building FinalUPCSet table"
    $FinalUPCSet = $UnliddedItemResult | 
        Where-Object Quantity -gt 0 |
        ForEach-Object {
            $ReferenceLiddedItemUPC = $IndexedCSV["$($_.ItemLookupCode)"].LiddedItem
            $ReferenceLidItemUPC = $IndexedCSV["$($_.ItemLookupCode)"].LidItem
            [PSCustomObject]@{
                $UnliddedItemColumnName = $_.ItemLookupCode
                $LiddedItemColumnName = $ReferenceLiddedItemUPC
                LidItem = $ReferenceLidItemUPC
                Quantity = $_.Quantity
                UnliddedID = $_.ID
                LiddedID = $IndexedLiddedItemResult[$ReferenceLiddedItemUPC].ID
                UnliddedDeltaQuantity = -1 * $_.Quantity
                LiddedDeltaQuantity = $_.Quantity
                UnliddedCost = $_.Cost
                LiddedCost = $IndexedLiddedItemResult[$ReferenceLiddedItemUPC].Cost
            }
        }

    $FinalUPCSet = Remove-FinalUPCSetDuplicates -FinalUPCSet $FinalUPCSet
    
    Write-Verbose "Building LidItemHashTable"
    $LidItemHashTable = New-LidItemQuantityHashTable -FinalUPCSet $FinalUPCSet
    
    $LidItemUPCs = $LidItemHashTable.keys | ForEach-Object {[PSCustomObject]@{
        LidItem = $_
    }}
    
    $LidItemsInCurrentInventory = Get-RMSItemsUsingCSV -CSVObject $LidItemUPCs -CSVColumnName LidItem @InvokeRMSSQLParameters
    
    $LidItemsAdjustedInventory = $LidItemsInCurrentInventory | ForEach-Object {
        $NewQuantity = $_.Quantity - $LidItemHashTable[$_.ItemLookupCode]
        [PSCustomObject]@{
            ItemLookupCode = $_.ItemLookupCode
            ID = $_.ID
            AdjustedQuantity = $NewQuantity
            LidDeltaQuantity = -1 * (Get-DeltaOfTwoNumbers $_.Quantity $NewQuantity)
            Cost = $_.Cost
            LastUpdated = $_.LastUpdated
        }
    }
       
    Write-Verbose "Building Query Array - UpdateLiddedItemQueryArray"
    $FinalUPCSet | ForEach-Object {
        [array]$UpdateLiddedItemQueryArray += @"
UPDATE Item
SET Quantity = $($_.Quantity), LastUpdated = GETDATE() 
WHERE ItemLookupCode = '$($_.$LiddedItemColumnName)' AND Quantity = 0

"@
    }

    Write-Verbose "Building Query Array - SetUnliddedItemToZeroQueryArray"
    $UnliddedItemsToSetToZero = ConvertTo-SQLArrayFromCSV -CSVObject $FinalUPCSet -CSVColumnName $UnliddedItemColumnName
        [array]$SetUnliddedItemToZeroQueryArray += @"
UPDATE Item
SET Quantity = 0, LastUpdated = GETDATE()
WHERE Quantity > 0 AND ItemLookupCode IN $UnliddedItemsToSetToZero

"@

    Write-Verbose "Building Query Array - UpdateLidItemQueryArray"
    $LidItemsAdjustedInventory | ForEach-Object {
        [array]$UpdateLidItemQueryArray += @"
UPDATE Item
SET Quantity = '$($_.AdjustedQuantity)', LastUpdated = GETDATE() 
WHERE ItemLookupCode = '$($_.ItemLookupCode)' AND LastUpdated < DATEADD(hh,-1,GETDATE())

"@
    }

    $InventoryTranferLogData_Unlidded = $FinalUPCSet | ForEach-Object {
            [PSCustomObject]@{
                ID = $_.UnliddedID
                Quantity = $_.UnliddedDeltaQuantity
                Cost = $_.UnliddedCost
            }
        }

    $InventoryTransferLogData_Lidded = $FinalUPCSet | ForEach-Object {
            [PSCustomObject]@{
                ID = $_.LiddedID
                Quantity = $_.LiddedDeltaQuantity
                Cost = $_.LiddedCost
            }
        }
    
    $InventoryTransferLogData_Lid = $LidItemsAdjustedInventory | ForEach-Object {
        [PSCustomObject]@{
            ID = $_.ID
            Quantity = $_.LidDeltaQuantity
            Cost = $_.Cost
        }
    }
    
    Write-Verbose "Building Query - InventoryTransferLogQuery for Unlidded"
    $InventoryTransferLogQuery += $InventoryTranferLogData_Unlidded | New-RMSInventoryTransferLogQuery
    
    Write-Verbose "Building Query - InventoryTransferLogQuery for Lidded"
    $InventoryTransferLogQuery += $InventoryTransferLogData_Lidded | New-RMSInventoryTransferLogQuery -ErrorAction SilentlyContinue

    Write-Verbose "Building Query - InventoryTransferLogQuery for Lids"
    $InventoryTransferLogQuery += $InventoryTransferLogData_Lid | New-RMSInventoryTransferLogQuery
   
    $RMSLidConversionLogDirectory = Get-RMSLidConversionLogDirectory
    New-Item -Path "$RMSLidConversionLogDirectory\$DatabaseName" -ItemType Directory -ErrorAction SilentlyContinue
    $FinalUPCSetExportPath = "$RMSLidConversionLogDirectory\$DatabaseName\$($DatabaseName)_LiddedUnlidded.csv"
    Write-Verbose "Exporting FinalUPCSet to $FinalUPCSetExportPath"
    $LidItemExportPath = "$RMSLidConversionLogDirectory\$DatabaseName\$($DatabaseName)_Lids.csv"
    $InventoryTransferLogQueryExportPath = "$RMSLidConversionLogDirectory\$DatabaseName\$($DatabaseName)_InventoryTransferLogQuery.txt"
    $FinalUPCSet | Export-Csv -LiteralPath $FinalUPCSetExportPath -Force
    $LidItemsAdjustedInventory | Export-Csv -Path $LidItemExportPath -Force
    $InventoryTransferLogQuery | Out-File -FilePath $InventoryTransferLogQueryExportPath -Force

    if ($PrimeSQL -and $ExecuteSQL) {
        Write-Verbose "Items to be updated: $($InventoryTransferLogQuery.Count)"
        
        Write-Verbose "DB Query - Setting lidded item quantities"
        Invoke-DeploySQLBySetSizeInterval -SQLArray $UpdateLiddedItemQueryArray -SetSizeInterval $SetSizeInterval @InvokeRMSSQLParameters
    
        Write-Verbose "DB Query - Setting unlidded items to ZERO"
        Invoke-DeploySQLBySetSizeInterval -SQLArray $SetUnliddedItemToZeroQueryArray -SetSizeInterval $SetSizeInterval @InvokeRMSSQLParameters

        Write-Verbose "DB Query - Setting lid items to adjusted quantity"
        Invoke-DeploySQLBySetSizeInterval -SQLArray $UpdateLidItemQueryArray -SetSizeInterval $SetSizeInterval @InvokeRMSSQLParameters

        Write-Verbose "DB Query - Inserting InventoryTransferLogs"
        Invoke-DeploySQLBySetSizeInterval -SQLArray $InventoryTransferLogQuery -SetSizeInterval $SetSizeInterval -DelayBetweenQueriesInMinutes $TimeDelay @InvokeRMSSQLParameters 
    } else {
        Write-Verbose "Items to be updated: $($InventoryTransferLogQuery.Count)"
        Write-Warning "ExecuteSQL parameter not set. No changes have been made to the database."
    }
}

function Invoke-DeploySQLBySetSizeInterval {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][array]$SQLArray,
        [Parameter(Mandatory)]$SQLServerName,
        [Parameter(Mandatory)]$DataBaseName,
        [Parameter(Mandatory)]$SetSizeInterval,
        $DelayBetweenQueriesInMinutes = 0
    )

    for ($i = 0; $i -lt $SQLArray.Count; $i += $SetSizeInterval) {
        $QueryToSend = ""
        $QueryToSend += $SQLArray | Select-Object -First $SetSizeInterval -Skip $i
        Write-Verbose "Sending queries $i through $($i + $SetSizeInterval - 1)"
        Invoke-RMSSQL @PSBoundParameters -Query $QueryToSend
        Start-Sleep -Seconds ($DelayBetweenQueriesInMinutes * 60)
    }    
}


function New-LidItemQuantityHashTable {
    param (
        $FinalUPCSet
    )

    $LidItemUniqueItemCodes = $FinalUPCSet | Select-Object -ExpandProperty LidItem -Unique
    [hashtable]$LidItemHashTable = @{}
    $LidItemUniqueItemCodes | ForEach-Object {[hashtable]$LidItemHashTable += @{$_=0}}

    $FinalUPCSet | ForEach-Object {
        $LidItemHashTable["$($_.LidItem)"] = $LidItemHashTable["$($_.LidItem)"] + $_.Quantity
    }

    $LidItemHashTable    
}

function Get-ItemFromRMSHQDB{
    param(
      [parameter(mandatory)][string]$UPCorEBSItemNumber
    )
    $ComputerName = "SQL"
    $DataBaseName = "TERVIS_RMSHQ1"
    if ($UPCorEBSItemNumber.length -eq 7){
        $SqlQueryGetItemIDFromAlias = @"
SELECT ItemID
FROM Alias
WHERE Alias = '$UPCorEBSItemNumber'
"@

        $ItemID = Invoke-MSSQL -Server $ComputerName -Database $DataBaseName -SQLCommand $SqlQueryGetItemIDFromAlias -ConvertFromDataRow | Select-Object -ExpandProperty ItemID
        $SqlQuery = @"
SELECT ID, HQID, ItemLookupCode, Quantity, Price, Description 
FROM Item
WHERE ID = '$ItemID'
"@

        Invoke-MSSQL -Database $DataBaseName -Server $ComputerName -SQLCommand $SqlQuery
    } elseif ($UPCorEBSItemNumber.length -eq 12){
        $SqlQuery = @"
SELECT ID, HQID, ItemLookupCode, Quantity, Price, Description 
FROM Item
WHERE ItemLookupCode = '$UPCorEBSItemNumber'
"@
        Invoke-MSSQL -Database $DataBaseName -Server $ComputerName -SQLCommand $SqlQuery
    }   
}

function Invoke-RMSInventoryTransferLogThing {
    param(
        [parameter(Mandatory)][PSCustomObject]$CSVObject,
        [parameter(Mandatory)]$CSVColumnName,
        [parameter(Mandatory)]$SQLServerName,
        [parameter(Mandatory)]$DatabaseName
    )
    $Items = Get-RMSItemsUsingCSV @PSBoundParameters
    $Items | New-RMSInventoryTransferLogQuery
}

function New-RMSInventoryTransferLogQuery {
    param(
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$ID,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$Quantity,
        #[parameter(Mandatory,ValueFromPipelineByPropertyName)]$LastUpdated,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$Cost
    )

    process {
        if ($Quantity -ne 0) {
@"
INSERT INTO InventoryTransferLog (
    "ItemID",
    "DetailID",
    "Quantity",
    "DateTransferred",
    "ReasonCodeID",
    "CashierID",
    "Type",
    "Cost"
) VALUES (
    '$ID',
    '0',
    '$Quantity',
    (SELECT 
        LastUpdated
    FROM
        Item
    WHERE
        ID = '$ID'
    ),
    0,
    1,
    5,
    '$Cost'
)
"@
        }
    }
}

function Get-RMSItemsUsingCSV {
    param(
        [cmdletbinding()]
        [parameter(Mandatory)][PSCustomObject]$CSVObject,
        [parameter(Mandatory)][string]$CSVColumnName,
        [parameter(Mandatory)][string]$SQLServerName,
        [parameter(Mandatory)][string]$DatabaseName
    )

    $ItemArray = ConvertTo-SQLArrayFromCSV -CSVObject $CSVObject -CSVColumnName $CSVColumnName

    $SQLCommand = @"
SELECT
    ItemLookupCode,
    ID,
    Quantity,
    Cost,
    LastUpdated
FROM
    Item
WHERE 
    ItemLookupCode in $ItemArray
"@

    Invoke-RMSSQL -DataBaseName $DatabaseName -SQLServerName $SQLServerName -Query $SQLCommand
}

function ConvertTo-IndexedHashtable {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$InputObject,
        [Parameter(Mandatory)]$PropertyToIndex
    )
    begin {
        $HashTable = @{}
    }
    process {
        try {
            $HashTable += @{
                $InputObject.$PropertyToIndex = $InputObject
            }
        }
        catch {
            Write-Warning "$($InputObject.$PropertyToIndex) could not be added to the index."
        }
    }
    end {
        $HashTable
    }
}

function ConvertFrom-EBSItemNumberToUPC {
    param (
        [Parameter(Mandatory)]$CSVObject,
        [Parameter(Mandatory)]$RMSHQServer,
        [Parameter(Mandatory)]$RMSHQDataBaseName, 
        [switch]$ReturnOnlyGoodData
    )

    $ColumnNames = $CSVObject | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    
    $AliasNumbers = foreach ($ColumnName in $ColumnNames) {
        $CSVObject.$ColumnName | ForEach-Object {
            $_
        }
    }

    $AliasNumberSQLArray = "('$($AliasNumbers -join "','")')"
    
    $EBSItemNumberToItemUPCTableQuery = @"
SELECT Alias.Alias AS EBSItemNumber, 
    Item.ItemLookupCode AS ItemUPC
FROM Alias JOIN Item
ON Alias.ItemID = Item.ID
WHERE Alias.Alias IN $AliasNumberSQLArray
"@
    $EBSItemNumberToItemUPCTable = Invoke-MSSQL -Server $RMSHQServer -Database $RMSHQDataBaseName -sqlCommand $EBSItemNumberToItemUPCTableQuery
    $IndexedEBSItemNumberToItemUPCTable = $EBSItemNumberToItemUPCTable | ConvertTo-IndexedHashtable -PropertyToIndex EBSItemNumber

    #Manual Index Fix
    $IndexedEBSItemNumberToItemUPCTable[1164529] = "093597869198" 
    $IndexedEBSItemNumberToItemUPCTable[1160250] = "093597858079" 
    $IndexedEBSItemNumberToItemUPCTable[1161453] = "093597861178" 
    $IndexedEBSItemNumberToItemUPCTable[1204401] = "888633287742" 
    $IndexedEBSItemNumberToItemUPCTable[1166112] = "093597873775" 
    $IndexedEBSItemNumberToItemUPCTable[1161456] = "093597861277" 
    $IndexedEBSItemNumberToItemUPCTable[1161457] = "093597861284"

    $NewCSVObject = @()
    $CSVObject | ForEach-Object {
        $TempRow = [PSCustomObject]@{}
        foreach ($ColumnName in $ColumnNames) {
            $Value = $IndexedEBSItemNumberToItemUPCTable["$($_.$ColumnName)"].ItemUPC
            $TempRow | Add-Member -MemberType NoteProperty -Name $ColumnName -Value $Value
            $TempRow | Add-Member -MemberType NoteProperty -Name "EBS$ColumnName" -Value $_.$ColumnName
        }
        [array]$NewCSVObject += $TempRow
    }

    if ($ReturnOnlyGoodData){
        $NewCSVObject | Where-Object {
            ($_.LiddedItem -ne $null) -or
            ($_.UnliddedItem -ne $null) -or
            ($_.LidItem -ne $null)
        }
    }
    else {
        $NewCSVObject
    }
}

function Add-TervisRMSTenderType {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$ComputerName,
        [Parameter(Mandatory)]$DatabaseName,
        [Parameter(Mandatory)]$Description,
        [Parameter(Mandatory)]$Code,
        $AdditionalDetailType = 0,
        $ScanCode = 0,
        $PrinterValidation = 0,
        $ValidationLine1,
        $ValidationLine2,
        $ValidationLine3,
        $VerificationType = 0,
        $VerifyViaEDC = 0,
        $PreventOverTendering = 0,
        $RoundToValue = 0.0000,
        $MaximumAmount = 0.0000,
        $DoNotPopCashDrawer = 0,
        $CurrencyID = 0,
        $DisplayOrder = 0,
        $ValidationMask,
        $SignatureRequired = 0,
        $AllowMultipleEntries = 0,
        $DebitSurcharge = 0.0000,
        $SupportCashBack = 0,
        $CashBackLimit = 0.0000,
        $CashBackFee  = 0.0000
    )

    $AddTenderTypeQuery = @"
exec sp_executesql N'SET NOCOUNT OFF; 
    INSERT INTO "Tender" (
        "Description",
        "AdditionalDetailType",
        "ScanCode",
        "PrinterValidation",
        "ValidationLine1",
        "ValidationLine2",
        "ValidationLine3",
        "VerificationType",
        "VerifyViaEDC",
        "PreventOverTendering",
        "Code",
        "RoundToValue",
        "MaximumAmount",
        "DoNotPopCashDrawer",
        "CurrencyID",
        "DisplayOrder",
        "ValidationMask",
        "SignatureRequired",
        "AllowMultipleEntries",
        "DebitSurcharge",
        "SupportCashBack",
        "CashBackLimit",
        "CashBackFee") 
    VALUES (@P1,@P2,@P3,@P4,@P5,@P6,@P7,@P8,@P9,@P10,@P11,@P12,@P13,@P14,@P15,@P16,@P17,@P18,@P19,@P20,@P21,@P22,@P23)',
    N'@P1 nvarchar(22),@P2 smallint,@P3 smallint,@P4 bit,@P5 nvarchar(1),@P6 nvarchar(1),@P7 nvarchar(1),@P8 int,@P9 bit,@P10 bit,@P11 nvarchar(5),@P12 money,@P13 money,@P14 bit,@P15 int,@P16 int,@P17 nvarchar(1),@P18 bit,@P19 bit,@P20 money,@P21 bit,@P22 money,@P23 money',
    N'$Description',$AdditionalDetailType,$ScanCode,$PrinterValidation,N'$ValidationLine1',N'$ValidationLine2',N'$ValidationLine3',$VerificationType,$VerifyViaEDC,$PreventOverTendering,N'$Code',$RoundToValue,$MaximumAmount,$DoNotPopCashDrawer,$CurrencyID,$DisplayOrder,N'$ValidationMask',$SignatureRequired,$AllowMultipleEntries,$DebitSurcharge,$SupportCashBack,$CashBackLimit,$CashBackFee
"@

    Write-Verbose "Adding $Description to $DatabaseName"
    Invoke-RMSSQL -DataBaseName $DatabaseName -SQLServerName $ComputerName -Query $AddTenderTypeQuery
}

function Add-TervisRMSCustomButton {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$ComputerName,
        [Parameter(Mandatory)]$DatabaseName,
        $Caption = "",        
        $Number = 0,
        $Style = 0,
        $Command = "",
        $Description = "",
        $Picture = "",
        $UseMask = 0
    )

    $AddCustomPOSButtonQuery = @"
exec sp_executesql 
    N'SET NOCOUNT OFF; 
        INSERT INTO "CustomButtons" (
            "Caption",        
            "Number",
            "Style",
            "Command",
            "Description",
            "Picture",
            "UseMask") 
        VALUES (@P1,
            @P2,
            @P3,
            @P4,
            @P5,
            @P6,
            @P7)',
    N'@P1 nvarchar(50),@P2 int,@P3 int,@P4 nvarchar(255),@P5 nvarchar(50),@P6 image,@P7 bit',
    N'$Caption',$Number,$Style,N'$Command',N'$Description',$Picture,$UseMask
"@

    Write-Verbose "Adding Custom POS Button $Description to $DatabaseName"
    Invoke-RMSSQL -DataBaseName $DatabaseName -SQLServerName $ComputerName -Query $AddCustomPOSButtonQuery
}

function Get-DeltaOfTwoNumbers {
    param (
        [Parameter(Mandatory,Position=1)]$FirstNumber,
        [Parameter(Mandatory,Position=2)]$SecondNumber
    )

    $NumberObject = $($FirstNumber,$SecondNumber) | Measure-Object -Maximum -Minimum

    if (
        (($FirstNumber -ge 0) -and ($SecondNumber -ge 0)) -or
        (($FirstNumber -lt 0) -xor ($SecondNumber -lt 0))
    ) {
        $NumberObject.Maximum - $NumberObject.Minimum
    } else {
        [System.Math]::Abs($NumberObject.Minimum - $NumberObject.Maximum)
    }
}

function Get-LiddedItemCostComparison {
    param (
        $FinalUPCSet,
        $LidItemsInCurrentInventory
    )

    $IndexedLidItems = $LidItemsInCurrentInventory | ConvertTo-IndexedHashtable -PropertyToIndex ItemLookupCode

    $FinalUPCSet | ForEach-Object  {
        $UnliddedCost = $_.UnliddedCost
        $LidCost = $IndexedLidItems[$_.LidItem].Cost
        $CostSum = ($UnliddedCost + $LidCost)
        $LiddedCostInRMS = $_.LiddedCost
        $DoesCostMatch = if ($CostSum -eq $LiddedCostInRMS) {$true} else {$false}

        [PSCustomObject]@{
            LiddedItem = $_.LiddedItem
            UnliddedCost = $UnliddedCost
            LidCost = $LidCost
            CostSum = $CostSum
            LiddedCostInRMS = $LiddedCostInRMS
            DoesCostMatch = $DoesCostMatch
        }
    }
}

function Remove-FinalUPCSetDuplicates {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$FinalUPCSet
    )
    begin {
        $DuplicateLiddedItemsUPCs = $FinalUPCSet.LiddedItem | Find-DuplicateValues
    }
    process {
        $FinalUPCSet | Where-Object LiddedItem -NotIn $DuplicateLiddedItemsUPCs
        #$ProblemItems = $FinalUPCSet | Where-Object LiddedItem -In $DuplicateLiddedItemsUPCs
    }
}

function Find-DuplicateValues {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$Values
    )
    begin {
        [hashtable]$tempHash = @{}
        [array]$DuplicateArray = $()
        [array]$ValuesArray = $()
    } process {
        $ValuesArray += $Values
    }
    end {
        for ($i = 0; $i -lt $ValuesArray.Count; $i++) {
            try {
                $tempHash += @{$ValuesArray[$i] = $null}
            } catch {
                $DuplicateArray += $ValuesArray[$i]
            }
        }

        $DuplicateArray | Sort-Object | Select-Object -Unique
    }
}

function Invoke-RMSLidConversionDeployment {
    
    $Parameters = Get-PasswordstatePassword -ID 5471
    $PathToComputerList = $Parameters.GenericField1
    $PathToCSV = $Parameters.GenericField2
    $ComputerNames = (Get-Content $PathToComputerList) -split "`n"

    Start-ParallelWork -Parameters $ComputerNames -OptionalParameters $PathToCSV -MaxConcurrentJobs 7 -ScriptBlock {
        param (
            $Parameters,
            $OptionalParameters
        )
        Invoke-RMSUpdateLiddedItemQuantityFromDBUnliddedItemQuantity `
            -ComputerName $Parameters `
            -PathToCSV $OptionalParameters `
            -LiddedItemColumnName LiddedItem `
            -UnliddedItemColumnName UnliddedItem `
            -LidItemColumnName LidItem -PrimeSQL -ExecuteSQL `
            -Verbose *> "C:\RMSLidConversionOutput\$Parameters.log"
    }
}

function Invoke-RMSLidQuantityAdjustmentAndInventoryTransferLogs_Osprey {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$PathToOriginalFinalUPCSetCSV,
        [Parameter(Mandatory)]$PathToNewFormatFinalUPCSetCSV,
        [Parameter(Mandatory)]$ComputerName,
        [switch]$PrimeSQL,
        [switch]$ExecuteSQL
    )

    Write-Verbose "Importing CSVs"
    $OriginalCSV = Import-Csv -Path $PathToOriginalFinalUPCSetCSV
    $NewFormatCSV = Import-Csv -Path $PathToNewFormatFinalUPCSetCSV
    
    Write-Verbose "Getting RMS database name on $ComputerName"
    $DatabaseName = Get-RMSDatabaseName -ComputerName $ComputerName -ErrorAction Stop | Select-Object -ExpandProperty RMSDatabaseName
    
    $InvokeRMSSQLParameters = @{
        DatabaseName = $DatabaseName
        SQLServerName = $ComputerName
    }
    $SetSizeInterval = 500
    $TimeDelay = 10

    Write-Verbose "Indexing RMS data"
    $IndexedOriginalCSV = $OriginalCSV | ConvertTo-IndexedHashtable -PropertyToIndex UnliddedItem

    Write-Verbose "Rebuilding FinalUPCSet for lid item adjustment"
    $FinalUPCSet = $NewFormatCSV | ForEach-Object {
        $Quantity = $IndexedOriginalCSV["$($_.UnliddedItem)"].Quantity
        if ($Quantity) {
            [PSCustomObject]@{
                UnliddedItem = $_.UnliddedItem
                LiddedItem = $_.LiddedItem
                LidItem = $_.LidItem
                Quantity = $Quantity
                UnliddedID = $_.UnliddedID
                LiddedID = $_.LiddedID
                UnliddedDeltaQuantity = -1 * $Quantity
                LiddedDeltaQuantity = $Quantity
                UnliddedCost = $_.UnliddedCost
                LiddedCost = $_.LiddedCost
            }
        }
    }

    $RMSLidConversionLogDirectory = Get-RMSLidConversionLogDirectory
    New-Item -Path "$RMSLidConversionLogDirectory\$DatabaseName" -ItemType Directory -ErrorAction SilentlyContinue
    $FinalUPCSet | Where-Object {-not $_.LiddedID} | Out-File "$RMSLidConversionLogDirectory\$DatabaseName\$($DatabaseName)_ExcludedItems.log"
    $FinalUPCSet = $FinalUPCSet | Where-Object {$_.LiddedID}

    Write-Verbose "Building LidItemHashTable"
    $LidItemHashTable = New-LidItemQuantityHashTable -FinalUPCSet $FinalUPCSet
    
    $LidItemUPCs = $LidItemHashTable.keys | ForEach-Object {[PSCustomObject]@{
        LidItem = $_
    }}
    
    $LidItemsInCurrentInventory = Get-RMSItemsUsingCSV -CSVObject $LidItemUPCs -CSVColumnName LidItem @InvokeRMSSQLParameters
    
    $LidItemsAdjustedInventory = $LidItemsInCurrentInventory | ForEach-Object {
        $NewQuantity = $_.Quantity - $LidItemHashTable[$_.ItemLookupCode]
        [PSCustomObject]@{
            ItemLookupCode = $_.ItemLookupCode
            ID = $_.ID
            AdjustedQuantity = $NewQuantity
            LidDeltaQuantity = -1 * (Get-DeltaOfTwoNumbers $_.Quantity $NewQuantity)
            Cost = $_.Cost
            LastUpdated = $_.LastUpdated
        }
    }

    Write-Verbose "Building Query Array - UpdateLidItemQueryArray"
    $LidItemsAdjustedInventory | ForEach-Object {
        [array]$UpdateLidItemQueryArray += @"
UPDATE Item
SET Quantity = '$($_.AdjustedQuantity)', LastUpdated = GETDATE() 
WHERE ItemLookupCode = '$($_.ItemLookupCode)' AND LastUpdated < DATEADD(hh,-1,GETDATE())

"@
    }

    $InventoryTranferLogData_Unlidded = $FinalUPCSet | ForEach-Object {
        [PSCustomObject]@{
            ID = $_.UnliddedID
            Quantity = $_.UnliddedDeltaQuantity
            Cost = $_.UnliddedCost
        }
    }

    $InventoryTransferLogData_Lidded = $FinalUPCSet | ForEach-Object {
            [PSCustomObject]@{
                ID = $_.LiddedID
                Quantity = $_.LiddedDeltaQuantity
                Cost = $_.LiddedCost
            }
        }

    $InventoryTransferLogData_Lid = $LidItemsAdjustedInventory | ForEach-Object {
        [PSCustomObject]@{
            ID = $_.ID
            Quantity = $_.LidDeltaQuantity
            Cost = $_.Cost
        }
    }

    Write-Verbose "Building Query - InventoryTransferLogQuery for Unlidded"
    $InventoryTransferLogQuery += $InventoryTranferLogData_Unlidded | New-RMSInventoryTransferLogQuery

    Write-Verbose "Building Query - InventoryTransferLogQuery for Lidded"
    $InventoryTransferLogQuery += $InventoryTransferLogData_Lidded | New-RMSInventoryTransferLogQuery -ErrorAction SilentlyContinue

    Write-Verbose "Building Query - InventoryTransferLogQuery for Lids"
    $InventoryTransferLogQuery += $InventoryTransferLogData_Lid | New-RMSInventoryTransferLogQuery

    # $FinalUPCSetExportPath = "$RMSLidConversionLogDirectory\$DatabaseName\$($DatabaseName)_LiddedUnlidded.csv"
    # Write-Verbose "Exporting FinalUPCSet to $FinalUPCSetExportPath"
    # $LidItemExportPath = "$RMSLidConversionLogDirectory\$DatabaseName\$($DatabaseName)_Lids.csv"
    # $InventoryTransferLogQueryExportPath = "$RMSLidConversionLogDirectory\$DatabaseName\$($DatabaseName)_InventoryTransferLogQuery.txt"
    # $FinalUPCSet | Export-Csv -LiteralPath $FinalUPCSetExportPath -Force
    # $LidItemsAdjustedInventory | Export-Csv -Path $LidItemExportPath -Force
    # $InventoryTransferLogQuery | Out-File -FilePath $InventoryTransferLogQueryExportPath -Force
    # $UpdateLidItemQueryArray | Out-File -FilePath "$RMSLidConversionLogDirectory\$DatabaseName\$($DatabaseName)_LidItemSetQuantityQuery.txt"
    
    Write-Verbose "Items to be updated: $($InventoryTransferLogQuery.Count)"
    if ($PrimeSQL -and $ExecuteSQL) {
         #Write-Verbose "DB Query - Setting lid items to adjusted quantity"
        #Invoke-DeploySQLBySetSizeInterval -SQLArray $UpdateLidItemQueryArray -SetSizeInterval $SetSizeInterval @InvokeRMSSQLParameters

        Write-Verbose "DB Query - Inserting InventoryTransferLogs"
        Invoke-DeploySQLBySetSizeInterval -SQLArray $InventoryTransferLogQuery -SetSizeInterval $SetSizeInterval -DelayBetweenQueriesInMinutes $TimeDelay @InvokeRMSSQLParameters 
    } else {
        Write-Warning "ExecuteSQL parameter not set. No changes have been made to the database."
    }
}

function Get-RMSLidConversionLogDirectory {
    (Get-PasswordstatePassword -ID 5475).GenericField1
}

function Test-TervisStoreDatabaseConnectivity {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$StoreComputerObject,
        [switch]$Extended
    )
    process {
        $ConnectionResult = Test-NetConnection -ComputerName $StoreComputerObject.IPV4Address -Port 1433 -WarningAction SilentlyContinue
        if ($ConnectionResult.TcpTestSucceeded -and $Extended) {
            $SQLQueryResult = try {
                $QueryResult = Invoke-RMSSQL -DataBaseName master -SQLServerName $StoreComputerObject.IPV4Address -Query "SELECT 1" -ErrorAction Stop
                if ($QueryResult) {$true} else {$false}
            } catch {
                $false
            }
        }
        [PSCustomObject]@{
            ComputerName = $StoreComputerObject.ComputerName
            TcpTestSucceeded = $ConnectionResult.TcpTestSucceeded
            SQLQuerySucceeded = $SQLQueryResult
        }
    }
}

function Test-TervisStoreNetConnection {
    $ComputerObjects = Get-RegisterComputerObjects
    $ComputerObjects += Get-BackOfficeComputerObjects

    foreach ($Computer in $ComputerObjects) {
        $PingTest = Test-NetConnection -ComputerName $Computer.IPv4Address -WarningAction SilentlyContinue
        [PSCustomObject]@{
            ComputerName = $Computer.ComputerName
            PingSucceeded = $PingTest.PingSucceeded
        }
    }
}

function Get-TervisRmsHookAclStatus {
    param (
        [Parameter(Mandatory)]$ReferenceComputerName,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$ComputerName
    )
    begin {
        $Path = 'HKLM:\SOFTWARE\Microsoft\Retail Management System\Store Operations\Hooks'
        $ReferenceAcl = Invoke-Command -ComputerName $ReferenceComputerName -ScriptBlock {
            (Get-Acl -Path $using:Path).GetAccessRules($true,$true, [System.Security.Principal.NTAccount])
        }
    }
    process {
        $DifferenceAcl = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            (Get-Acl -Path $using:Path).GetAccessRules($true,$true, [System.Security.Principal.NTAccount])
        }
        
        $IsAclCorrect = if (
            $ReferenceAcl[0].AccessControlType -eq $DifferenceAcl[0].AccessControlType -and
            $ReferenceAcl[0].IdentityReference -eq $DifferenceAcl[0].IdentityReference -and
            $ReferenceAcl[0].RegistryRights -eq $DifferenceAcl[0].RegistryRights
        ) {$true} else {$false}

        [PSCustomObject]@{
            ComputerName = $ComputerName
            IsAclCorrect = $IsAclCorrect
        }
    }
}

function Update-TervisRMSSaleReceipt {
    param (
        [Parameter(Mandatory)]
        [ValidateSet("TervisSaleReceipt", "TervisBBReceipt")]$ReceiptTemplate,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$ComputerName
    )
    begin {
        $ReceiptTemplateData = Get-Content -Path "$PSScriptRoot\ReceiptTemplates\$ReceiptTemplate.xml" -Raw -Encoding UTF8
        $Query = @"
            UPDATE Receipt
            SET TemplateSale = '$ReceiptTemplateData'
            , TemplateCancel = '$ReceiptTemplateData'
            , TemplateWorkOrder = '$ReceiptTemplateData'
            WHERE ID = 1
"@
    }
    process {
        Write-Verbose "$ComputerName`: Setting receipt template to $ReceiptTemplate"
        $DB = Get-RMSDatabaseName -ComputerName $ComputerName
        Invoke-RMSSQL -DataBaseName $DB.RMSDatabaseName -SQLServerName $ComputerName -Query $Query
    }
}
