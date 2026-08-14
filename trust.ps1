<#
.SYNOPSIS
    Signs the app's scripts with a personal self-signed certificate.

.DESCRIPTION
    OPTIONAL. Read this before running it.

    What it actually buys you:
      - The scripts carry an Authenticode signature, so PowerShell stops treating
        them as unidentified code and they keep working even if this machine is
        later put under an AllSigned execution policy.
      - The certificate is trusted only for your Windows account.

    What it does NOT do — be clear-eyed about this:
      - It does not make Microsoft Defender, SmartScreen, or a corporate AV treat
        the app as a known-good publisher. A self-signed certificate carries no
        outside reputation; it only says "the file has not changed since I signed
        it", not "somebody vouched for this".
      - Windows shows a security confirmation dialog the first time a certificate
        goes into the root store. That prompt is the operating system asking you to
        take responsibility for trusting it. Answer Yes only because you know where
        this app came from.

    The cost: any edit to tray.ps1 invalidates its signature and this has to be run
    again. That includes updates arriving through OneDrive from another PC. Under
    the default RemoteSigned policy an invalid signature is harmless, but under
    AllSigned the app would stop starting until re-signed.

    If you are not under AllSigned, install.cmd alone is enough — it already strips
    the internet mark that actually blocks synced files.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$AppDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Subject    = 'CN=Claude Usage Tray (personal)'
$CerPath    = Join-Path $AppDir 'ClaudeUsageTray.cer'
$ToSign     = @('tray.ps1', 'setup.ps1') | ForEach-Object { Join-Path $AppDir $_ } |
              Where-Object { Test-Path -LiteralPath $_ }

Write-Host ''
Write-Host '  Firmando Claude Usage Tray' -ForegroundColor Cyan
Write-Host ''

# Reuse an existing certificate so every PC ends up trusting the same one.
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Subject -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1

if (-not $cert) {
    Write-Host '  [ ] Creando certificado de firma...'
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
                -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10) `
                -KeyExportPolicy NonExportable
    Write-Host "  [x] Certificado creado: $($cert.Thumbprint)"
} else {
    Write-Host "  [x] Reutilizando certificado: $($cert.Thumbprint)"
}

Write-Host ''
Write-Host '  Windows va a pedirte confirmacion para confiar en el certificado.' -ForegroundColor Yellow
Write-Host '  Es una sola vez en este PC. Responde Si.' -ForegroundColor Yellow
Write-Host ''

foreach ($storeName in 'TrustedPublisher', 'Root') {
    $store = New-Object Security.Cryptography.X509Certificates.X509Store $storeName, 'CurrentUser'
    $store.Open('ReadWrite')
    try {
        if (-not $store.Certificates.Find('FindByThumbprint', $cert.Thumbprint, $false).Count) {
            $store.Add($cert)
            Write-Host "  [x] Anadido a CurrentUser\$storeName"
        } else {
            Write-Host "  [-] Ya estaba en CurrentUser\$storeName"
        }
    } finally { $store.Close() }
}

# Export the public half so the other PCs can trust the signature without ever
# seeing the private key. The private key stays in this machine's user store and
# is deliberately non-exportable, so it never travels through OneDrive.
[IO.File]::WriteAllBytes($CerPath, $cert.Export('Cert'))
Write-Host "  [x] Certificado publico exportado a $(Split-Path -Leaf $CerPath)"

foreach ($file in $ToSign) {
    $result = Set-AuthenticodeSignature -FilePath $file -Certificate $cert `
                  -HashAlgorithm SHA256 -ErrorAction Continue
    $name = Split-Path -Leaf $file
    if ($result.Status -eq 'Valid') {
        Write-Host "  [x] Firmado $name"
    } else {
        Write-Host "  [!] $name -> $($result.Status): $($result.StatusMessage)" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '  Listo. En los demas PCs basta con ejecutar install.cmd:' -ForegroundColor Green
Write-Host '  importa el .cer automaticamente desde OneDrive.'
Write-Host ''
Write-Host '  Recuerda: si editas tray.ps1, vuelve a ejecutar trust.cmd.' -ForegroundColor DarkGray
Write-Host ''
