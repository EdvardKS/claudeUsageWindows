<#
.SYNOPSIS
    Installs, repairs or removes Claude Usage Tray for the current user.

.DESCRIPTION
    An explicit, bilingual wizard. It explains what the app does, checks that this
    machine can actually run it, reports which Claude plan it found, shows exactly
    where the files will go and what will be touched, and only then asks for one
    confirmation.

    Everything it writes lives inside the current user's profile:
    HKCU\Software\Microsoft\Windows\CurrentVersion\Run, %LOCALAPPDATA%\Programs and
    %LOCALAPPDATA%\ClaudeUsageTray. It never writes to HKLM, ProgramData or another
    user's profile, and it never needs elevation. Other accounts on the machine —
    including the administrator — are completely unaffected.

.PARAMETER Install
    Default. Runs the full wizard.

.PARAMETER Uninstall
    Stops the app and removes the autostart entry.

.PARAMETER Repair
    Re-runs the checks and rewrites the autostart entry without copying anything.
    This is the diagnostic path: run it whenever the icon stops behaving.

.PARAMETER Silent
    No pauses and no questions. Everything is still printed.

.PARAMETER InPlace
    Do not copy anything: run the app from the folder it is already in. Use this
    when the folder is synced (OneDrive, Dropbox, a network share) and you want
    edits to propagate to your other machines.

.PARAMETER Language
    en, es, or auto (default: follow the Windows UI language).
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]   [switch]$Install,
    [Parameter(ParameterSetName = 'Uninstall')] [switch]$Uninstall,
    [Parameter(ParameterSetName = 'Repair')]    [switch]$Repair,
    [switch]$Silent,
    [switch]$InPlace,
    [ValidateSet('auto', 'en', 'es')] [string]$Language = 'auto'
)

$ErrorActionPreference = 'Stop'

$SourceDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$DefaultDir = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeUsageTray'
$StateDir   = Join-Path $env:LOCALAPPDATA 'ClaudeUsageTray'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue   = 'ClaudeUsageTray'

# Files that make up the app. config.json is handled separately so an existing
# one is never overwritten with the shipped defaults.
$AppFiles = @(
    'tray.ps1', 'launch.vbs', 'setup.ps1',
    'install.cmd', 'uninstall.cmd', 'trust.cmd', 'trust.ps1',
    'README.md', 'LICENSE'
)

# ---------------------------------------------------------------------------
# Language
# ---------------------------------------------------------------------------

. (Join-Path $SourceDir 'lib\i18n.ps1')
. (Join-Path $SourceDir 'lib\plan.ps1')

$configPath = Join-Path $SourceDir 'config.json'
$configLang = 'auto'
if ($Language -eq 'auto' -and (Test-Path -LiteralPath $configPath)) {
    try {
        $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -contains 'language' -and $cfg.language) {
            $configLang = [string]$cfg.language
        }
    } catch { }
}
$detected = Get-AppLanguage 'auto'
[void](Set-AppLanguage $(if ($Language -ne 'auto') { $Language } else { $configLang }))

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------

$script:StepNo    = 0
$script:StepTotal = 8

function Write-Banner {
    Write-Host ''
    Write-Host ('  ' + (T 'wiz.title')) -ForegroundColor Cyan
    Write-Host ('  ' + (T 'wiz.subtitle')) -ForegroundColor DarkGray
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$TitleKey)
    $script:StepNo++
    Write-Host ''
    Write-Host ('  [{0}/{1}] ' -f $script:StepNo, $script:StepTotal) -ForegroundColor DarkGray -NoNewline
    Write-Host (T $TitleKey) -ForegroundColor White
}

function Split-Wrapped {
    <# Word-wraps at 68 columns so the explanatory paragraphs stay readable in a
       default 80-column console. Returns an array of lines. #>
    param([string]$Text, [int]$Width = 68)
    $lines = New-Object System.Collections.ArrayList
    $line  = ''
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if ($line.Length -eq 0) {
            $line = $word
        } elseif (($line.Length + 1 + $word.Length) -le $Width) {
            $line = $line + ' ' + $word
        } else {
            [void]$lines.Add($line); $line = $word
        }
    }
    if ($line) { [void]$lines.Add($line) }
    return $lines
}

function Write-Ok    { param([string]$Text) Write-Host ('      [x] ' + $Text) -ForegroundColor Green }
function Write-Warn  { param([string]$Text) Write-Host ('      [!] ' + $Text) -ForegroundColor Yellow }
function Write-Fail  { param([string]$Text) Write-Host ('      [X] ' + $Text) -ForegroundColor Red }
function Write-Dim   { param([string]$Text) Write-Host ('      ' + $Text) -ForegroundColor DarkGray }

function Write-Info {
    param([string]$Text)
    foreach ($line in (Split-Wrapped $Text)) { Write-Host ('      ' + $line) -ForegroundColor Gray }
}

function Write-Bullet {
    <# Like Write-Info but hangs the wrapped continuation under the text, not
       under the dash. #>
    param([string]$Text)
    $lines = @(Split-Wrapped $Text 64)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $prefix = if ($i -eq 0) { '      - ' } else { '        ' }
        Write-Host ($prefix + $lines[$i]) -ForegroundColor Gray
    }
}

function Write-Pair {
    param([string]$Label, [string]$Value, [string]$Color = 'Gray')
    Write-Host ('      {0,-26} ' -f $Label) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Write-Credit {
    Write-Host ''
    Write-Host ('  ' + (T 'wiz.credit')) -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Shared operations
# ---------------------------------------------------------------------------

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

function Test-InOneDrive {
    param([string]$Path)
    foreach ($name in 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') {
        $root = [Environment]::GetEnvironmentVariable($name)
        if ($root -and $Path.ToLowerInvariant().StartsWith($root.ToLowerInvariant())) { return $true }
    }
    return $false
}

function Set-OneDrivePin {
    <#
        Ask OneDrive to keep the files on disk. With Files On-Demand a synced file
        can be a cloud placeholder, and Windows would try to start the app at logon
        before OneDrive has had a chance to hydrate it.

        attrib.exe is a native executable: a failure sets $LASTEXITCODE but never
        throws, so a try/catch around it would never fire. That is what used to make
        this report success on machines that have no OneDrive at all.
    #>
    param([string]$Path)

    if (-not (Test-InOneDrive $Path)) { return 'skip' }
    try {
        $global:LASTEXITCODE = 0
        attrib.exe +P -U "$Path\*" /s /d 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return 'ok' }
        return 'fail'
    } catch {
        return 'fail'
    }
}

function Remove-InternetMark {
    param([string]$Path)
    $unblocked = 0
    Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        if (Get-Content -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
            Unblock-File -LiteralPath $_.FullName
            $unblocked++
        }
    }
    return $unblocked
}

function Get-RunCommand {
    param([string]$Path)
    $vbs  = Join-Path $Path 'launch.vbs'
    $tray = Join-Path $Path 'tray.ps1'
    if (Test-Path -LiteralPath $vbs) { return ('wscript.exe "{0}"' -f $vbs) }
    return ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $tray)
}

function Start-Tray {
    param([string]$Path)
    $vbs = Join-Path $Path 'launch.vbs'
    if (Test-Path -LiteralPath $vbs) {
        Start-Process wscript.exe -ArgumentList "`"$vbs`""
    } else {
        Start-Process powershell.exe -ArgumentList `
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f (Join-Path $Path 'tray.ps1'))
    }
}

function Invoke-Preflight {
    <# Returns $true when the app can run here. Prints one line per check. #>
    $ok = $true

    $os = [Environment]::OSVersion.Version
    Write-Pair (T 'wiz.check.os') ('{0}.{1}.{2}' -f $os.Major, $os.Minor, $os.Build) 'Green'

    Write-Pair (T 'wiz.check.ps') ([string]$PSVersionTable.PSVersion) 'Green'

    $mode = $ExecutionContext.SessionState.LanguageMode
    if ($mode -eq 'FullLanguage') {
        Write-Pair (T 'wiz.check.lang') ([string]$mode) 'Green'
    } else {
        Write-Pair (T 'wiz.check.lang') ([string]$mode) 'Red'
        Write-Fail (T 'wiz.check.langfail')
        $ok = $false
    }

    $policy = Get-ExecutionPolicy
    if ($policy -eq 'AllSigned') {
        Write-Pair (T 'wiz.check.policy') ([string]$policy) 'Yellow'
        Write-Warn (T 'wiz.check.policywarn')
    } else {
        Write-Pair (T 'wiz.check.policy') ([string]$policy) 'Green'
    }

    if (Test-Path -LiteralPath (Join-Path $SourceDir 'tray.ps1')) {
        Write-Pair (T 'wiz.check.files') (T 'wiz.check.ok') 'Green'
    } else {
        Write-Pair (T 'wiz.check.files') (T 'wiz.check.fail') 'Red'
        Write-Fail (T 'wiz.check.filesfail')
        $ok = $false
    }

    return $ok
}

function Show-Plan {
    <# Returns the plan object; prints it and explains what it means. #>
    $plan = Get-ClaudePlan
    $color = 'Green'
    if (-not $plan.Usable) { $color = 'Red' } elseif ($plan.Expired) { $color = 'Yellow' }

    Write-Host '      ' -NoNewline
    Write-Host ((T 'wiz.plan.found') -f $plan.PlanName) -ForegroundColor $color
    if ($plan.Tier) { Write-Dim ((T 'wiz.plan.tier') -f $plan.Tier) }
    Write-Host ''
    Write-Info $plan.Detail
    return $plan
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if ($Uninstall) {
    Write-Banner
    Write-Host ''
    Write-Host ('  ' + (T 'wiz.uninst.header')) -ForegroundColor Cyan
    Write-Host ''

    $stopped = Stop-Tray
    Write-Ok ((T 'wiz.run.stopped') -f $stopped)

    if (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $RunKey -Name $RunValue
        Write-Ok (T 'wiz.uninst.run')
    } else {
        Write-Dim (T 'wiz.uninst.norun')
    }

    Write-Host ''
    Write-Info (T 'wiz.uninst.files')
    Write-Dim $SourceDir
    if (Test-Path -LiteralPath $DefaultDir) { Write-Dim $DefaultDir }
    Write-Info (T 'wiz.uninst.cache')
    Write-Dim $StateDir
    Write-Info (T 'wiz.uninst.manual')
    Write-Credit
    return
}

# ---------------------------------------------------------------------------
# Repair — checks and rewires, copies nothing
# ---------------------------------------------------------------------------

if ($Repair) {
    $script:StepTotal = 4
    Write-Banner

    $AppDir = $SourceDir
    if ((Test-Path -LiteralPath (Join-Path $DefaultDir 'tray.ps1')) -and -not $InPlace) {
        $AppDir = $DefaultDir
    }

    Write-Step 'wiz.repair.header'
    Write-Pair (T 'wiz.done.installed') $AppDir

    Write-Step 'wiz.check.header'
    if (-not (Invoke-Preflight)) { Write-Credit; exit 1 }

    Write-Step 'wiz.plan.header'
    $plan = Show-Plan

    Write-Step 'wiz.run.header'
    $unblocked = Remove-InternetMark $AppDir
    Write-Ok ((T 'wiz.run.unblock') -f $unblocked)
    New-ItemProperty -Path $RunKey -Name $RunValue -Value (Get-RunCommand $AppDir) `
        -PropertyType String -Force | Out-Null
    Write-Ok (T 'wiz.run.autostart')
    [void](Stop-Tray)
    Start-Tray $AppDir
    Write-Ok (T 'wiz.run.started')

    Write-Host ''
    Write-Info (T 'wiz.repair.done')
    Write-Pair (T 'wiz.done.log') (Join-Path $StateDir 'tray.log')
    Write-Credit
    return
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

Write-Banner

# ---- Step 1: language -------------------------------------------------------
Write-Step 'wiz.lang.header'
$langName = @{ en = 'English'; es = 'Espanol' }
$detectedName = $langName[$detected]
if (-not $detectedName) { $detectedName = $detected }
Write-Info ((T 'wiz.lang.found') -f $detectedName)

if (-not $Silent -and $Language -eq 'auto') {
    Write-Dim (T 'wiz.lang.ask')
    Write-Host '      > ' -ForegroundColor DarkGray -NoNewline
    $answer = Read-Host
    switch ($answer.Trim().ToLowerInvariant()) {
        'e' { [void](Set-AppLanguage 'en') }
        'en' { [void](Set-AppLanguage 'en') }
        's' { [void](Set-AppLanguage 'es') }
        'es' { [void](Set-AppLanguage 'es') }
    }
}
Write-Ok (T 'wiz.lang.set')

# ---- Step 2: what this is ---------------------------------------------------
Write-Step 'wiz.about.header'
Write-Bullet (T 'wiz.about.1')
Write-Bullet (T 'wiz.about.2')
Write-Bullet (T 'wiz.about.3')
Write-Bullet (T 'wiz.about.4')

# ---- Step 3: can this machine run it? --------------------------------------
Write-Step 'wiz.check.header'
if (-not (Invoke-Preflight)) {
    Write-Host ''
    Write-Info (T 'wiz.plan.abort')
    Write-Credit
    exit 1
}

# ---- Step 4: which plan? ----------------------------------------------------
Write-Step 'wiz.plan.header'
$plan = Show-Plan
if (-not $plan.Usable -and -not $plan.Expired) {
    Write-Host ''
    Write-Fail (T 'wiz.plan.abort')
    Write-Info (T 'wiz.plan.aborthint')
    Write-Credit
    exit 1
}

# ---- Step 5: where -----------------------------------------------------------
Write-Step 'wiz.dest.header'
$AppDir = $DefaultDir
if ($InPlace -or ($SourceDir.TrimEnd('\') -ieq $DefaultDir.TrimEnd('\'))) { $AppDir = $SourceDir }

Write-Pair (T 'wiz.dest.from') $SourceDir
Write-Pair (T 'wiz.dest.to')   $AppDir 'White'
Write-Host ''
if ($AppDir -ieq $SourceDir) {
    Write-Dim (T 'wiz.dest.inplace')
} else {
    Write-Dim (T 'wiz.dest.free')
}
Write-Pair (T 'wiz.dest.state')     $StateDir
Write-Pair (T 'wiz.dest.autostart') ('HKCU\...\Run\' + $RunValue)

# ---- Step 6: what it touches ------------------------------------------------
Write-Step 'wiz.perm.header'
Write-Info (T 'wiz.perm.will')
Write-Dim  ('  + ' + $AppDir)
Write-Dim  ('  + ' + $StateDir)
Write-Dim  ('  + HKCU\Software\Microsoft\Windows\CurrentVersion\Run\' + $RunValue)
Write-Host ''
Write-Info (T 'wiz.perm.never')
Write-Dim  ('  - ' + (T 'wiz.perm.never.1'))
Write-Dim  ('  - ' + (T 'wiz.perm.never.2'))
Write-Dim  ('  - ' + (T 'wiz.perm.never.3'))
Write-Dim  ('  - ' + (T 'wiz.perm.never.4'))

if (-not $Silent) {
    Write-Host ''
    Write-Host ('      ' + (T 'wiz.perm.continue')) -ForegroundColor Yellow
    Write-Host '      > ' -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

# ---- Step 7: do it -----------------------------------------------------------
Write-Step 'wiz.run.header'

if ($AppDir -ieq $SourceDir) {
    Write-Dim (T 'wiz.run.copyskip')
} else {
    if (-not (Test-Path -LiteralPath $AppDir)) {
        New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
    }
    $copied = 0
    foreach ($name in $AppFiles) {
        $from = Join-Path $SourceDir $name
        if (Test-Path -LiteralPath $from) {
            Copy-Item -LiteralPath $from -Destination (Join-Path $AppDir $name) -Force
            $copied++
        }
    }
    $libFrom = Join-Path $SourceDir 'lib'
    if (Test-Path -LiteralPath $libFrom) {
        $libTo = Join-Path $AppDir 'lib'
        if (-not (Test-Path -LiteralPath $libTo)) { New-Item -ItemType Directory -Path $libTo -Force | Out-Null }
        Get-ChildItem -LiteralPath $libFrom -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $libTo $_.Name) -Force
            $copied++
        }
    }
    # Never clobber settings the user already tuned from the tray menu.
    $cfgTo = Join-Path $AppDir 'config.json'
    if (-not (Test-Path -LiteralPath $cfgTo) -and (Test-Path -LiteralPath $configPath)) {
        Copy-Item -LiteralPath $configPath -Destination $cfgTo -Force
        $copied++
    }
    Write-Ok ((T 'wiz.run.copy') -f $copied)
}

$unblocked = Remove-InternetMark $AppDir
Write-Ok ((T 'wiz.run.unblock') -f $unblocked)

switch (Set-OneDrivePin $AppDir) {
    'ok'   { Write-Ok   (T 'wiz.run.pin') }
    'skip' { Write-Dim  (T 'wiz.run.pinskip') }
    'fail' { Write-Warn (T 'wiz.run.pinfail') }
}

# Trust the signing certificate if one was shipped alongside the app. A fresh
# clone has none, so this is skipped entirely for most people.
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
        Write-Ok (T 'wiz.run.cert')
    } catch {
        Write-Warn ((T 'wiz.run.certfail') -f $_.Exception.Message)
    }
}

New-ItemProperty -Path $RunKey -Name $RunValue -Value (Get-RunCommand $AppDir) `
    -PropertyType String -Force | Out-Null
Write-Ok (T 'wiz.run.autostart')

# ---- Step 8: prove it works and finish --------------------------------------
Write-Step 'wiz.test.header'
$trayPath = Join-Path $AppDir 'tray.ps1'
$probe = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $trayPath -Once 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok (T 'wiz.test.ok')
    $probe | ForEach-Object { Write-Dim ('  ' + $_) }
} else {
    Write-Warn (T 'wiz.test.fail')
    $probe | ForEach-Object { Write-Dim ('  ' + $_) }
    Write-Warn (T 'wiz.test.hint')
}

[void](Stop-Tray)
Start-Tray $AppDir
Write-Ok (T 'wiz.run.started')

Write-Host ''
Write-Host ('  ' + (T 'wiz.done.header')) -ForegroundColor Green
Write-Pair (T 'wiz.done.installed') $AppDir 'White'
Write-Pair (T 'wiz.done.log')       (Join-Path $StateDir 'tray.log')
Write-Host ''
Write-Info (T 'wiz.done.look')
Write-Dim  (T 'wiz.done.hidden')
Write-Host ''
Write-Dim  (T 'wiz.done.uninstall')
Write-Dim  (T 'wiz.done.repair')
Write-Credit
