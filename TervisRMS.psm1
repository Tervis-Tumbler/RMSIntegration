#Requires -modules TervisPowerShellJobs,InvokeSQL,TervisPasswordstatePowershell,TervisSQLPS

function Get-HeadquartersServers {
    param(
        [Switch]$Online = $True
    )

    $RMSHQServersOU = Get-ADOrganizationalUnit -Filter { Name -eq "RMSHQ Servers" } 
    $HeadquartersServersNames = Get-ADComputer -SearchBase $RMSHQServersOU -Filter { Name -like "*RMSHQ*" } |
    Select -ExpandProperty name

    $ClusterResources = Get-ClusterGroup -Cluster hypervcluster5 | 
    where grouptype -eq "VirtualMachine" |
    where Name -In $HeadquartersServersNames

    Get-VM -ClusterObject $ClusterResources

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        [pscustomobject][ordered]@{
            BackOfficeComputerName = $Parameter;
            Online = $(Test-Connection -ComputerName $Parameter -Count 1 -Quiet);        
        }
    } -Parameters $BackOfficeComputerNames

    $Responses | 
    where Online -EQ $true |
    Select -ExpandProperty BackOfficeComputerName
}

function Get-BackOfficeComputers {
    param(
        [Switch]$Online
    )

    $BackOfficeComputerNames = Get-ADComputer -Filter * -SearchBase "OU=Back Office Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" |
    Select -ExpandProperty name

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        [pscustomobject][ordered]@{
            BackOfficeComputerName = $Parameter;
            Online = $(Test-Connection -ComputerName $Parameter -Count 1 -Quiet);        
        }
    } -Parameters $BackOfficeComputerNames

    if ($Online) {
        $Responses | 
        where Online -EQ $true |
        Select -ExpandProperty BackOfficeComputerName
    } else {
        $Responses |         
        Select -ExpandProperty BackOfficeComputerName
    }
}

function Get-RegisterComputers {
    param(
        [Switch]$Online
    )

    $RegisterComputerNames = Get-ADComputer -Filter * -SearchBase "OU=Register Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" |
        where Enabled -EQ $true |
        Select -ExpandProperty name

   

    if ($Online) {
        $Responses = Start-ParallelWork -ScriptBlock {
            param($Parameter)
            [pscustomobject][ordered]@{
                RegisterComputerName = $Parameter;
                Online = $(Test-Connection -ComputerName $Parameter -Count 1 -Quiet);        
            }
        } -Parameters $RegisterComputerNames | 
        where Online -EQ $true |
        Select -ExpandProperty RegisterComputerName
    } else {
        $RegisterComputerNames
    }
}

function Get-RegisterComputerObjects {
    param (
        [System.UInt16]$MaxAgeInDays = 31
    )

    Get-ADComputer -Filter * -SearchBase "OU=Register Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" -Properties LastLogonDate,IPv4Address |
        where Enabled -EQ $true |
        where {$_.LastLogonDate -GT (Get-Date).AddDays(-1*$MaxAgeInDays)} |
        Add-Member -MemberType AliasProperty -Name ComputerName -Value Name -Force -PassThru
}

function Get-OmittedRegisterComputers {
    param (
        $OnlineRegisterComputers = (Get-RegisterComputers -Online)
    )
    $AllRegisterComputers = Get-ADComputer -Filter * -SearchBase "OU=Register Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" |
        select -ExpandProperty Name
    compare $AllRegisterComputers $OnlineRegisterComputers -PassThru
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
    where ConditionResult -EQ $true | 
    select -ExpandProperty BackOfficeComputerName
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
    where RunningSQL -EQ $true | 
    select -ExpandProperty BackOfficeComputerName
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
    sort TotalSizeMB -Descending | 
    select -First 1 -ExpandProperty Name

    [pscustomobject][ordered]@{
        BackOfficeComputerName = $BackOfficeComputerName
        RMSDatabaseName = $RMSDatabaseName
    }
}

function New-RMSSQLDatabaseCredentials {
    param (
        $Credential = $(Get-credential -Message "Enter RMS back office SQL server databse user credentials" ) 
    )

    $Credential | Export-Clixml -Path "$env:USERPROFILE\RMSSQLCredential.txt"
}

function Invoke-RMSSQL {
    param(
        $DataBaseName,
        $SQLServerName,
        $Query
    )
    $Credential = Get-PasswordstateCredential -PasswordID 56
    Invoke-SQL -dataSource $SQLServerName -database $DataBaseName -sqlCommand $Query -Credential $Credential | ConvertFrom-DataRow
}

function Get-RMSBatchNumber {
    param(
        $LastDBTimeStamp,
        $DataBaseName,
        $SQLServerName
    )
    $Query = "select BatchNumber from [batch] where dbtimestamp > $LastDBTimeStamp AND Status = 7"

    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query | 
    Select -ExpandProperty BatchNumber
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
    #where ConditionResult -EQ $true | 
    #select -ExpandProperty BackOfficeComputerName

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
    select backofficecomputername, RMSDatabasename
}

function Get-ComputersInOU {
    param(
        [Switch]$Online = $True,
        [Parameter(Mandatory)]$OUPath
    )

    $ComputerNames = Get-ADComputer -Filter * -SearchBase $OUPath |
        Select -ExpandProperty name

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        [pscustomobject][ordered]@{
            ComputerName = $Parameter;
            Online = $(Test-Connection -ComputerName $Parameter -Count 1 -Quiet);        
        }
    } -Parameters $ComputerNames

    $Responses | 
        where Online -EQ $true |
        Select -ExpandProperty ComputerName
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
        where ConditionResult -EQ $true | 
        select -ExpandProperty ComputerName
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
        where RunningSQL -EQ $true | 
        select -ExpandProperty ComputerName
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
        sort TotalSizeMB -Descending | 
        select -First 1 -ExpandProperty Name

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
        select ComputerName, RMSDatabasename
}

function Stop-SOPOSUSERProcess {
    $RegisterComputers = Get-RegisterComputers -Online

    foreach ($RegisterComputer in $RegisterComputers) {
        $RegisterComputer
        (Get-WmiObject Win32_Process -ComputerName $RegisterComputer | ?{ $_.ProcessName -match "soposuser" }).Terminate()
    }

}

function Stop-SOPOSUSERProcessParallel {
    param (
        $RegisterComputers = (Get-RegisterComputers -Online)
    )

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        $Credential = Get-PasswordstateCredential -PasswordID 417
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
        $RegisterComputers = (Get-RegisterComputers -Online)
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
        $RegisterComputers = (Get-RegisterComputers -Online)
    ) 

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter) 
        Restart-Computer -ComputerName $Parameter -Force -Verbose 
    } -Parameters $RegisterComputers

    $Responses
}

function Invoke-ConvertOfflineDBToSimpleRecoverModel {
    [CmdletBinding()]
    param (
        #$RegisterComputer
    )

    Write-Verbose -Message "Getting online registers"
    $OnlineRegisters = Get-RegisterComputers -Online
    
    Start-ParallelWork -Parameters $OnlineRegisters -ScriptBlock {
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
        $Credential = (Get-PasswordstateCredential -PasswordID 56),
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
    } | select ComputerName,name,recovery_model_desc
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
                where {$_.DisplayName -match "Shift4 Universal Transaction Gateway"} |
                select -Property DisplayName,DisplayVersion,InstallDate
        }
        if (!$UTGProductInformation) {
            Write-Warning "Could not get UTG install information from $parameter"
        } else {
            Add-Member -InputObject $UTGProductInformation -MemberType NoteProperty -Name ComputerName -Value $parameter
        }
        $UTGProductInformation 
    } | select ComputerName,DisplayName,DisplayVersion,InstallDate
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
    } | select ComputerName,DisplayName,DisplayVersion
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
        $ADDNSRoot = $ADDomain | Select -ExpandProperty DNSRoot
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
            Select -First 1 -ExpandProperty DNSName) | `
            Where OptionID -eq 6 | `
            Select -ExpandProperty Value
        $DNSServerIPAddresses += '208.67.220.220','8.8.4.4'
        if ($UseWMI) {
            $IPConfiguration = Get-WmiObject win32_networkadapterconfiguration -ComputerName $ComputerName | where IPEnabled
            $InterfaceIndex = $IPConfiguration | Select -ExpandProperty InterfaceIndex
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
            $InterfaceName = $CurrentNicConfiguration | Select -ExpandProperty InterfaceAlias
            Set-DnsClientServerAddress `
                -InterfaceAlias ($CurrentNicConfiguration).InterfaceAlias `
                -ServerAddresses $DNSServerIPAddresses `
                -CimSession $CimSession
            $IPConfiguration = Get-WmiObject win32_networkadapterconfiguration -ComputerName $ComputerName | where Description -eq ($CurrentNicConfiguration).InterfaceDescription
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
    $TotalComputers = $BackOfficeComputers | measure | select -ExpandProperty Count
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
    select defaultusername -ExpandProperty defaultusername
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

function Invoke-RMSSQLUpdateItemQuantityFromCSV{
    param(
        [parameter(mandatory)$ComputerName
    )

    $CSV = Import-Csv -Path 'C:\users\alozano\OneDrive - Tervis\Desktop\ItemNumberList.csv'
    $DatabaseName = Get-RMSDatabaseName -ComputerName $ComputerName -Verbose
    $SQLUpdateQuery = ""

    foreach ($Item in $CSV){
        $SQLUpdateQuery += @"
UPDATE Item
SET Quantity = $($Item.Quantity)
WHERE ItemID = $($Item.Lidded) AND Item.Quantity = 0

"@
    }

    Invoke-RMSSQL -DataBaseName $DatabaseName -SQLServerName $ComputerName -Query $SQLUpdateQuery
}