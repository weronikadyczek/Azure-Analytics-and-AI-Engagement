$yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "I accept the license agreement."
$no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "I do not accept and wish to stop execution."
$options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
$title = "Agreement"
$message = "By typing [Y], I hereby confirm that I have read the license ( available at https://github.com/microsoft/Azure-Analytics-and-AI-Engagement/blob/main/license.md ) and disclaimers ( available at https://github.com/microsoft/Azure-Analytics-and-AI-Engagement/blob/main/README.md ) and hereby accept the terms of the license and agree that the terms and conditions set forth therein govern my use of the code made available hereunder. (Type [Y] for Yes or [N] for No and press enter)"
$result = $host.ui.PromptForChoice($title, $message, $options, 1)
if ($result -eq 1) {
    write-host "Thank you. Please ensure you delete the resources created with template to avoid further cost implications."
}
else 
{
    function RefreshTokens()
    {
        #Copy external blob content
        $global:powerbitoken = ((az account get-access-token --resource https://analysis.windows.net/powerbi/api) | ConvertFrom-Json).accessToken
        $global:synapseToken = ((az account get-access-token --resource https://dev.azuresynapse.net) | ConvertFrom-Json).accessToken
        $global:graphToken = ((az account get-access-token --resource https://graph.microsoft.com) | ConvertFrom-Json).accessToken
        $global:managementToken = ((az account get-access-token --resource https://management.azure.com) | ConvertFrom-Json).accessToken
        $global:purviewToken = ((az account get-access-token --resource https://purview.azure.net) | ConvertFrom-Json).accessToken
        $global:fabric = ((az account get-access-token --resource https://api.fabric.microsoft.com) | ConvertFrom-Json).accessToken
    }

    function Check-HttpRedirect($uri) {
        $httpReq = [system.net.HttpWebRequest]::Create($uri)
        $httpReq.Accept = "text/html, application/xhtml+xml, */*"
        $httpReq.method = "GET"   
        $httpReq.AllowAutoRedirect = $false;

        #use them all...
        #[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Ssl3 -bor [System.Net.SecurityProtocolType]::Tls;

        $global:httpCode = -1;

        $response = "";            

        try {
            $res = $httpReq.GetResponse();

            $statusCode = $res.StatusCode.ToString();
            $global:httpCode = [int]$res.StatusCode;
            $cookieC = $res.Cookies;
            $resHeaders = $res.Headers;  
            $global:rescontentLength = $res.ContentLength;
            $global:location = $null;
                                
            try {
                $global:location = $res.Headers["Location"].ToString();
                return $global:location;
            }
            catch {
            }

            return $null;

        }
        catch {
            $res2 = $_.Exception.InnerException.Response;
            $global:httpCode = $_.Exception.InnerException.HResult;
            $global:httperror = $_.exception.message;

            try {
                $global:location = $res2.Headers["Location"].ToString();
                return $global:location;
            }
            catch {
            }
        } 

        return $null;
    }

    function ReplaceTokensInFile($ht, $filePath) {
        $template = Get-Content -Raw -Path $filePath
        
        foreach ($paramName in $ht.Keys) {
            $template = $template.Replace($paramName, $ht[$paramName])
        }

        return $template;
    }

    Write-Host "------------Prerequisites------------"
    Write-Host "-An Azure Account with the ability to create Fabric Workspace."
    Write-Host "-A Power BI with Fabric License to host Power BI reports."
    Write-Host "-Make sure the user deploying the script has atleast a 'Contributor' level of access on the 'Subscription' on which it is being deployed."
    Write-Host "-Make sure your Power BI administrator can provide service principal access on your Power BI tenant."
    Write-Host "-Make sure to register the following resource providers with your Azure Subscription:"
    Write-Host "-Microsoft.Fabric"
    Write-Host "-Microsoft.EventHub"
    Write-Host "-Microsoft.SQLSever"
    Write-Host "-Microsoft.StorageAccount"
    Write-Host "-Microsoft.AppService"
    Write-Host "-Make sure you use the same valid credentials to log into Azure and Power BI."

    Write-Host "    -----------------   "
    Write-Host "    -----------------   "
    Write-Host "If you fulfill the above requirements please proceed otherwise press 'Ctrl+C' to end script execution."
    Write-Host "    -----------------   "
    Write-Host "    -----------------   "

    Start-Sleep -s 30

    az login

    $subscriptionId = (az account show --query 'id' -o tsv)
 
    #for powershell...
    Connect-AzAccount -DeviceCode -SubscriptionId $subscriptionId

    $starttime=get-date


    [string]$suffix =  -join ((48..57) + (97..122) | Get-Random -Count 7 | % {[char]$_})
    $rgName = "fabric-dpoc-$suffix"
    # $preferred_list = "australiaeast","centralus","southcentralus","eastus2","northeurope","southeastasia","uksouth","westeurope","westus","westus2"
    # $locations = Get-AzLocation | Where-Object {
    #     $_.Providers -contains "Microsoft.Synapse" -and
    #     $_.Providers -contains "Microsoft.Sql" -and
    #     $_.Providers -contains "Microsoft.Storage" -and
    #     $_.Providers -contains "Microsoft.Compute" -and
    #     $_.Location -in $preferred_list
    # }
    # $max_index = $locations.Count - 1
    # $rand = (0..$max_index) | Get-Random
    $Region = read-host "Enter the region for deployment"
    $namespaces_adx_thermostat_occupancy_name = "adx-thermostat-occupancy-$suffix"
    $sites_adx_thermostat_realtime_name = "app-realtime-kpi-analytics-$suffix"
    $serverfarm_adx_thermostat_realtime_name = "asp-realtime-kpi-analytics-$suffix"
    $subscriptionId = (Get-AzContext).Subscription.Id
    $tenantId = (Get-AzContext).Tenant.Id
    $storage_account_name = "storage$suffix"
    $mssql_server_name = "mssql$suffix"
    $mssql_database_name = "SalesDb"
    $mssql_administrator_login = "labsqladmin"
    $serverfarm_asp_fabric_name = "asp-fabric-$suffix"
    $app_fabric_name = "app-fabric-$suffix"
    $complexPassword = 0
    $sql_administrator_login_password=""
    while ($complexPassword -ne 1)
    {
        $sql_administrator_login_password = Read-Host "Enter a password to use for the $mssql_administrator_login login.
        `The password must meet complexity requirements:
        ` - Minimum 8 characters. 
        ` - At least one upper case English letter [A-Z]
        ` - At least one lower case English letter [a-z]
        ` - At least one digit [0-9]
        ` - At least one special character (!,@,#,%,^,&,$)
        ` "

        if(($sql_administrator_login_password -cmatch '[a-z]') -and ($sql_administrator_login_password -cmatch '[A-Z]') -and ($sql_administrator_login_password -match '\d') -and ($sql_administrator_login_password.length -ge 8) -and ($sql_administrator_login_password -match '!|@|#|%|^|&|$'))
        {
            $complexPassword = 1
        Write-Output "Password $sql_administrator_login_password accepted. Make sure you remember this!"
        }
        else
        {
            Write-Output "$sql_administrator_login_password does not meet the compexity requirements."
        }
    }


    $wsIdContosoSales =  Read-Host "Enter your 'contosoSales' PowerBI workspace Id "
    $wsIdContosoFinance =  Read-Host "Enter your 'contosoFinance' PowerBI workspace Id "

    RefreshTokens
    $url = "https://api.powerbi.com/v1.0/myorg/groups/$wsIdContosoSales";
    $contosoSalesWsName = Invoke-RestMethod -Uri $url -Method GET -Headers @{ Authorization="Bearer $powerbitoken" };
    $contosoSalesWsName = $contosoSalesWsName.name
    $url = "https://api.powerbi.com/v1.0/myorg/groups/$wsIdContosoFinance"
    $contosoFinanceWsName = Invoke-RestMethod -Uri $url -Method GET -Headers @{ Authorization="Bearer $powerbitoken" };
    $contosoFinanceWsName = $contosoFinanceWsName.name

    $lakehouseBronze =  "lakehouseBronze_$suffix"
    $lakehouseSilver =  "lakehouseSilver_$suffix"
    $lakehouseGold =  "lakehouseGold_$suffix"
    $lakehouseFinance = "lakehouseFinance_$suffix"
    $lakehouseSales = "Sales_Lakehouse"


    Add-Content log.txt "------FABRIC assets deployment STARTS HERE------"
    Write-Host "------------FABRIC assets deployment STARTS HERE------------"


    $spname = "Fabric Demo $suffix"

    $app = az ad app create --display-name $spname | ConvertFrom-Json
    $appId = $app.appId

    $mainAppCredential = az ad app credential reset --id $appId | ConvertFrom-Json
    $clientsecpwdapp = $mainAppCredential.password

    az ad sp create --id $appId | Out-Null    
    $sp = az ad sp show --id $appId --query "id" -o tsv
    start-sleep -s 15

    $tenantId = az account show --query tenantId -o tsv
Write-Host "Tenant ID: $tenantId"

RefreshTokens
    $url = "https://api.powerbi.com/v1.0/myorg/groups";
    $result = Invoke-WebRequest -Uri $url -Method GET -ContentType "application/json" -Headers @{ Authorization = "Bearer $powerbitoken" } -ea SilentlyContinue;
    $homeCluster = $result.Headers["home-cluster-uri"]
    #$homeCluser = "https://wabi-west-us-redirect.analysis.windows.net";

    RefreshTokens
    $url = "$homeCluster/metadata/tenantsettings"
    $post = "{`"featureSwitches`":[{`"switchId`":306,`"switchName`":`"ServicePrincipalAccess`",`"isEnabled`":true,`"isGranular`":true,`"allowedSecurityGroups`":[],`"deniedSecurityGroups`":[]}],`"properties`":[{`"tenantSettingName`":`"ServicePrincipalAccess`",`"properties`":{`"HideServicePrincipalsNotification`":`"false`"}}]}"
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", "Bearer $powerbiToken")
    $headers.Add("X-PowerBI-User-Admin", "true")
    #$result = Invoke-RestMethod -Uri $url -Method PUT -body $post -ContentType "application/json" -Headers $headers -ea SilentlyContinue;

    #add PowerBI App to workspace as an admin to group
    RefreshTokens
    $url = "https://api.powerbi.com/v1.0/myorg/groups/$wsIdContosoSales/users";
    $post = "{
    `"identifier`":`"$($sp)`",
    `"groupUserAccessRight`":`"Admin`",
    `"principalType`":`"App`"
    }";

    $result = Invoke-RestMethod -Uri $url -Method POST -body $post -ContentType "application/json" -Headers @{ Authorization = "Bearer $powerbitoken" } -ea SilentlyContinue;

    #get the power bi app...
    $powerBIApp = Get-AzADServicePrincipal -DisplayNameBeginsWith "Power BI Service"
    $powerBiAppId = $powerBIApp.Id;

    #setup powerBI app...
    RefreshTokens
    $url = "https://graph.microsoft.com/beta/OAuth2PermissionGrants";
    $post = "{
    `"clientId`":`"$appId`",
    `"consentType`":`"AllPrincipals`",
    `"resourceId`":`"$powerBiAppId`",
    `"scope`":`"Dataset.ReadWrite.All Dashboard.Read.All Report.Read.All Group.Read Group.Read.All Content.Create Metadata.View_Any Dataset.Read.All Data.Alter_Any`",
    `"expiryTime`":`"2021-03-29T14:35:32.4943409+03:00`",
    `"startTime`":`"2020-03-29T14:35:32.4933413+03:00`"
    }";

    $result = Invoke-RestMethod -Uri $url -Method GET -ContentType "application/json" -Headers @{ Authorization = "Bearer $graphtoken" } -ea SilentlyContinue;

    #setup powerBI app...
    RefreshTokens
    $url = "https://graph.microsoft.com/beta/OAuth2PermissionGrants";
    $post = "{
    `"clientId`":`"$appId`",
    `"consentType`":`"AllPrincipals`",
    `"resourceId`":`"$powerBiAppId`",
    `"scope`":`"User.Read Directory.AccessAsUser.All`",
    `"expiryTime`":`"2021-03-29T14:35:32.4943409+03:00`",
    `"startTime`":`"2020-03-29T14:35:32.4933413+03:00`"
    }";

    $result = Invoke-RestMethod -Uri $url -Method GET -ContentType "application/json" -Headers @{ Authorization = "Bearer $graphtoken" } -ea SilentlyContinue;

    $credential = New-Object PSCredential($appId, (ConvertTo-SecureString $clientsecpwdapp -AsPlainText -Force))

    # Connect to Power BI using the service principal
    Connect-PowerBIServiceAccount -ServicePrincipal -Credential $credential -TenantId $tenantId

    pip install --user --upgrade pip setuptools
    pip install --user packaging  # Packaging is required by ansible-core
    pip install --user cryptography
    pip install --user ms-fabric-cli


    fab config set encryption_fallback_enabled true
    fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

$financeworkspacePath = "$contosoFinanceWsName.Workspace"

# 3. Pass it to `fab cd`
fab cd $financeworkspacePath
fab mkdir $financeworkspacePath/lakehouseFinance_$suffix.Lakehouse
# 2. Use the variable with .Workspace suffix to match fab's friendly name
$salesworkspacePath = "$contosoSalesWsName.Workspace"

# 3. Pass it to `fab cd`
fab cd $salesworkspacePath

fab mkdir $salesworkspacePath/lakehouseBronze_$suffix.Lakehouse
fab mkdir $salesworkspacePath/lakehouseSilver_$suffix.Lakehouse
fab mkdir $salesworkspacePath/lakehouseGold_$suffix.Lakehouse
fab mkdir $salesworkspacePath/Sales_Lakehouse1.Lakehouse

Write-Host "-----Creation of Lakehouse in '$contosoFinanceWsName' workspace COMPLETED------"

$warehousename = "salesDW_$suffix"
fab mkdir $salesworkspacePath/$warehousename.warehouse

Write-Host "-----------Creation of Warehouse COMPLETED------------"

Write-Host "-----------Creation of Eventstream Started------------"

$eventStreamName = "ThermostatEventStream_$suffix"
$eventStreamPath = "$salesworkspacePath/$eventStreamName.eventstream"

fab mkdir $eventStreamPath

Write-Host "-----------Creation of Eventstream COMPLETED------------"

Write-Host "------Creating Eventhouse------"
$KQLDB = "Contoso-Eventhouse"
fab mkdir $salesworkspacePath/$KQLDB.eventhouse

Write-Host "------Creating Eventhouse completed------"

  
    Add-Content log.txt "------Uploading assets to Lakehouses------"
    Write-Host "------------Uploading assets to Lakehouses------------"
    $tenantId = (Get-AzContext).Tenant.Id
    azcopy login --tenant-id $tenantId

    azcopy copy "https://fabric2dpoc.blob.core.windows.net/bronzelakehousefiles/*" "https://onelake.blob.fabric.microsoft.com/$contosoSalesWsName/$lakehouseBronze.Lakehouse/Files/" --overwrite=prompt --from-to=BlobBlob --s2s-preserve-access-tier=false --check-length=true --include-directory-stub=false --s2s-preserve-blob-tags=false --recursive --trusted-microsoft-suffixes=onelake.blob.fabric.microsoft.com --log-level=INFO;
    azcopy copy "https://fabric2dpoc.blob.core.windows.net/bronzelakehousetables/*" "https://onelake.blob.fabric.microsoft.com/$contosoSalesWsName/$lakehouseBronze.Lakehouse/Tables/" --overwrite=prompt --from-to=BlobBlob --s2s-preserve-access-tier=false --check-length=true --include-directory-stub=false --s2s-preserve-blob-tags=false --recursive --trusted-microsoft-suffixes=onelake.blob.fabric.microsoft.com --log-level=INFO;
    azcopy copy "https://fabric2dpoc.blob.core.windows.net/silverlakehousetables/*" "https://onelake.blob.fabric.microsoft.com/$contosoSalesWsName/$lakehouseSilver.Lakehouse/Tables/" --overwrite=prompt --from-to=BlobBlob --s2s-preserve-access-tier=false --check-length=true --include-directory-stub=false --s2s-preserve-blob-tags=false --recursive --trusted-microsoft-suffixes=onelake.blob.fabric.microsoft.com --log-level=INFO;
    azcopy copy "https://fabric2dpoc.blob.core.windows.net/silverlakehousefiles/*" "https://onelake.blob.fabric.microsoft.com/$contosoSalesWsName/$lakehouseSilver.Lakehouse/Files/" --overwrite=prompt --from-to=BlobBlob --s2s-preserve-access-tier=false --check-length=true --include-directory-stub=false --s2s-preserve-blob-tags=false --recursive --trusted-microsoft-suffixes=onelake.blob.fabric.microsoft.com --log-level=INFO;
    azcopy copy "https://fabric2dpoc.blob.core.windows.net/financedata/*" "https://onelake.blob.fabric.microsoft.com/$contosoFinanceWsName/$lakehouseFinance.Lakehouse/Files/" --overwrite=prompt --from-to=BlobBlob --s2s-preserve-access-tier=false --check-length=true --include-directory-stub=false --s2s-preserve-blob-tags=false --recursive --trusted-microsoft-suffixes=onelake.blob.fabric.microsoft.com --log-level=INFO;

    #azcopy copy "https://fabricddib.blob.core.windows.net/goldlakehousetables/*" "https://onelake.blob.fabric.microsoft.com/$contosoSalesWsName/$lakehouseGold.Lakehouse/Tables/" --overwrite=prompt --from-to=BlobBlob --s2s-preserve-access-tier=false --check-length=true --include-directory-stub=false --s2s-preserve-blob-tags=false --recursive --trusted-microsoft-suffixes=onelake.blob.fabric.microsoft.com --log-level=INFO;

    Add-Content log.txt "------Uploading assets to Lakehouses COMPLETED------"
    Write-Host "------------Uploading assets to Lakehouses COMPLETED------------"


    ## notebooks
    Add-Content log.txt "-----Configuring Fabric Notebooks w.r.t. current workspace and lakehouses-----"
    Write-Host "----Configuring Fabric Notebooks w.r.t. current workspace and lakehouses----"

    (Get-Content -path "artifacts/fabricnotebooks/01 Marketing Data to Lakehouse (Bronze) - Code-First Experience.ipynb" -Raw) | Foreach-Object { $_ `
        -replace '#SALES_WORKSPACE_NAME#', $contosoSalesWsName `
        -replace '#LAKEHOUSE_BRONZE#', $lakehouseBronze `
    } | Set-Content -Path "artifacts/fabricnotebooks/01 Marketing Data to Lakehouse (Bronze) - Code-First Experience.ipynb"

    (Get-Content -path "artifacts/fabricnotebooks/02 Bronze to Silver layer_ Medallion Architecture.ipynb" -Raw) | Foreach-Object { $_ `
        -replace '#SALES_WORKSPACE_NAME#', $contosoSalesWsName `
        -replace '#LAKEHOUSE_BRONZE#', $lakehouseBronze `
        -replace '#LAKEHOUSE_SILVER#', $lakehouseSilver `
    } | Set-Content -Path "artifacts/fabricnotebooks/02 Bronze to Silver layer_ Medallion Architecture.ipynb"

    (Get-Content -path "artifacts/fabricnotebooks/03 Silver to Gold layer_ Medallion Architecture.ipynb" -Raw) | Foreach-Object { $_ `
        -replace '#LAKEHOUSE_GOLD#', $lakehouseGold `
        -replace '_LAKEHOUSE_GOLD_', $lakehouseGold `
    } | Set-Content -Path "artifacts/fabricnotebooks/03 Silver to Gold layer_ Medallion Architecture.ipynb"

    (Get-Content -path "artifacts/fabricnotebooks/04 Churn Prediction Using MLFlow From Silver To Gold Layer.ipynb" -Raw) | Foreach-Object { $_ `
        -replace '#LAKEHOUSE_SILVER#', $lakehouseSilver `
        -replace '#LAKEHOUSE_GOLD#', $lakehouseGold `
    } | Set-Content -Path "artifacts/fabricnotebooks/04 Churn Prediction Using MLFlow From Silver To Gold Layer.ipynb"

    (Get-Content -path "artifacts/fabricnotebooks/05 Sales Forecasting for Store items in Gold Layer.ipynb" -Raw) | Foreach-Object { $_ `
        -replace '#LAKEHOUSE_SILVER#', $lakehouseSilver `
        -replace '#LAKEHOUSE_GOLD#', $lakehouseGold `
    } | Set-Content -Path "artifacts/fabricnotebooks/05 Sales Forecasting for Store items in Gold Layer.ipynb"

    Add-Content log.txt "-----Fabric Notebook Configuration COMPLETED-----"
    Write-Host "----Fabric Notebook Configuration COMPLETED----"

    Add-Content log.txt "-----Uploading Notebooks-----"
    Write-Host "-----Uploading Notebooks-----"
    RefreshTokens
     $requestHeaders = @{
         Authorization  = "Bearer " + $fabric
         "Content-Type" = "application/json"
         "Scope"        = "Notebook.ReadWrite.All"
     }


    $files = Get-ChildItem -Path "./artifacts/fabricnotebooks" -File -Recurse
    Set-Location ./artifacts/fabricnotebooks
    
    foreach ($name in $files.name) {
    if ($name -eq "01 Marketing Data to Lakehouse (Bronze) - Code-First Experience.ipynb" -or
        $name -eq "02 Bronze to Silver layer_ Medallion Architecture.ipynb" -or
        $name -eq "03 Silver to Gold layer_ Medallion Architecture.ipynb") {
        
        $fileContent = Get-Content -Raw $name
        $fileContentBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)
        $fileContentEncoded = [System.Convert]::ToBase64String($fileContentBytes)

        $body = '{
            "displayName": "' + $name + '",
            "type": "Notebook",
            "definition": {
                "format": "ipynb",
                "parts": [
                    {
                        "path": "artifact.content.ipynb",
                        "payload": "' + $fileContentEncoded + '",
                        "payloadType": "InlineBase64"
                    }
                ]
            }
        }'

        $endPoint = "https://api.fabric.microsoft.com/v1/workspaces/$wsIdContosoSales/items/"

        $Lakehouse = Invoke-RestMethod $endPoint -Method POST -Headers $requestHeaders -Body $body

        Write-Host "Notebook uploaded: $name"
    } elseif ($name -eq "04 Churn Prediction Using MLFlow From Silver To Gold Layer.ipynb" -or
            $name -eq "05 Sales Forecasting for Store items in Gold Layer.ipynb" -or 
            $name -eq "Generate realtime thermostat data.ipynb") {
        
        $fileContent = Get-Content -Raw $name
        $fileContentBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)
        $fileContentEncoded = [System.Convert]::ToBase64String($fileContentBytes)

        $body = '{
            "displayName": "' + $name + '",
            "type": "Notebook",
            "definition": {
                "format": "ipynb",
                "parts": [
                    {
                        "path": "artifact.content.ipynb",
                        "payload": "' + $fileContentEncoded + '",
                        "payloadType": "InlineBase64"
                    }
                ]
            }
        }'

        $endPoint = "https://api.fabric.microsoft.com/v1/workspaces/$wsIdContosoSales/items/"
        $Lakehouse = Invoke-RestMethod $endPoint -Method POST -Headers $requestHeaders -Body $body

        Write-Host "Notebook uploaded: $name"
        }
    }
    Add-Content log.txt "-----Uploading Notebooks COMPLETED-----"
    Write-Host "-----Uploading Notebooks COMPLETED-----"

    cd..
    cd..
    
    RefreshTokens
     $requestHeaders = @{
         Authorization  = "Bearer " + $fabric
         "Content-Type" = "application/json"
         "Scope"        = "Notebook.ReadWrite.All"
     }


# Internal shortcut in fabric 2.0:

# Define lakehouse paths
$goldLakehouse = "$salesworkspacePath/$lakehouseGold.Lakehouse/Tables"
$silverLakehouse = "$salesworkspacePath/$lakehouseSilver.Lakehouse/Tables"

fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

# Tables to shortcut
$tables = @(
    "dimension_date",
    "dimension_product",
    "dimension_customer",
    "fact_sales",
    "fact_campaigndata"
)

# Create shortcuts

foreach ($table in $tables) {
    Write-Host "Creating Shortcut for $table"

    $shortcutPath = "$goldLakehouse/$table.Shortcut"
    $targetPath = "$silverLakehouse/$table"

    fab ln $shortcutPath --type oneLake --target $targetPath
    Write-Host "✅ Shortcut created: $table"
}   


    Write-Host "Creating $rgName resource group in $Region ..."
    New-AzResourceGroup -Name $rgName -Location $Region | Out-Null
    Write-Host "Resource group $rgName creation COMPLETE"

    Write-Host "Creating resources in $rgName..."
    New-AzResourceGroupDeployment -ResourceGroupName $rgName `
    -TemplateFile "mainTemplate.json" `
    -Mode Complete `
    -location $Region `
    -storage_account_name $storage_account_name `
    -mssql_server_name $mssql_server_name `
    -mssql_database_name $mssql_database_name `
    -mssql_administrator_login $mssql_administrator_login `
    -sql_administrator_login_password $sql_administrator_login_password `
    -serverfarm_asp_fabric_name $serverfarm_asp_fabric_name `
    -app_fabric_name $app_fabric_name `
    -Force

    Write-Host "Resource creation in $rgName resource group COMPLETE"

    $thermostat_telemetry_Realtime_URL =  ""
    $occupancy_data_Realtime_URL =  ""

    #Adding tags
    $tags = @{
        "wsIdContosoSales" = $wsIdContosoSales
        "wsIdContosoFinance" = $wsIdContosoFinance
    }
    Set-AzResourceGroup -ResourceGroupName $rgName -Tag $tags

    Add-Content log.txt "------Fetching az copy library------"
    Write-Host "------------Fetching az copy library------------"

    #download azcopy command
    if ([System.Environment]::OSVersion.Platform -eq "Unix") {
        $azCopyLink = Check-HttpRedirect "https://aka.ms/downloadazcopy-v10-linux"

        if (!$azCopyLink) {
            $azCopyLink = "https://azcopyvnext.azureedge.net/release20200709/azcopy_linux_amd64_10.5.0.tar.gz"
        }

        Invoke-WebRequest $azCopyLink -OutFile "azCopy.tar.gz"
        tar -xf "azCopy.tar.gz"
        $azCopyCommand = (Get-ChildItem -Path ".\" -Recurse azcopy).Directory.FullName

        if ($azCopyCommand.count -gt 1) {
            $azCopyCommand = $azCopyCommand[0];
        }

        cd $azCopyCommand
        chmod +x azcopy
        cd ..
        $azCopyCommand += "\azcopy"
    } else {
        $azCopyLink = Check-HttpRedirect "https://aka.ms/downloadazcopy-v10-windows"

        if (!$azCopyLink) {
            $azCopyLink = "https://azcopyvnext.azureedge.net/release20200501/azcopy_windows_amd64_10.4.3.zip"
        }

        Invoke-WebRequest $azCopyLink -OutFile "azCopy.zip"
        Expand-Archive "azCopy.zip" -DestinationPath ".\" -Force
        $azCopyCommand = (Get-ChildItem -Path ".\" -Recurse azcopy.exe).Directory.FullName

        if ($azCopyCommand.count -gt 1) {
            $azCopyCommand = $azCopyCommand[0];
        }

        $azCopyCommand += "\azcopy"
    }


    Add-Content log.txt "------Fetching az copy library COMPLETED------"
    Write-Host "------------Fetching az copy library COMPLETED------------"

    Add-Content log.txt "------Copying assets to the Storage Account------"
    Write-Host "------------Copying assets to the Storage Account------------"

    ## storage AZ Copy
    $storage_account_key = (Get-AzStorageAccountKey -ResourceGroupName $rgName -AccountName $storage_account_name)[0].Value
    $dataLakeContext = New-AzStorageContext -StorageAccountName $storage_account_name -StorageAccountKey $storage_account_key

    $destinationSasKey = New-AzStorageContainerSASToken -Container "bronzeshortcutdata" -Context $dataLakeContext -Permission rwdl
    if (-not $destinationSasKey.StartsWith('?')) { $destinationSasKey = "?$destinationSasKey"}
    $destinationUri = "https://$($storage_account_name).blob.core.windows.net/bronzeshortcutdata$($destinationSasKey)"
    & $azCopyCommand copy "https://fabric2dpoc.blob.core.windows.net/bronzeshortcutdata/" $destinationUri --recursive

    $destinationSasKey = New-AzStorageContainerSASToken -Container "data-source" -Context $dataLakeContext -Permission rwdl
    if (-not $destinationSasKey.StartsWith('?')) { $destinationSasKey = "?$destinationSasKey"}
    $destinationUri = "https://$($storage_account_name).blob.core.windows.net/data-source$($destinationSasKey)"
    & $azCopyCommand copy "https://fabric2dpoc.blob.core.windows.net/data-source/" $destinationUri --recursive

    $destinationSasKey = New-AzStorageContainerSASToken -Container "webappassets" -Context $dataLakeContext -Permission rwdl
    if (-not $destinationSasKey.StartsWith('?')) { $destinationSasKey = "?$destinationSasKey"}
    $destinationUri = "https://$($storage_account_name).blob.core.windows.net/webappassets$($destinationSasKey)"
    & $azCopyCommand copy "https://fabric2dpoc.blob.core.windows.net/webappassets/" $destinationUri --recursive

    $destinationSasKey = New-AzStorageContainerSASToken -Container "personas" -Context $dataLakeContext -Permission rwdl
    if (-not $destinationSasKey.StartsWith('?')) { $destinationSasKey = "?$destinationSasKey"}
    $destinationUri = "https://$($storage_account_name).blob.core.windows.net/personas$($destinationSasKey)"
    & $azCopyCommand copy "https://fabric2dpoc.blob.core.windows.net/personas/" $destinationUri --recursive

    $destinationSasKey = New-AzStorageContainerSASToken -Container "kqldata" -Context $dataLakeContext -Permission rwdl
    if (-not $destinationSasKey.StartsWith('?')) { $destinationSasKey = "?$destinationSasKey"}
    $destinationUri = "https://$($storage_account_name).blob.core.windows.net/kqldata$($destinationSasKey)"
    & $azCopyCommand copy "https://fabric2dpoc.blob.core.windows.net/kqldata/" $destinationUri --recursive

    Add-Content log.txt "------Copying assets to the Storage Account COMPLETED------"
    Write-Host "------------Copying assets to the Storage Account COMPLETED------------"

    ##Assigning SP as Storage Blob Data Contributor
    Add-Content log.txt "------Assigning SP as Storage Blob Data Contributor------"

az role assignment create --assignee $appId --role "Storage Blob Data Contributor" --scope "/subscriptions/$subscriptionId/resourceGroups/$rgname"


    ##Fabric continues


    RefreshTokens
     $requestHeaders = @{
         Authorization  = "Bearer " + $fabric
         "Content-Type" = "application/json"
         "Scope"        = "Notebook.ReadWrite.All"
     }

     
## Get Lakehouse details
$endPoint = "https://api.fabric.microsoft.com/v1/workspaces/$wsIdContosoSales/lakehouses"
    $Lakehouse = Invoke-RestMethod $endPoint `
        -Method GET `
        -Headers $requestHeaders



# Get the ID of the  lakehouse 
# $LakehouseId = $Lakehouse.value[0].id  # or use a filter:
$LakehouseSilverId = ($Lakehouse.value | Where-Object { $_.displayName -eq "$lakehouseSilver" }).id
$LakehouseGoldId = ($Lakehouse.value | Where-Object { $_.displayName -eq "$lakehouseGold" }).id
$LakehouseBronzeId = ($Lakehouse.value | Where-Object { $_.displayName -eq "$lakehouseBronze" }).id

Write-Output "Lakehouse ID: $LakehouseSilverId"
Write-Output "Lakehouse ID: $LakehouseGoldId"
Write-Output "Lakehouse ID: $LakehouseBronzeId"


## ADLS Gen 2 Shortcut

fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

# Assign values (replace as needed)
$connectionName = ".connections/adlsgen2fabcli$suffix.Connection"
$serverUrl = "https://$storage_account_name.dfs.core.windows.net"
$path = "bronzeshortcutdata"

# Build param string
$params = @(
    "connectionDetails.type=AzureDataLakeStorage",
    "connectionDetails.parameters.server=$serverUrl",
    "connectionDetails.parameters.path=$path",
    "credentialDetails.type=ServicePrincipal",
    "credentialDetails.servicePrincipalClientId=$appId",
    "credentialDetails.servicePrincipalSecret=$clientsecpwdapp",
    "credentialDetails.tenantId=$tenantId",
    "privacyLevel=Organizational"
) -join ","

# Final command
fab create $connectionName -P $params

$connectionId = (fab ls .connections -l | Where-Object { $_ -match "adlsgen2fabcli$suffix.Connection" } | ForEach-Object { ($_ -split '\s+')[1] })
$BronzeLakehousepath = "$salesworkspacePath/$lakehouseBronze.Lakehouse/Files"
$shortcutPath = "$BronzeLakehousepath/sales-transaction-litware.shortcut"
$jsonInput = @{
    location = "https://$storage_account_name.dfs.core.windows.net/"
    subpath = "bronzeshortcutdata"
    connectionId = $connectionId
} | ConvertTo-Json -Compress

fab ln $shortcutPath --type adlsGen2 -i $jsonInput


fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

$notebookPath1 = "$salesworkspacePath/01 Marketing Data to Lakehouse (Bronze) - Code-First Experience.ipynb.Notebook"

# Build the JSON input string
$jsonInput = @{
    known_lakehouses = @(@{ id = $LakehouseBronzeId })
    default_lakehouse = $LakehouseBronzeId
    default_lakehouse_name = $lakehouseBronze
    default_lakehouse_workspace_id = $wsIdContosoSales
} | ConvertTo-Json -Compress

# Run the fab set command
fab set "$notebookPath1" -q lakehouse -i $jsonInput -f

fab job run "$salesworkspacePath/01 Marketing Data to Lakehouse (Bronze) - Code-First Experience.ipynb.Notebook"

fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

$notebookPath2 = "$salesworkspacePath/02 Bronze to Silver layer_ Medallion Architecture.ipynb.Notebook"

# Build the JSON input string
$jsonInput = @{
    known_lakehouses = @(@{ id = $LakehouseSilverId })
    default_lakehouse = $LakehouseSilverId
    default_lakehouse_name = $lakehouseSilver
    default_lakehouse_workspace_id = $wsIdContosoSales
} | ConvertTo-Json -Compress

# Run the fab set command
fab set "$notebookPath2" -q lakehouse -i $jsonInput -f

fab job run "$salesworkspacePath/02 Bronze to Silver layer_ Medallion Architecture.ipynb.Notebook"

fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

$notebookPath3 = "$salesworkspacePath/03 Silver to Gold layer_ Medallion Architecture.ipynb.Notebook"

# Build the JSON input string
$jsonInput = @{
    known_lakehouses = @(@{ id = $LakehouseGoldId })
    default_lakehouse = $LakehouseGoldId
    default_lakehouse_name = $lakehouseGold
    default_lakehouse_workspace_id = $wsIdContosoSales
} | ConvertTo-Json -Compress

# Run the fab set command
fab set "$notebookPath3" -q lakehouse -i $jsonInput -f

fab job run "$salesworkspacePath/03 Silver to Gold layer_ Medallion Architecture.ipynb.Notebook"

fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

$notebookPath4 = "$salesworkspacePath/04 Churn Prediction Using MLFlow From Silver To Gold Layer.ipynb.Notebook"

# Build the JSON input string
$jsonInput4 = @{
    known_lakehouses = @(@{ id = $LakehouseSilverId })
    default_lakehouse = $LakehouseSilverId
    default_lakehouse_name = $lakehouseSilver
    default_lakehouse_workspace_id = $wsIdContosoSales
} | ConvertTo-Json -Compress

# Run the fab set command
fab set "$notebookPath4" -q lakehouse -i $jsonInput4 -f

# fab job run "$salesworkspacePath/04 Churn Prediction Using MLFlow From Silver To Gold Layer.ipynb.Notebook"

fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

$notebookPath5 = "$salesworkspacePath/05 Sales Forecasting for Store items in Gold Layer.ipynb.Notebook"


$jsonInput = @{
    known_lakehouses = @(@{ id = $LakehouseSilverId })
    default_lakehouse = $LakehouseSilverId
    default_lakehouse_name = $lakehouseSilver
    default_lakehouse_workspace_id = $wsIdContosoSales
} | ConvertTo-Json -Compress

fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

fab set "$notebookPath5" -q lakehouse -i $jsonInput -f
fab job run "$salesworkspacePath/05 Sales Forecasting for Store items in Gold Layer.ipynb.Notebook"

    Add-Content log.txt "------Uploading PowerBI Reports------"
    Write-Host "------------Uploading PowerBI Reports------------"

    #https://docs.microsoft.com/en-us/power-bi/developer/embedded/embed-service-principal
    #Allow service principals to user PowerBI APIS must be enabled - https://app.powerbi.com/admin-portal/tenantSettings?language=en-U
    #add PowerBI App to workspace as an admin to group
    
    
    $PowerBIFiles = Get-ChildItem "./artifacts/reports" -Recurse -Filter *.pbix
    $reportList = @()

    foreach ($Pbix in $PowerBIFiles) {
    Write-Output "Uploading report: $($Pbix.BaseName +'.pbix')"

    $report = New-PowerBIReport -Path $Pbix.FullName -WorkspaceId $wsIdContosoSales -ConflictAction CreateOrOverwrite

    if ($report -ne $null) {
        Write-Output "Report uploaded successfully: $($report.Name +'.pbix')"

        $temp = [PSCustomObject]@{
            FileName        = $Pbix.FullName
            Name            = $Pbix.BaseName  # Using BaseName to get the file name without the extension
            PowerBIDataSetId = $null
            ReportId        = $report.Id
            SourceServer    = $null
            SourceDatabase  = $null
        }

        # Get dataset
        $url = "https://api.powerbi.com/v1.0/myorg/groups/$wsIdContosoSales/datasets"
        $dataSets = Invoke-RestMethod -Uri $url -Method GET -Headers @{ Authorization="Bearer $powerbitoken" }

        foreach ($res in $dataSets.value) {
            if ($res.name -eq $temp.Name) {
                $temp.PowerBIDataSetId = $res.id
                break  # Exit the loop once a match is found
            }
        }

        $reportList += $temp
    } else {
        Write-Output "Failed to upload report: $($report.Name +'.pbix')"
        }
    }
    Add-Content log.txt "------Uploading PowerBI Reports COMPLETED------"
    Write-Host "------------Uploading PowerBI Reports COMPLETED------------"

    Start-Sleep -s 10

    Add-Content log.txt "------FABRIC assets deployment DONE------"
    Write-Host "------------FABRIC assets deployment DONE------------"

    Add-Content log.txt "------AZURE assets deployment STARTS HERE------"
    Write-Host "------------AZURE assets deployment STARTS HERE------------"


    ## mssql
    Add-Content log.txt "------Copying assets to the Azure SQL Server------"
    Write-Host "------------Copying assets to the Azure SQL Server------------"
    $SQLScriptsPath="./artifacts/sqlscripts"
    $sqlQuery = Get-Content -Raw -Path "$($SQLScriptsPath)/salesSqlDbScript.sql"
    $sqlEndpoint="$($mssql_server_name).database.windows.net"
    $result=Invoke-SqlCmd -Query $sqlQuery -ServerInstance $sqlEndpoint -Database $mssql_database_name -Username $mssql_administrator_login -Password $sql_administrator_login_password
    Add-Content log.txt $result
    Add-Content log.txt "------Copying assets to the Azure SQL Server COMPLETED------"
    Write-Host "------------Copying assets to the Azure SQL Server COMPLETED------------"

Write-Host "---creating SQL Connection, Data Pipelines"
    # Parameters for the API request

 RefreshTokens   

$uri = "https://api.fabric.microsoft.com/v1/connections"
$headers = @{
    Authorization = "Bearer $fabric"
    "Content-Type"  = "application/json"
}
$body = @{
    connectivityType = "ShareableCloud"
    displayName      = "Mirroredsqlconnection-$suffix"
    connectionDetails = @{
        type           = "SQL"
        creationMethod = "SQL"
        parameters     = @(
            @{
                dataType = "Text"
                name     = "server"
                value    = "$($mssql_server_name).database.windows.net"
            },
            @{
                dataType = "Text"
                name     = "database"
                value    = "$mssql_database_name"
            }
        )
    }
    privacyLevel     = "Organizational"
    credentialDetails = @{
        singleSignOnType   = "None"
        connectionEncryption = "NotEncrypted"
        skipTestConnection = $false
        credentials = @{
            credentialType = "Basic"
            username       = "$mssql_administrator_login"
            password       = "$sql_administrator_login_password" # Replace with your actual password
        }
    }
}
# Convert the body to JSON
$bodyJson = $body | ConvertTo-Json -Depth 10
# Make the POST request
$response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $bodyJson
$connection = $response.id                                            
Write-Output "Connection ID: $connection"

RefreshTokens

Write-Host " ---------Setting up the Data Pipelines ------------"

    RefreshTokens
     $requestHeaders = @{
         Authorization  = "Bearer " + $fabric
         "Content-Type" = "application/json"
         "Scope"        = "Notebook.ReadWrite.All"
     }
## Get Warehouse details
$endPoint = "https://api.fabric.microsoft.com/v1/workspaces/$wsIdContosoSales/warehouses"
    $Warehouse = Invoke-RestMethod $endPoint `
        -Method GET `
        -Headers $requestHeaders 

$Warehouseid = $Warehouse.value.id
$Warehouseconnectionstring = $Warehouse.value.properties.connectionString

## Replace values in pipeline.json

(Get-Content -path "artifacts/pipelines/pipeline-content.json" -Raw) | Foreach-Object { $_ `
        -replace '#salessqldbconnectionid#', $connection `
        -replace '#warehousename#', $warehousename `
        -replace '#datawarehouseendpoint#', $Warehouseconnectionstring `
        -replace '#warehouseid#', $Warehouseid `
        -replace '#wsid#', $wsIdContosoSales `
    } | Set-Content -Path "artifacts/pipelines/pipeline-content.json"

$files = Get-ChildItem -Path "./artifacts/pipelines" -File -Recurse
Set-Location ./artifacts/pipelines

$pat_token = $fabric
    $requestHeaders = @{
        Authorization  = "Bearer" + " " + $pat_token
        "Content-Type" = "application/json"
        "Scope"        = "DataPipeline.ReadWrite.All"
    }


# Set the file name
$name = "pipeline-content.json"

if ($name -eq "pipeline-content.json") {

    # Read the JSON content of the pipeline file
    $fileContent = Get-Content -Raw $name
    $fileContentBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)
    $fileContentEncoded = [System.Convert]::ToBase64String($fileContentBytes)

    # Construct request body for Pipeline
    $body = '{
        "displayName": "02 Sales data from Azure SQL DB to Data Warehouse - Low Code Experience",
        "definition": {
            "parts": [
                {
                    "path": "pipeline-content.json",
                    "payload": "' + $fileContentEncoded + '",
                    "payloadType": "InlineBase64"
                }
            ]
        }
    }'

    # POST to Fabric API
    $endPoint = "https://api.fabric.microsoft.com/v1/workspaces/$wsIdContosoSales/dataPipelines"
    $pipelineResult = Invoke-RestMethod $endPoint -Method POST -Headers $requestHeaders -Body $body

    Write-Host "Pipeline uploaded: $name"
}

Write-Host " ---------Data Pipelines setup complete------------"

cd..
cd..

fab auth login --username $appId --password $clientsecpwdapp --tenant $tenantId

fab job run "$salesworkspacePath/02 Sales data from Azure SQL DB to Data Warehouse - Low Code Experience.DataPipeline"


# # Get the storage account context
# $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName
# $ctx = $storageAccount.Context
# $expiryTime = (Get-Date  -Format "yyyy-MM-ddTHH:mm:ssZ")                     
# $startTime = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")

# # Generate SAS token
# $sasToken = New-AzStorageAccountSASToken `
#     -Service Blob,File,Queue,Table `
#     -ResourceType Container `
#     -Permission rlw `
#     -StartTime $startTime `
#     -ExpiryTime $expiryTime `
#     -Context $ctx

# # Output SAS Token
# Write-Host "`n✅ SAS Token:" $sasToken

# (Get-Content -path "artifacts/warehousescripts/00 Ingest Data In DW Using COPY INTO Command.sql" -Raw) | Foreach-Object { $_ `
#         -replace '#STORAGE_ACCOUNT_NAME#', $storage_account_name `
#         -replace '#STORAGE_ACCOUNT_SAS_TOKEN#', $sasToken `

#     } | Set-Content -Path "artifacts/warehousescripts/00 Ingest Data In DW Using COPY INTO Command.sql"

    #Web app
    Add-Content log.txt "------Deploying Web Apps------"
    Write-Host  "----------------Deploying Web Apps---------------"
    RefreshTokens

    $zips = @("app-fabric-2")
    foreach($zip in $zips)
    {
        expand-archive -path "./artifacts/binaries/$($zip).zip" -destinationpath "./$($zip)" -force
    }

    (Get-Content -path app-fabric-2/appsettings.json -Raw) | Foreach-Object { $_ `
            -replace '#WORKSPACE_ID#', $wsIdContosoSales`
            -replace '#APP_ID#', $appId`
            -replace '#APP_SECRET#', $clientsecpwdapp`
            -replace '#TENANT_ID#', $tenantId`
    } | Set-Content -Path app-fabric-2/appsettings.json

    $filepath = "./app-fabric-2/wwwroot/environment.js"
    $itemTemplate = Get-Content -Path $filepath
    $item = $itemTemplate.Replace("#STORAGE_ACCOUNT_NAME#", $storage_account_name).Replace("#SERVER_NAME#", $app_fabric_name).Replace("#WORKSPACE_ID#", $wsIdContosoSales)
    Set-Content -Path $filepath -Value $item

    RefreshTokens
    $url = "https://api.powerbi.com/v1.0/myorg/groups/$wsIdContosoSales/reports";
    $reportList = Invoke-RestMethod -Uri $url -Method GET -Headers @{ Authorization = "Bearer $powerbitoken" };
    $reportList = $reportList.Value

    #update all th report ids in the poc web app...
    $ht = new-object system.collections.hashtable   
    # $ht.add("#Bing_Map_Key#", "AhBNZSn-fKVSNUE5xYFbW_qajVAZwWYc8OoSHlH8nmchGuDI6ykzYjrtbwuNSrR8")
    $ht.add("#07_Campaign_Analytics_Report_with_Lakehouse#", $($reportList | where { $_.name -eq "01 Campaign Analytics Report with Lakehouse" }).id)
    $ht.add("#09_Sales_Analytics_Report_with_Warehouse#", $($reportList | where { $_.name -eq "02 Sales Analytics Report with Warehouse" }).id)
    $ht.add("#Contoso_Finance_Report#", $($reportList | where { $_.name -eq "03 Contoso Finance Report" }).id)
    $ht.add("#HR_Analytics_Report_Lakehouse#", $($reportList | where { $_.name -eq "05 HR Analytics Report Lakehouse" }).id)
    $ht.add("#IT_Report#", $($reportList | where { $_.name -eq "06 IT Report" }).id)
    $ht.add("#Marketing_Report#", $($reportList | where { $_.name -eq "07 Marketing Report" }).id)
    $ht.add("#Operations_Report#", $($reportList | where { $_.name -eq "08 Operations Report" }).id)
    $ht.add("#Group_CEO_KPI_Fabric_AML#", $($reportList | where { $_.name -eq "04 Group CEO KPI Fabric+AML" }).id)
    $ht.add("#Score_Cards_Report#", $($reportList | where { $_.name -eq "09 Score Cards Report" }).id)
    $ht.add("#WORLD_MAP#", $($reportList | where { $_.name -eq "10 World Map (Trident)" }).id)

    $filePath = "./app-fabric-2/wwwroot/environment.js";
    Set-Content $filePath $(ReplaceTokensInFile $ht $filePath)

    Compress-Archive -Path "./app-fabric-2/*" -DestinationPath "./app-fabric-2.zip" -Update

    # fetching authentication token
    $TOKEN = az account get-access-token --query accessToken | tr -d '"'

    az webapp stop --name $app_fabric_name --resource-group $rgName
    try {
        # Publish-AzWebApp -ResourceGroupName $rgName -Name $sites_adx_therm -ArchivePath ./artifacts/binaries/app-adx-thermostat-realtime.zip -Force
        $deployment = curl -X POST -H "Authorization: Bearer $TOKEN" -T "./app-fabric-2.zip" "https://$app_fabric_name.scm.azurewebsites.net/api/publish?type=zip"
    }
    catch {
    }

    az webapp start --name $app_fabric_name --resource-group $rgName

    # # ADX Thermostat Realtime
    # $occupancy_endpoint = az eventhubs eventhub authorization-rule keys list --resource-group $rgName --namespace-name $namespaces_adx_thermostat_occupancy_name --eventhub-name occupancy --name occupancy | ConvertFrom-Json
    # $occupancy_endpoint = $occupancy_endpoint.primaryConnectionString
    # $thermostat_endpoint = az eventhubs eventhub authorization-rule keys list --resource-group $rgName --namespace-name $namespaces_adx_thermostat_occupancy_name --eventhub-name thermostat --name thermostat | ConvertFrom-Json
    # $thermostat_endpoint = $thermostat_endpoint.primaryConnectionString

    # (Get-Content -path adx-config-appsetting.json -Raw) | Foreach-Object { $_ `
    #     -replace '#NAMESPACES_ADX_THERMOSTAT_OCCUPANCY_THERMOSTAT_ENDPOINT#', $thermostat_endpoint`
    #     -replace '#NAMESPACES_ADX_THERMOSTAT_OCCUPANCY_OCCUPANCY_ENDPOINT#', $occupancy_endpoint`
    #     -replace '#THERMOSTATTELEMETRY_URL#', $thermostat_telemetry_Realtime_URL`
    #     -replace '#OCCUPANCYDATA_URL#', $occupancy_data_Realtime_URL`
    # } | Set-Content -Path adx-config-appsetting-with-replacement.json

    # $config = az webapp config appsettings set -g $rgName -n $sites_adx_thermostat_realtime_name --settings @adx-config-appsetting-with-replacement.json

    # Publish-AzWebApp -ResourceGroupName $rgName -Name $sites_adx_thermostat_realtime_name -ArchivePath ./artifacts/binaries/app-adx-thermostat-realtime.zip -Force

    # az webapp stop --name $sites_adx_thermostat_realtime_name --resource-group $rgName

    # # number of retries
    # $maxRetries = 2
    # # delay 
    # $retryDelay = 10
    # # Retry counter
    # $count = 0
    
    # while ($count -lt $maxRetries) {
    #     Publish-AzWebApp -ResourceGroupName $rgName -Name $sites_adx_thermostat_realtime_name -ArchivePath ./artifacts/binaries/app-adx-thermostat-realtime.zip -Force
    
    #     if ($LASTEXITCODE -eq 0) {
    #         Write-Host "Simulator web app build deployed successfully."
    #         break
    #     } else {
    #         Write-Host "Failed to deploy simulator web app build. Retrying in $retryDelay seconds..."
    #         $count++
    #         Start-Sleep -Seconds $retryDelay
    #     }
    # }
    
    # if ($count -eq $maxRetries) {
    #     Write-Host "Failed to deploy the simulator web app build after $maxRetries attempts."
    #     exit 1
    # }

    # cd app-adx-thermostat-realtime
    # az webapp up --resource-group $rgName --name $sites_adx_thermostat_realtime_name --plan $serverfarm_adx_thermostat_realtime_name --location $Region
    # cd ..
    
    Write-Information "Deploying ADX Thermostat Realtime App"
    $TOKEN_2 = az account get-access-token --query accessToken | tr -d '"'
    $maxRetries = 3
    $retryCount = 0
    $success = $false
    while (-not $success -and $retryCount -lt $maxRetries) {
        try {
            $retryCount++
            Write-Host "Deployment attempt $retryCount..."
            $deployment = Invoke-RestMethod -Uri "https://$sites_adx_thermostat_realtime_name.scm.azurewebsites.net/api/publish?type=zip" `
                                            -Method Post `
                                            -Headers @{Authorization = "Bearer $TOKEN_2"} `
                                            -InFile "./artifacts/binaries/app-adx-thermostat-realtime.zip" `
                                            -ContentType "application/zip"
            $success = $true
            Write-Host "Deployment succeeded."
        }
        catch {
            Write-Warning "Attempt $retryCount failed. Retrying..."
            Start-Sleep -Seconds 10
            $TOKEN_2 = (az account get-access-token --query accessToken -o tsv) -replace '"', ''
        }
    }
    if (-not $success) { Write-Error "Deployment failed after $maxRetries attempts." }
  
    Add-Content log.txt "------Deploying Web Apps COMPLETED------"
    Write-Host  "----------------Deploying Web Apps COMPLETED---------------"


    Add-Content log.txt "------AZURE assets deployment DONE------"
    Write-Host "------------AZURE assets deployment DONE------------"

    $endtime=get-date
    $executiontime=$endtime-$starttime
    Write-Host "Execution Time"$executiontime.TotalMinutes
    Add-Content log.txt "-----------------Execution Complete---------------"

    Write-Host "List of resources deployed in $rgName resource group"
    $deployed_resources = Get-AzResource -resourcegroup $rgName
    $deployed_resources = $deployed_resources | Select-Object Name, Type | Format-Table -AutoSize
    Write-Output $deployed_resources

    Write-Host "List of resources deployed in $contosoSalesWsName workspace"
    $endPoint = "https://api.fabric.microsoft.com/v1/workspaces/$wsIdContosoSales/items"
    $fabric_items = Invoke-RestMethod $endPoint `
            -Method GET `
        -Headers $requestHeaders 

    $table = $fabric_items.value | Select-Object DisplayName, Type | Format-Table -AutoSize

    Write-Output $table

    Write-Host "List of resources deployed in $contosoFinanceWsName workspace"
    $endPoint = "https://api.fabric.microsoft.com/v1/workspaces/$wsIdContosoFinance/items"
    $fabric_items = Invoke-RestMethod $endPoint `
            -Method GET `
        -Headers $requestHeaders 

    $table = $fabric_items.value | Select-Object DisplayName, Type | Format-Table -AutoSize
    Write-Output $table

    Write-Host  "-----------------Execution Complete----------------"

}