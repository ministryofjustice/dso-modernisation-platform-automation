$ErrorActionPreference = "Stop"
$ChainFileBase64 = "sed-chain-file"
$PfxFileBase64 = "sed-pfx-file"
$Password = "sed-password"

$WebBinding = Get-WebBinding -Name 'Default Web Site' | Where-Object -Property protocol -eq 'https'
if (-not $WebBinding) {
  Write-Output "Creating https WebBinding"
  $WebBinding = New-WebBinding -Name $Config.WebSiteName -IPAddress "*" -Port 443 -Protocol "https"
}
$WebBinding

$ChainFileName = [System.IO.Path]::GetTempFileName().Replace(".tmp",".pem")
[IO.File]::WriteAllBytes($ChainFileName, [Convert]::FromBase64String($ChainFileBase64))
$CACert = Import-Certificate -FilePath $ChainFileName -CertStoreLocation 'Cert:\LocalMachine\CA'
$CACert
Remove-Item -Path $ChainFileName -Force

$PfxFileName = [System.IO.Path]::GetTempFileName().Replace(".tmp",".pfx")
[IO.File]::WriteAllBytes($PfxFileName, [Convert]::FromBase64String($PfxFileBase64))
$PfxCert = Import-PfxCertificate -FilePath $PfxFileName -CertStoreLocation 'Cert:\LocalMachine\My' -Password $Password
$PfxCert
Remove-Item -Path $PfxFileName -Force

$WebBinding.AddSslCertificate($PfxCert.Thumbprint, 'Cert:\LocalMachine\My')
