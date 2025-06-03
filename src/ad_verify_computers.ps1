#Import-Module ActiveDirectory

$daysInactive = 90
$inactiveDate = (Get-Date).Adddays( - ($daysInactive))
Write-Output "Inactive cleanup date will be $($daysInactive) days previous, i.e. $($inactiveDate)"

#-------------------------------
# FIND INACTIVE COMPUTERS
#-------------------------------

# Get AD Computers that haven't logged on in $daysInactive days
$inactiveComputers = Get-ADComputer -Filter { LastLogonDate -lt $inactiveDate } -Properties LastLogonDate, whenCreated, IPv4Address | Select-Object Name, LastLogonDate, IPv4Address, DistinguishedName

# Get AD Computers that have never logged on and were created > the $daysInactive variable
$UnusedComputers = Get-ADComputer -Filter { LastLogonDate -notlike "*" -and whenCreated -lt $inactiveDate } -Properties LastLogonDate, whenCreated  | Select-Object Name, LastLogonDate, whenCreated, DistinguishedName
Write-Output "Found $($UnusedComputers.count) unused, aged computer accounts, which are: $($UnusedComputers.Name)"

# Alternative method (includes never logged on computers)
# $inactiveComputers = Search-ADAccount -AccountInactive -DateTime $inactiveDate -ComputersOnly | Select-Object Name, LastLogonDate, Enabled, DistinguishedName

#-------------------------------
# SPLIT BY CLOUD USING IP RANGE
#-------------------------------

$azNomsProdIpRange = "10.40."
$azNomsDevTestIpRange = "10.101."
$azNomsDevTestMgmtIpRange = "10.102."
$azNomsTestDRIpRange = "10.111."
$azNomsMgmtDRIpRange = "10.112."
$AwsMpCore = "10.20."
$AwsMpNonLive = "10.26."
$AwsMpLive = "10.27."

# # hmpps azure cidr ranges
# aks-studio-hosting-live-1-vnet = "10.244.0.0/20"
# aks-studio-hosting-dev-1-vnet  = "10.247.0.0/20"
# aks-studio-hosting-ops-1-vnet  = "10.247.32.0/20"
# nomisapi-t2-root-vnet          = "10.47.0.192/26"
# nomisapi-t3-root-vnet          = "10.47.0.0/26"
# nomisapi-preprod-root-vnet     = "10.47.0.64/26"
# nomisapi-prod-root-vnet        = "10.47.0.128/26"

$azNomsInactiveCompAccts = @()
$awsInactiveCompAccts = @()

foreach ($Computer in $inactiveComputers) {
    $IPAddress = $Computer.IPv4Address
    if ($IPAddress -like "$azNomsProdIpRange*" -or $IPAddress -like "$azNomsDevTestIpRange*" -or $IPAddress -like "$azNomsDevTestMgmtIpRange*" -or $IPAddress -like "$azNomsTestDRIpRange*" -or $IPAddress -like "$azNomsMgmtDRIpRange*") {
        $azNomsInactiveCompAccts += [PSCustomObject]@{
            Name              = $Computer.Name
            IPAddress         = $IPAddress
            LastLogonDate     = $Computer.LastLogonDate
            whenCreated       = $Computer.whenCreated
            DistinguishedName = $Computer.DistinguishedName
        }
    }
    elseif ($IPAddress -like "$AwsMpCore*" -or $IPAddress -like "$AwsMpNonLive*" -or $IPAddress -like "$AwsMpLive*") {
        $awsInactiveCompAccts += [PSCustomObject]@{
            Name              = $Computer.Name
            IPAddress         = $IPAddress
            LastLogonDate     = $Computer.LastLogonDate
            whenCreated       = $Computer.whenCreated
            DistinguishedName = $Computer.DistinguishedName
        }
    }
}

Write-Output "azNomsInactiveCompAccts count: $($azNomsInactiveCompAccts.count), AwsInactiveCompsAccts (ModPlatform) count: $($awsInactiveCompAccts.count) out of a total inactive of: $($inactiveComputers.count)"

#----------------------------------
# CROSS REFERENCE AZURE TO BE SAFE
#----------------------------------
import-Module -Name AWSPowerShell -MinimumVersion 4.1.807
Import-Module Az.Accounts, Az.Compute
Import-Module Microsoft.PowerShell.Security

# Get the secret value
$hostname = (Get-ComputerInfo).CsName
$secretValue = Get-SECSecretValue -SecretId "/$($hostname.ToLower())/dso-modernisation-platform-automation" -Region "eu-west-2"
$raw = $secretValue.SecretString.Trim('{}').Trim()
$parts = $raw -split ',\s*'

# Parse into hashtable
$secretJson = @{}
foreach ($part in $parts) {
    $kv = $part -split ':\s*', 2
    $secretJson[$kv[0].Trim()] = $kv[1].Trim()
}

$clientId = $secretJson["clientId"]
$clientSecret = $secretJson["clientSecret"]
$tenantId = $secretJson["tenantId"]
$subscriptionId = $secretJson["subscriptionId"]

$clientSecret = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
$pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $clientId, $clientSecret
Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant $tenantId -Subscription $subscriptionId

# NOMS Production 1, NOMS Dev & Test Environments
$subscriptionIds = @("1d95dcda-65b2-4273-81df-eb979c6b547b", "b1f3cebb-4988-4ff9-9259-f02ad7744fcb")

$doNotDeleteAzCompAccts = @()

Write-Output "Before verification azNomsInactiveCompAccts count is: $($azNomsInactiveCompAccts.Count)"

foreach ($subscriptionId in $subscriptionIds) {
    Select-AzSubscription -SubscriptionId $subscriptionId
    # Get all Azure VMs in the current subscription
    $AzureVMs = Get-AzVM | Select-Object Name
    Write-Output "Cross checking $($AzureVMs.count) VM's in current subsription"
    # Compare inactive AD computer accounts with Azure VMs
    $doNotDeleteAzCompAccts = $azNomsInactiveCompAccts | Where-Object { $_.Name -in $AzureVMs.Name }
    $azNomsInactiveCompAccts = $azNomsInactiveCompAccts | Where-Object { $_.Name -notin $AzureVMs.Name }
    Write-Output "$($doNotDeleteAzCompAccts.Name) removed from the deletion list for current subsription, $($doNotDeleteAzCompAccts.Count) VM's"
    Write-Output "After this verification pass azNomsInactiveCompAccts count is: $($azNomsInactiveCompAccts.Count)"
}

# Output deleted VMs
if ($azNomsInactiveCompAccts) {
    Write-Output "After verification azNomsInactiveCompAccts count is: $($azNomsInactiveCompAccts.Count), difference is: $($doNotDeleteAzCompAccts.Count)"
}
else {
    Write-Output "No deleted VMs found."
}

#----------------------------------
# CROSS REFERENCE AWS TO BE SAFE
#----------------------------------

$awsNamedInstances = Get-Content -Path "C:\ScriptLogs\all-ec2-hostnames.txt"

$doNotDeleteAwsCompAccts = @()
$verifiedAwsInactiveComps = @()

# to confirm the verication is working we can pick a name from $awsInactiveCompAccts and add it to $awsNamedInstances
# $awsNamedInstances += "EC2AMAZ-1234567"

foreach ($name in $awsInactiveCompAccts.Name) {
    # Compare inactive AD computer accounts with current Mod-Platform instances
    if ($name -in $awsNamedInstances) {
        $doNotDeleteAwsCompAccts += $name
    }
    elseif ($name -notin $awsNamedInstances) {
        $verifiedAwsInactiveComps += $name
    }
}

# Output results after AWS verification
if ($awsInactiveCompAccts) {
    Write-Output "Checked $($awsInactiveCompAccts.count) inactive AWS comp accts, against $($awsNamedInstances.count) active instances, verified result count is: $($verifiedAwsInactiveComps.Count), difference is: $($doNotDeleteAwsCompAccts.Count), which is:"
    write-output $doNotDeleteAwsCompAccts
}
else {
    Write-Output "No deleted VMs found."
}

#-----------------------------------
# REPORTING - Export results to CSV
#-----------------------------------
$LogDir = "C:\ScriptLogs"
if (!(Test-Path -Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force
}

$inactiveComputers | Export-Csv $LogDir\ad_clean_computers_allInactiveComputers.csv -NoTypeInformation
$azNomsInactiveCompAccts | Export-Csv $LogDir\ad_clean_computers_verifiedInactiveazNomsComputers.csv -NoTypeInformation
$verifiedAwsInactiveComps | Out-File -FilePath $LogDir\ad_clean_computers_verifiedAwsInactiveComps.csv
$UnusedComputers | Export-Csv $LogDir\ad_clean_computers_completelyUnusedComputers.csv -NoTypeInformation

#$dateTime = Get-Date -F 'ddMMyy-HHmm'
$ZipPath = Join-Path $LogDir "all_logs.zip"
Compress-Archive -Path "$LogDir\*.csv" -DestinationPath $ZipPath -Force
         
# Output location of zip file for retrieval
Write-Host "##output_path##$ZipPath"
