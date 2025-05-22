#-------------------------------
# INACTIVE COMPUTER MANAGEMENT
#-------------------------------
#Import-Module ActiveDirectory
import-Module -Name AWSPowerShell -MinimumVersion 4.1.807

# Get the secret value
$hostname = (Get-ComputerInfo).CsName
$adSecretValue = Get-SECSecretValue -SecretId "/$($hostname.ToLower())/dso-ad-computer-cleanup" -Region "eu-west-2"
$adSecretValue = $adSecretValue.SecretString | ConvertFrom-Json
$username = $adSecretValue.username
$password = $adSecretValue.password
#$domainname = $adSecretValue.domainname
$password = ConvertTo-SecureString -String $password -AsPlainText -Force

$adcred = New-Object System.Management.Automation.PSCredential ($username, $Password)

$LogDir = "C:\ScriptLogs"
Expand-Archive -Path "$LogDir\all_logs.zip" -DestinationPath $LogDir -Force
$verifiedAzInactiveComps = (Get-Content -Path  $LogDir\ad_clean_computers_verifiedInactiveazNomsComputers.csv | ConvertFrom-csv)
$verifiedAwsInactiveComps = Get-Content -Path $LogDir\ad_clean_computers_verifiedAwsInactiveComps.csv

# # Example to Disable Inactive Computers
# ForEach ($computer in $inactiveComputers) {
#     $DistName = $computer.DistinguishedName
#     #Set-ADComputer -Identity $DistName -Enabled $false
#     Get-ADComputer -Filter { DistinguishedName -eq $DistName } | Select-Object Name, Enabled
# }

Write-Output "Deleting $($verifiedAzInactiveComps.count) verified inactive computer accounts from the Azure network scopes"
ForEach ($computer in $verifiedAzInactiveComps.Name) {
    #Remove-ADComputer -Identity $computer -Confirm:$false -Credential $adcred
    Write-Output "$($computer) - Will be deleted"
}

Write-Output "Deleting $($verifiedAwsInactiveComps.count) verified inactive computer accounts from the AWS network scopes"
ForEach ($computer in $verifiedAwsInactiveComps) {
    #Remove-ADComputer -Identity $computer -Confirm:$false -Credential $adcred
    Write-Output "$($computer) - Will be Deleted"
}

# May need Get-ADComputer $computer.DistinguishedName | Remove-ADObject -Recursive -Confirm:$false