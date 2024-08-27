$ErrorActionPreference = "Stop"
$DomainNames = "sed-domain-names"

$WebBinding = Get-WebBinding -Name 'Default Web Site' | Where-Object -Property protocol -eq 'https'
if (-not $WebBinding) {
  Write-Output "Creating Default Web Site https WebBinding"
  $WebBinding = New-WebBinding -Name 'Default Web Site' -IPAddress "*" -Port 443 -Protocol "https"
}

$Cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object -Property 'Subject' -match ($DomainNames.split(' ')[0]) | Sort-Object NotAfter | Select-Object -Last 1
if (-not $Cert) {
  Write-Output "Could not find certificate in store"
  Exit 1
}

$WebBinding.AddSslCertificate($Cert.Thumbprint, 'My')
