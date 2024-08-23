$WebBinding = Get-WebBinding -Name 'Default Web Site' | Where-Object -Property protocol -eq 'https'
if ($WebBinding -and $WebBinding.contains("certificateHash")) {
  $CertificateStoreName = $WebBinding.certificateStoreName
  $CertPath = 'cert:\LocalMachine\' + $CertificateStoreName
  $WebCert = Get-ChildItem -Path $CertPath | Where-Object -Property 'Thumbprint' -eq $WebBinding.certificateHash
  if ($WebCert) {
    ($WebCert.NotAfter - (Get-Date)).Days
  }
}
