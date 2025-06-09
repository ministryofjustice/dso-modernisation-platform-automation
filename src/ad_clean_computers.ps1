#-------------------------------
# INACTIVE COMPUTER MANAGEMENT
#-------------------------------
#Import-Module ActiveDirectory
import-Module -Name AWSPowerShell -MinimumVersion 4.1.807
$currentDate = Get-Date -F 'dd-MM-yy'

# Get the secret value
$hostname = (Get-ComputerInfo).CsName
$adSecretValue = Get-SECSecretValue -SecretId "/$($hostname.ToLower())/dso-ad-computer-cleanup" -Region "eu-west-2"
$adSecretValue = $adSecretValue.SecretString | ConvertFrom-Json
$username = $adSecretValue.username
$password = $adSecretValue.password
$domainname = $adSecretValue.domainname
$password = ConvertTo-SecureString -String $password -AsPlainText -Force

$adcred = New-Object System.Management.Automation.PSCredential ($username, $Password)

$LogDir = "C:\ScriptLogs"
Expand-Archive -Path "$LogDir\all_logs.zip" -DestinationPath $LogDir -Force
$verifiedAzInactiveComps = (Get-Content -Path  $LogDir\ad_clean_computers_verifiedInactiveazNomsComputers.csv | ConvertFrom-csv)
$verifiedAwsInactiveComps = Get-Content -Path $LogDir\ad_clean_computers_verifiedAwsInactiveComps.csv
$unusedInactiveComps = (Get-Content -Path $LogDir\ad_clean_computers_completelyUnusedComputers.csv | ConvertFrom-csv)

# # Alternative Example to Disable Inactive Computers
# ForEach ($computer in $inactiveComputers) {
#     $DistName = $computer.DistinguishedName
#     #Set-ADComputer -Identity $DistName -Enabled $false
#     Get-ADComputer -Filter { DistinguishedName -eq $DistName } | Select-Object Name, Enabled
# }

$deletedAzInactiveComps = @()
$deletedAwsInactiveComps = @()
$deletedUnusedAgedComps = @()

Write-Output "Deleting $($unusedInactiveComps.count) unused inactive computer accounts"
ForEach ($computer in $unusedInactiveComps.Name) {
    Remove-ADComputer -Identity $computer -Confirm:$false -Credential $adcred
    $deletedUnusedAgedComps += [PSCustomObject]@{
        Name    = $Computer
        Domain  = $domainname
        Deleted = $currentDate
    }
}

Write-Output "Deleting $($verifiedAzInactiveComps.count) verified inactive computer accounts from the Azure network scopes"
ForEach ($computer in $verifiedAzInactiveComps.Name) {
    #Remove-ADComputer -Identity $computer -Confirm:$false -Credential $adcred
    (Get-ADComputer $computer).DistinguishedName | Remove-ADObject -Recursive -Confirm:$false -Credential $adcred
    $deletedAzInactiveComps += [PSCustomObject]@{
        Name    = $Computer
        Domain  = $domainname
        Deleted = $currentDate
    }
}

Write-Output "Deleting $($verifiedAwsInactiveComps.count) verified inactive computer accounts from the AWS network scopes"
ForEach ($computer in $verifiedAwsInactiveComps) {
    #Remove-ADComputer -Identity $computer -Confirm:$false -Credential $adcred
    (Get-ADComputer $computer).DistinguishedName | Remove-ADObject -Recursive -Confirm:$false -Credential $adcred
    $deletedAwsInactiveComps += [PSCustomObject]@{
        Name    = $Computer
        Domain  = $domainname
        Deleted = $currentDate
    }
}

# Output results after deletion runs
if ($deletedAzInactiveComps) {
    Write-Output "Deleted $($deletedAzInactiveComps.count) computers in the Azure scopes for $($domainname) domain."
    write-output $deletedAzInactiveComps
}
else {
    Write-Output "No deleted Azure VM's found."
}

if ($deletedAwsInactiveComps) {
    Write-Output "Deleted $($deletedAwsInactiveComps.count) computers in the AWS scopes for $($domainname) domain."
    write-output $deletedAwsInactiveComps
}
else {
    Write-Output "No deleted AWS instances found."
}

Copy-Item -Path $LogDir\ad_clean_computers_allInactiveComputers.csv -Destination $LogDir\inactiveCompDNs-$domainname-$currentDate.csv
$deletedAzInactiveComps | Export-Csv $LogDir\deletedAzInactiveComps-$domainname-$currentDate.csv -NoTypeInformation
$deletedAwsInactiveComps | Export-Csv $LogDir\deletedAwsInactiveComps-$domainname-$currentDate.csv -NoTypeInformation
$deletedUnusedAgedComps | Export-Csv $LogDir\deletedUnusedAgedComps-$domainname-$currentDate.csv -NoTypeInformation


# Get-ChildItem -Path $LogDir | Where-Object {
#     $_.Name -in @("*-$domainname-$currentDate.csv")
# } | ForEach-Object {
#     Write-S3Object -BucketName $bucketName -File $_.FullName -Key ("adcompscript/logs/" + $_.Name)
# }
