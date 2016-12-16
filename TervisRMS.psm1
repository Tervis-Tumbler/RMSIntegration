#Requires -modules TervisPowerShellJobs,InvokeSQL,PasswordstatePowershell

function Get-BackOfficeComputers {
    param(
        [Switch]$Online = $True
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

    $Responses | 
    where Online -EQ $true |
    Select -ExpandProperty BackOfficeComputerName
}

function Get-RegisterComputers {
    param(
        [Switch]$Online = $True
    )

    $RegisterComputerNames = Get-ADComputer -Filter * -SearchBase "OU=Register Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" |
    Select -ExpandProperty name

    $Responses = Start-ParallelWork -ScriptBlock {
        param($Parameter)
        [pscustomobject][ordered]@{
            RegisterComputerName = $Parameter;
            Online = $(Test-Connection -ComputerName $Parameter -Count 1 -Quiet);        
        }
    } -Parameters $RegisterComputerNames

    $Responses | 
    where Online -EQ $true |
    Select -ExpandProperty RegisterComputerName
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
        (Get-WmiObject Win32_Process -ComputerName $RegisterComputer | ?{ $_.ProcessName -match "soposuser" }).Terminate()
    }

}

function Get-PersonalizeItConfigFileInfo {
    $RegisterComputers = Get-RegisterComputers -Online

    foreach ($RegisterComputer in $RegisterComputers) {
        Invoke-Command -ComputerName $RegisterComputer { Get-ChildItem "C:\Program Files\nChannel\Personalize\PersonalizeItConfig.xml" } -ErrorAction SilentlyContinue | Select-Object pscomputername,name,lastwritetime | sort lastwritetime
    }

}

function Get-PersonalizeItDllFileInfo {
    $RegisterComputers = Get-RegisterComputers -Online

    foreach ($RegisterComputer in $RegisterComputers) {
        Invoke-Command -ComputerName $RegisterComputer { Get-ChildItem "C:\Program Files\nChannel\Personalize\Personalize.dll" } -ErrorAction SilentlyContinue | Select-Object pscomputername,name,lastwritetime
    }

}

function Invoke-TervisRegisterComputerGPUpdate {
    $RegisterComputers = Get-RegisterComputers -Online

    foreach ($RegisterComputer in $RegisterComputers) {
        Invoke-GPUpdate -Computer $RegisterComputer -RandomDelayInMinutes 0 -Force
    }
}

function Invoke-ConvertOfflineDBToSimpleRecoverModel {
    [CmdletBinding()]
    param (
        
    )

    Write-Verbose -Message "Getting online registers"
    $OnlineRegisters = Get-RegisterComputers

    <#
    Start-ParallelWork -ScriptBlock {
        param ($Parameter)
        [PSCustomObject][Ordered]@{
            ComputerName = $Parameter
            RemoteSQLEnabled = (Get-SQLRemoteAccessEnabled -ComputerName $Parameter)
        }
    } -Parameters $OnlineRegisters

    Get-OfflineDBTransactionLogName
    # Get free space before
    # Run SQL command to fix issue
    # Get free space after
    #>
}

function Enable-SQLRemoteAccess {
    param (
        [Parameter(Mandatory=$true)]$ComputerName
    )

    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        $SQLTCPKeyPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL10_50.MSSQLSERVER\MSSQLServer\SuperSocketNetLib\Tcp"
        $SQLTCPKey = Get-ItemProperty -Path $SQLTCPKeyPath
        if (-not $SQLTCPKey.Enabled) {
            Set-ItemProperty -Path $SQLTCPKeyPath -Name Enabled -Value 1
            Restart-Service -Name MSSQLSERVER -Force
        }
    }
}

function Get-SQLRemoteAccessEnabled {
    param (
        [Parameter(Mandatory=$true)]$ComputerName
    )

    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        $SQLTCPKeyPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL10_50.MSSQLSERVER\MSSQLServer\SuperSocketNetLib\Tcp"
        $SQLTCPKey = Get-ItemProperty -Path $SQLTCPKeyPath
        $SQLTCPKey.Enabled
    }
}

function Get-OfflineDBTransactionLogName {
    param (
        $Credential = (Get-PasswordstateCredential -PasswordID 56),
        [Parameter(Mandatory=$true)]$ComputerName
    )

    $TransactionLogFileNameSQLQuery = @"
SELECT name
FROM sys.master_files
WHERE name LIKE '%\_Log' ESCAPE '\';
"@

    Invoke-RMSSQL -SQLServerName $ComputerName -DataBaseName OfflineDB -Query $TransactionLogFileNameSQLQuery |
        Select-Object -ExpandProperty Name
}