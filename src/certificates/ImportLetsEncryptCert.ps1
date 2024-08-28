$ErrorActionPreference = "Stop"
$ChainFileBase64 = "sed-chain-base64"
$PfxFileBase64 = "sed-pfx-base64"
$Password = "sed-password"
$PasswordSecureString = ConvertTo-SecureString $Password -AsPlainText -Force

$ChainFileName = [System.IO.Path]::GetTempFileName().Replace(".tmp",".pem")
[IO.File]::WriteAllBytes($ChainFileName, [Convert]::FromBase64String($ChainFileBase64))
$CACert = Import-Certificate -FilePath $ChainFileName -CertStoreLocation 'Cert:\LocalMachine\CA'
$CACert
Remove-Item -Path $ChainFileName -Force

# Cert must be exportable otherwise IIS Web-Binding does not work
$PfxFileName = [System.IO.Path]::GetTempFileName().Replace(".tmp",".pfx")
[IO.File]::WriteAllBytes($PfxFileName, [Convert]::FromBase64String($PfxFileBase64))
$PfxCert = Import-PfxCertificate -Exportable -FilePath $PfxFileName -CertStoreLocation 'Cert:\LocalMachine\My' -Password $PasswordSecureString
$PfxCert
Remove-Item -Path $PfxFileName -Force

$Thumbprint=$PfxCert.Thumbprint
Write-Output "cert_thumbprint=$Thumbprint"
