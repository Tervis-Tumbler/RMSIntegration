function Start-ParrallelWork {
    param (
        $ScriptBlock,
        $Parameters
    )
    $Jobs = @()

    foreach ($Parameter in $Parameters) {
        while ($(Get-Job -State Running | where Id -In $Jobs.Id | Measure).count -ge 10) { Start-Sleep -Milliseconds 100 }
        $Jobs += Start-Job -ScriptBlock $ScriptBlock -ArgumentList $Parameter
    }

    while (
        Get-Job -State Running | 
        where Id -In $Jobs.Id
    ) {
        Write-Verbose "Sleeping for 100 milliseconds"
        Start-Sleep -Milliseconds 100 
    }
    
    $Results = Get-Job -HasMoreData $true | 
    where Id -In $Jobs.Id |
    Receive-Job

    Get-Job -State Completed | 
    where Id -In $Jobs.Id | 
    Remove-Job
    
    $Results
}

function Get-BackOfficeComputers {
    param(
        [Switch]$Online = $True
    )

    $BackOfficeComputerNames = Get-ADComputer -Filter * -SearchBase "OU=Back Office Computers,OU=Remote Store Computers,OU=Computers,OU=Stores,OU=Departments,DC=tervis,DC=prv" |
    Select -ExpandProperty name

    $Responses = Start-ParrallelWork -ScriptBlock {
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

function Get-BackOfficeComputersWhereConditionTrue {
    param(
        $BackOfficeComputerNames,
        $ConditionScriptBlock
    )

    $Responses = Start-ParrallelWork -ScriptBlock {
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

    $Responses = Start-ParrallelWork -ScriptBlock {
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

function Invoke-SQL {
    param(
        [string] $dataSource = ".\SQLEXPRESS",
        [string] $database = "MasterData",
        [string] $sqlCommand = $(throw "Please specify a query."),
        [string]$SQLUser,
        [String]$SQLPassword
      )

    $connectionString = "Server=$dataSource;Database=$database;User Id=$SQLUser;Password=$SQLPassword;"

    $connection = new-object system.data.SqlClient.SQLConnection($connectionString)
    $command = new-object system.data.sqlclient.sqlcommand($sqlCommand,$connection)
    $connection.Open()
    
    $adapter = New-Object System.Data.sqlclient.sqlDataAdapter $command
    $dataset = New-Object System.Data.DataSet
    $adapter.Fill($dataSet) | Out-Null
    
    $connection.Close()
    $dataSet.Tables 
}

function ConvertFrom-DataRow {
    param(
        [Parameter(
            Position=0, 
            Mandatory=$true, 
            ValueFromPipeline=$true,
            ValueFromPipelineByPropertyName=$true
        )]
        $DataRow
    )
    process {
        $DataRowProperties = $DataRow | GM -MemberType Properties | select -ExpandProperty name
        $DataRowWithLimitedProperties = $DataRow | select $DataRowProperties
        $DataRowAsPSObject = $DataRowWithLimitedProperties | % { $_ | ConvertTo-Json | ConvertFrom-Json }
        
        if($DataRowAsPSObject | GM | where membertype -NE "Method") {
            $DataRowAsPSObject
        }
    }
}

function Get-RMSDatabaseName {
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
    $Results = Invoke-RMSSQL -DataBaseName "master" -SQLServerName $BackOfficeComputerName -Query $Query | 
    TervisRMS\ConvertFrom-DataRow

    $RMSDatabaseName = $Results | 
    sort TotalSizeMB -Descending | 
    select -First 1 -ExpandProperty Name

    [pscustomobject][ordered]@{
        BackOfficeComputerName = $BackOfficeComputerName;
        RMSDatabaseName = $RMSDatabaseName;        
    }
}

function Get-ValueFromSecureString {
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        $SecureString
    )
    (New-Object System.Management.Automation.PSCredential 'N/A', $SecureString).GetNetworkCredential().Password
}

function New-RMSSQLDatabaseCredentials {
    param(
        $SQLUser,
        $SQLPassword
    )

    $SQLUser | ConvertTo-SecureString -AsPlainText -Force |
    ConvertFrom-SecureString |
    Out-File -FilePath "$env:USERPROFILE\Documents\RMSSQLUser.txt"

    $SQLPassword | ConvertTo-SecureString -AsPlainText -Force |
    ConvertFrom-SecureString |
    Out-File -FilePath "$env:USERPROFILE\Documents\RMSSQLPassword.txt"
}

function Invoke-RMSSQL {
    param(
        $DataBaseName,
        $SQLServerName,
        $Query
    )
    $SQLUser = Get-Content "$env:USERPROFILE\Documents\RMSSQLUser.txt" | ConvertTo-SecureString | Get-ValueFromSecureString
    $SQLPassword = Get-Content "$env:USERPROFILE\Documents\RMSSQLPassword.txt" | ConvertTo-SecureString | Get-ValueFromSecureString

    TervisRMS\Invoke-SQL -dataSource $SQLServerName -database $DataBaseName -sqlCommand $Query -SQLUser $SQLUser -SQLPassword $SQLPassword | 
    TervisRMS\ConvertFrom-DataRow
}

function Get-RMSBatchNumber {
    param(
        $LastDBTimeStamp,
        $DataBaseName,
        $SQLServerName
    )
    $Query = "select BatchNumber from [batch] where dbtimestamp > $LastDBTimeStamp"

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
    $BackOfficeServerAndDatabaseNames = Get-BackOfficeDatasbaseNames

    #$Responses = Start-ParrallelWork -ScriptBlock {
    #    param($Parameter)
    #    Get-RMSBatch -DataBaseName $Parameter.RMSDatabasename -SQLServerName $Parameter.backofficecomputername
    #} -Parameters $BackOfficeServerAndDatabaseName
    #
    #$Responses | 
    #where ConditionResult -EQ $true | 
    #select -ExpandProperty BackOfficeComputerName

    foreach ($BackOfficeServerAndDatabaseName in $BackOfficeServerAndDatabaseNames) {
        Get-RMSBatch -DataBaseName $BackOfficeServerAndDatabaseName.RMSDatabasename -SQLServerName $BackOfficeServerAndDatabaseName.backofficecomputername -LastDBTimeStamp
    }

    $BatchNumbers = Get-RMSBatchNumber -LastDBTimeStamp "0x000000000639A82E" -SQLServerName "3023MYBO1-PC" -DataBaseName "MontereyStore"
    $Batches = Get-RMSBatch -BatchNumber $BatchNumbers -DataBaseName "MontereyStore" -SQLServerName "3023MYBO1-PC"
}

function Get-RMSTransaction {
    param(
        $BatchNumber
    )
    $BatchNumberAsCommanSepratedList = $BatchNumber -join ","

    $Query = "select * from [Transaction] where BatchNumber in ($BatchNumberAsCommanSepratedList)"

    Invoke-RMSSQL -DataBaseName $DataBaseName -SQLServerName $SQLServerName -Query $Query
}

function Get-BackOfficeDatasbaseNames {
    $BackOfficeComputerNames = Get-BackOfficeComputersRunningSQL

    $Responses = Start-ParrallelWork -ScriptBlock {
        param($Parameter) 
        Get-RMSDatabaseName -BackOfficeComputerName $Parameter
    } -Parameters $BackOfficeComputerNames
    
    $Responses | 
    select backofficecomputername, RMSDatabasename
}
