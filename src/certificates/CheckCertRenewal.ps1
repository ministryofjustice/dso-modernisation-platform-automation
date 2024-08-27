$DomainNames = "sed-domain-names"
$RenewExpiryDays = sed-renew-expiry-days

$StoreCertExpiryDays = $null
$StoreCertThumbprint = $null
$WebCert = $null
$WebCertExpiryDays = $null
$WebCertThumbprint = $null
$RenewCert = 0
$UpdateWeb = 0
$RequiresUpdate = 0

$StoreCert = Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object -Property 'Subject' -match ($DomainNames.split(' ')[0]) | Sort-Object NotAfter | Select-Object -Last 1
if ($StoreCert) {
  $StoreCertExpiryDays = ($StoreCert.NotAfter - (Get-Date)).Days
  $StoreCertThumbprint = $StoreCert.Thumbprint
  Write-Output "store_cert=$StoreCertThumbprint,$StoreCertExpiryDays"
}

$WebBinding = Get-WebBinding -Name 'Default Web Site' | Where-Object -Property protocol -eq 'https'
if ($WebBinding -and $WebBinding.PSobject.Properties.Name -contains "certificateHash") {
  $CertificateStoreName = $WebBinding.certificateStoreName
  $CertPath = 'cert:\LocalMachine\' + $CertificateStoreName
  $WebCert = Get-ChildItem -Path $CertPath | Where-Object -Property 'Thumbprint' -eq $WebBinding.certificateHash
}
if ($WebCert) {
  $WebCertExpiryDays = ($WebCert.NotAfter - (Get-Date)).Days
  $WebCertThumbprint = $WebCert.Thumbprint
  Write-Output "web_cert=$WebCertThumbprint,$WebCertExpiryDays"
}

if ($StoreCert -eq $null -or $StoreCertExpiryDays -le $RenewExpiryDays) {
  $RenewCert=1
  $RequiresUpdate=1
}

if ($WebCert -eq $null -or $RenewCert -eq 1 -or $StoreCertThumbprint -ne $WebCertThumbprint) {
  $UpdateWeb=1
  $RequiresUpdate=1
}
Write-Output "renew_cert=$RenewCert"
Write-Output "update_web=$UpdateWeb"
Write-Output "requires_update=$RequiresUpdate"
