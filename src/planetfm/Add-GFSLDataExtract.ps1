$ErrorActionPreference = "Stop"

Write-Output "Debug PSVersionTable"
$PSVersionTable

# Security module compatibility can be problematic if switching
# between powershell 5 & 7. It can pick up the wrong version so
# clearing PSModulePath to ensure it is loaded cleanly
Write-Output "Importing Security Module"
$Env:PSModulePath = ""
Import-Module Microsoft.PowerShell.Security

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
$securePassword = ConvertTo-SecureString $SecretValue.svc_planetfm_gfsl -AsPlainText -Force
$credentials = New-Object System.Management.Automation.PSCredential("HMPP\svc_planetfm_gfsl", $securePassword)

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
    if ($file.Extension -eq ".txt") {
      $filePath           = $file.FullName
      $fileName           = $file.Name

      $fileNameURLEncoded = [System.Net.WebUtility]::UrlEncode($fileName)
      $uri                = "$destinationUrl/$fileNameURLEncoded"

      $uploadRequired = $true
      $hash           = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash

      Write-Output "$fileName checking for existing S3 file $hash"

      try {
        $response   = Invoke-WebRequest -Uri $uri -Method Head
        $remoteHash = $response.Headers["x-amz-meta-sha256"]

        if ($remoteHash -and $remoteHash -eq $hash) {
          $uploadRequired = $false
        }
      }
      catch {
        continue
      }

      if ($uploadRequired) {
        try {
          Invoke-RestMethod -Uri $uri -Method Put -InFile $filePath -ContentType "application/octet-stream"
          Write-Output "$fileName uploaded to S3"
        }
        catch {
          Write-Error "$fileName Failed to upload to S3. Error: $_"
        }
      } else {
        Write-Output "$fileName skipping - already uploaded to S3"
      }
    }
  }

  Write-Output "Preparing upload in utf8 encoding"
  $ansi = [System.Text.Encoding]::GetEncoding(1252)
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  foreach ($file in $files) {
    if ($file.Extension -eq ".txt") {
      $filePath = $file.FullName
      $fileName = $file.Name

      $fileNameUtf8 = [io.path]::ChangeExtension($fileName, "utf8")
      $filePathUtf8 = [io.path]::ChangeExtension($filePath, "utf8")

      $fileNameUtf8URLEncoded = [System.Net.WebUtility]::UrlEncode($fileNameUtf8)
      $uriUtf8 = "$destinationUrl/$fileNameUtf8URLEncoded"

      $content = [System.IO.File]::ReadAllText($filePath, $ansi)
      [System.IO.File]::WriteAllText($filePathUtf8, $content, $utf8)

      $uploadRequired = $true
      $hash           = (Get-FileHash -Path $filePathUtf8 -Algorithm SHA256).Hash
      Write-Output "$fileNameUtf8 checking for existing S3 file $hash"

      try {
        $response   = Invoke-WebRequest -Uri $uriUtf8 -Method Head
        $remoteHash = $response.Headers["x-amz-meta-sha256"]

        if ($remoteHash -and $remoteHash -eq $hash) {
          $uploadRequired = $false
        }
      }
      catch {
        continue
      }

      if ($uploadRequired) {
        try {
          Invoke-RestMethod -Uri $uriUtf8 -Method Put -InFile $filePathUtf8 -ContentType "application/octet-stream"
          Write-Output "$fileNameUtf8 uploaded to S3"
        }
        catch {
          Write-Error "$fileNameUtf8 Failed to upload to S3. Error: $_"
        }
      } else {
        Write-Output "$fileNameUtf8 skipping - already uploaded to S3"
      }
      Remove-Item $filePathUtf8
    }
  }
}
