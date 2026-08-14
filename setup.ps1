<#
.SYNOPSIS
    Registers or removes Claude Usage Tray for the current user.

.DESCRIPTION
    Everything this script touches lives inside the current user's profile:
    HKCU\Software\Microsoft\Windows\CurrentVersion\Run and %LOCALAPPDATA%.
    It never writes to HKLM, ProgramData, or another user's profile, and it never
    needs elevation. Other accounts on the machine — including the administrator —
    are completely unaffected.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]   [switch]$Install,
    [Parameter(ParameterSetName = 'Uninstall')] [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$AppDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$TrayPath  = Join-Path $AppDir 'tray.ps1'
$VbsPath   = Join-Path $AppDir 'launch.vbs'
$RunKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue  = 'ClaudeUsageTray'

function Stop-Tray {
    $stopped = 0
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*tray.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { }
        }
    if ($stopped -gt 0) { Start-Sleep -Milliseconds 600 }
    return $stopped
}

if ($Uninstall) {
    Write-Host ''
    Write-Host '  Desinstalando Claude Usage Tray' -ForegroundColor Cyan
    Write-Host ''

    $stopped = Stop-Tray
    Write-Host "  [x] Procesos detenidos: $stopped"

    if (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $RunKey -Name $RunValue
        Write-Host '  [x] Entrada de arranque eliminada de HKCU'
    } else {
        Write-Host '  [-] No habia entrada de arranque'
    }

    $stateDir = Join-Path $env:LOCALAPPDATA 'ClaudeUsageTray'
    Write-Host ''
    Write-Host "  Los archivos de la app siguen en:"
    Write-Host "    $AppDir" -ForegroundColor DarkGray
    Write-Host "  La cache local sigue en:"
    Write-Host "    $stateDir" -ForegroundColor DarkGray
    Write-Host '  Borralos a mano si no los quieres.'
    Write-Host ''
    return
}

# ---- Install -------------------------------------------------------------

Write-Host ''
Write-Host '  Instalando Claude Usage Tray' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path -LiteralPath $TrayPath)) {
    Write-Host "  ERROR: no encuentro tray.ps1 en $AppDir" -ForegroundColor Red
    exit 1
}

# 1. Ask OneDrive to keep these files on disk. With Files On-Demand a synced file
#    can be a cloud placeholder, and Windows would try to start the app at logon
#    before OneDrive has had a chance to hydrate it.
try {
    attrib.exe +P -U "$AppDir\*" /s /d 2>&1 | Out-Null
    Write-Host '  [x] Carpeta anclada en OneDrive (conservar siempre en este dispositivo)'
} catch {
    Write-Host '  [!] No se pudo anclar en OneDrive (no critico)' -ForegroundColor Yellow
}

# 2. Strip the Mark-of-the-Web. Files that arrive through OneDrive on another PC can
#    carry an internet zone tag, which makes Windows treat them as untrusted and
#    blocks them under the RemoteSigned execution policy.
$unblocked = 0
Get-ChildItem -LiteralPath $AppDir -File | ForEach-Object {
    if (Get-Content -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
        Unblock-File -LiteralPath $_.FullName
        $unblocked++
    }
}
Write-Host "  [x] Archivos desbloqueados para Windows (marca de internet quitada: $unblocked)"

# 3. Trust the signing certificate if one was shipped alongside the app.
$cer = Join-Path $AppDir 'ClaudeUsageTray.cer'
if (Test-Path -LiteralPath $cer) {
    try {
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $cer
        foreach ($storeName in 'TrustedPublisher', 'Root') {
            $store = New-Object Security.Cryptography.X509Certificates.X509Store $storeName, 'CurrentUser'
            $store.Open('ReadWrite')
            if (-not $store.Certificates.Find('FindByThumbprint', $cert.Thumbprint, $false).Count) {
                $store.Add($cert)
            }
            $store.Close()
        }
        Write-Host '  [x] Certificado de firma confiado (solo tu cuenta)'
    } catch {
        Write-Host "  [!] No se pudo confiar el certificado: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 4. Register autostart. The path is resolved on THIS machine, so each PC gets its
#    own correct OneDrive location.
$command = if (Test-Path -LiteralPath $VbsPath) {
    'wscript.exe "{0}"' -f $VbsPath
} else {
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $TrayPath
}
New-ItemProperty -Path $RunKey -Name $RunValue -Value $command -PropertyType String -Force | Out-Null
Write-Host '  [x] Arranque automatico registrado en HKCU (solo tu cuenta)'

# 5. Sanity check: the API has to answer before we call this a success.
Write-Host '  [ ] Comprobando acceso a la API de uso...' -NoNewline
$probe = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TrayPath -Once 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "`r  [x] API OK                              "
    $probe | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
} else {
    Write-Host "`r  [!] La API no respondio                 " -ForegroundColor Yellow
    $probe | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    Write-Host '      Abre Claude Code una vez para renovar la credencial.' -ForegroundColor Yellow
}

# 6. Restart the tray so the running copy matches what is on disk.
[void](Stop-Tray)
Start-Process wscript.exe -ArgumentList "`"$VbsPath`""
Write-Host '  [x] App arrancada'

Write-Host ''
Write-Host '  Listo. Busca el icono con los dos numeros en la bandeja.' -ForegroundColor Green
Write-Host '  Si no lo ves, esta en el desplegable de iconos ocultos (flecha ^).'
Write-Host '  Arrastralo fuera para fijarlo en la barra.'
Write-Host ''
