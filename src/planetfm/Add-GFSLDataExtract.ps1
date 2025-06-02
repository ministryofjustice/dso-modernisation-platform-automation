$ErrorActionPreference = "Stop"

Write-Output "Debug PSVersion"
$PSVersionTable.PSVersion
Write-Output "Debug PSModulePath"
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" -Name PSModulePath

Write-Output "Getting Account Id"
$SecretId = "/microsoft/AD/azure.hmpp.root/shared-passwords"
$AccountId = aws sts get-caller-identity --query Account --output text
$SecretRoleName = $ModPlatformADConfig.SecretRoleName
$RoleArn = "arn:aws:iam::${AccountId}:role/EC2HmppsDomainSecretsRole"
$Session = "ModPlatformADConfig-$env:COMPUTERNAME"

Write-Output "Assuming Role for domain secrets"
$CredsRaw = aws sts assume-role --role-arn "${RoleArn}" --role-session-name "${Session}"
$Creds = "$CredsRaw" | ConvertFrom-Json
$Tmp_AWS_ACCESS_KEY_ID = $env:AWS_ACCESS_KEY_ID
$Tmp_AWS_SECRET_ACCESS_KEY = $env:AWS_SECRET_ACCESS_KEY
$Tmp_AWS_SESSION_TOKEN = $env:AWS_SESSION_TOKEN
$env:AWS_ACCESS_KEY_ID = $Creds.Credentials.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $Creds.Credentials.SecretAccessKey
$env:AWS_SESSION_TOKEN = $Creds.Credentials.SessionToken

Write-Output "Retrieving SecretsManager domain secret"
$SecretValueRaw = aws secretsmanager get-secret-value --secret-id "${SecretId}" --query SecretString --output text
$env:AWS_ACCESS_KEY_ID = $Tmp_AWS_ACCESS_KEY_ID
$env:AWS_SECRET_ACCESS_KEY = $Tmp_AWS_SECRET_ACCESS_KEY
$env:AWS_SESSION_TOKEN = $Tmp_AWS_SESSION_TOKEN

Write-Output "Creating PSCredentials Object"
$SecretValue = "$SecretValueRaw" | ConvertFrom-Json
$securePassword = ConvertTo-SecureString $SecretValue.svc_rds -AsPlainText -Force
$credentials = New-Object System.Management.Automation.PSCredential("HMPP\svc_rds", $securePassword)

Write-Output "Retrieving SecretsManager GFSL secret"
$SecretId = "/GFSL/planetfm-data-extract"
$SecretValueRaw = aws secretsmanager get-secret-value --secret-id "${SecretId}" --query SecretString --output text
$SecretValue = "$SecretValueRaw" | ConvertFrom-Json

Write-Output "Extracting Source and Destination URL from secret"
$sourcePath = $SecretValue.SourcePath
$destinationUrl = $SecretValue.DestinationUrl

Write-Output "Running PSScriptBlock under domain user"
Invoke-Command -ComputerName localhost -Credential $credentials -Authentication CredSSP -ArgumentList $sourcePath, $destinationUrl -ScriptBlock  {
  param ($sourcePath, $destinationUrl)

  # Get list of files in source directory
  Write-Output "Getting list of files from $sourcePath"
  $files = Get-ChildItem -Path $sourcePath

  foreach ($file in $files) {
    $filePath = $file.FullName

    # URL-encode the file name if necessary
    $fileName = [System.Net.WebUtility]::UrlEncode($file.Name)
    $uri = "$destinationUrl/$fileName"

    try {
      Invoke-RestMethod -Uri $uri -Method Put -InFile $filePath -ContentType "application/octet-stream"
      Write-Host "Uploaded $fileName successfully."
    }
    catch {
      Write-Error "Failed to upload $fileName. Error: $_"
    }
  }
}
