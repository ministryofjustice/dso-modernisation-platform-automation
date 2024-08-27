$DomainNames = "sed-domain-names"
$Cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object -Property 'Subject' -match ($DomainNames.split(' ')[0]) | Sort-Object NotAfter | Select-Object -Last 1
if ($Cert) {
  $ExpiryDays = ($Cert.NotAfter - (Get-Date)).Days
  $Thumbprint = $Cert.Thumbprint
  Write-Output "store_cert=$Thumbprint,$ExpiryDays"
}

$WebBinding = Get-WebBinding -Name 'Default Web Site' | Where-Object -Property protocol -eq 'https'
if ($WebBinding -and $WebBinding -contains "certificateHash") {
  $CertificateStoreName = $WebBinding.certificateStoreName
  $CertPath = 'cert:\LocalMachine\' + $CertificateStoreName
  $Cert = Get-ChildItem -Path $CertPath | Where-Object -Property 'Thumbprint' -eq $WebBinding.certificateHash
  if ($Cert) {
    $ExpiryDays = ($Cert.NotAfter - (Get-Date)).Days
    $Thumbprint = $Cert.Thumbprint
    Write-Output "web_cert=$Thumbprint,$ExpiryDays"
  }
}

