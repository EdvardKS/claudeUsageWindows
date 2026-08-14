<#
.SYNOPSIS
    Claude Usage Tray - shows Claude Code quota usage in the Windows notification area.

.DESCRIPTION
    Draws a 16x16 tray icon with two stacked percentages: current session (5h window)
    on top, current week (all models) below. Left-click opens a detail panel with the
    reset countdowns. Data comes from the same endpoint the `/usage` slash command uses.

    No dependencies beyond Windows PowerShell 5.1 and .NET Framework 4.8, both of which
    ship with every Windows 10/11 install. Nothing is written outside the current user's
    profile.

.PARAMETER Foreground
    Keeps the console window visible and echoes the log to it. For debugging.

.PARAMETER Once
    Fetches usage once, prints the parsed result, and exits without creating a tray icon.

.PARAMETER Preview
    Path to a .png. Renders the real tray icon (magnified) and the real detail panel
    to that file and exits. Useful for checking the look without hunting for the icon.
#>
[CmdletBinding()]
param(
    [switch]$Foreground,
    [switch]$Once,
    [string]$Preview
)

$ErrorActionPreference = 'Stop'
# Version 1.0 on purpose: level 2 errors on absent properties, which the usage
# payload is full of (seven_day_opus, scope, ... are legitimately null or missing).
Set-StrictMode -Version 1.0

# ---------------------------------------------------------------------------
# Native interop
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace ClaudeTray -Name Native -MemberDefinition @'
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
'@

[void][ClaudeTray.Native]::SetProcessDPIAware()

$script:Interactive = -not ($Once -or $Preview)

if (-not $Foreground -and $script:Interactive) {
    $console = [ClaudeTray.Native]::GetConsoleWindow()
    if ($console -ne [IntPtr]::Zero) { [void][ClaudeTray.Native]::ShowWindow($console, 0) }  # SW_HIDE
}

# ---------------------------------------------------------------------------
# Paths, config, logging
# ---------------------------------------------------------------------------

$script:AppDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StateDir   = Join-Path $env:LOCALAPPDATA 'ClaudeUsageTray'
$script:CachePath  = Join-Path $script:StateDir 'last.json'
$script:LogPath    = Join-Path $script:StateDir 'tray.log'
$script:CredPath   = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunValue   = 'ClaudeUsageTray'
$script:UsageUrl   = 'https://api.anthropic.com/api/oauth/usage'

if (-not (Test-Path -LiteralPath $script:StateDir)) {
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
}

# Shared string tables and plan detection. If lib/ is missing the app still runs,
# but every label degrades to its lookup key — visible breakage beats a silent
# crash, and the log says why.
$script:LibLoaded = $false
try {
    . (Join-Path $script:AppDir 'lib\i18n.ps1')
    . (Join-Path $script:AppDir 'lib\plan.ps1')
    $script:LibLoaded = $true
} catch {
    function T { param([string]$Key) return $Key }
    function Set-AppLanguage { param([string]$Language) return 'en' }
    function Get-ClaudePlan { return $null }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Foreground -or -not $script:Interactive) { Write-Host $line }
    try {
        # Keep the log from growing without bound.
        if ((Test-Path -LiteralPath $script:LogPath) -and
            ((Get-Item -LiteralPath $script:LogPath).Length -gt 256KB)) {
            $keep = Get-Content -LiteralPath $script:LogPath -Tail 300
            Set-Content -LiteralPath $script:LogPath -Value $keep -Encoding utf8
        }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
    } catch { }
}

$script:Config = [pscustomobject]@{
    pollSeconds   = 900
    language      = 'auto'
    autoUpdate    = $true
    warnPercent   = 80
    critPercent   = 95
    showScopedRow = $true
    iconOutline   = $true
    colors = [pscustomobject]@{
        normal   = '#3ED16B'
        warning  = '#F5A623'
        critical = '#FF5A5F'
        stale    = '#9AA0A6'
    }
}

$configPath = Join-Path $script:AppDir 'config.json'
if (Test-Path -LiteralPath $configPath) {
    try {
        $userConfig = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        foreach ($prop in $userConfig.PSObject.Properties) {
            if ($prop.Name -eq 'colors' -and $prop.Value) {
                foreach ($c in $prop.Value.PSObject.Properties) {
                    $script:Config.colors | Add-Member -NotePropertyName $c.Name -NotePropertyValue $c.Value -Force
                }
            } else {
                $script:Config | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
            }
        }
    } catch {
        Write-Log "config.json unreadable, using defaults: $($_.Exception.Message)" 'WARN'
    }
}

# 15s is the "real time" setting; anything below that is just wasted requests.
if ($script:Config.pollSeconds -lt 15) { $script:Config.pollSeconds = 15 }

# 'auto' follows the Windows UI language; 'en'/'es' pin it.
$script:Lang = Set-AppLanguage ([string]$script:Config.language)
Write-Log ("language: {0} (config: {1})" -f $script:Lang, $script:Config.language)

# Choices offered in the tray menu, in the order they appear.
$script:PollChoices = @(
    @{ Seconds = 15;   Key = 'poll.realtime' }
    @{ Seconds = 60;   Key = 'poll.min1' }
    @{ Seconds = 120;  Key = 'poll.min2' }
    @{ Seconds = 300;  Key = 'poll.min5' }
    @{ Seconds = 900;  Key = 'poll.min15' }
    @{ Seconds = 1800; Key = 'poll.min30' }
    @{ Seconds = 3600; Key = 'poll.hour1' }
    @{ Seconds = 7200; Key = 'poll.hour2' }
)

function ConvertTo-Color {
    param([string]$Hex, [System.Drawing.Color]$Fallback)
    try { return [System.Drawing.ColorTranslator]::FromHtml($Hex) } catch { return $Fallback }
}

$script:ColNormal   = ConvertTo-Color $script:Config.colors.normal   ([System.Drawing.Color]::FromArgb(62,209,107))
$script:ColWarning  = ConvertTo-Color $script:Config.colors.warning  ([System.Drawing.Color]::FromArgb(245,166,35))
$script:ColCritical = ConvertTo-Color $script:Config.colors.critical ([System.Drawing.Color]::FromArgb(255,90,95))
$script:ColStale    = ConvertTo-Color $script:Config.colors.stale    ([System.Drawing.Color]::FromArgb(154,160,166))

function Get-SeverityColor {
    param($Percent, [bool]$Stale)
    if ($Stale -or $null -eq $Percent) { return $script:ColStale }
    if ($Percent -ge $script:Config.critPercent) { return $script:ColCritical }
    if ($Percent -ge $script:Config.warnPercent) { return $script:ColWarning }
    return $script:ColNormal
}

# ---------------------------------------------------------------------------
# Usage fetching
#
# The work runs in a background runspace so a slow or dead network never freezes
# the tray icon. The runspace re-reads the credential file itself, so no token is
# ever held in a shared variable.
# ---------------------------------------------------------------------------

$script:FetchScript = {
    param([string]$CredPath, [string]$Url)

    $ErrorActionPreference = 'Stop'
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
    } catch { }

    try {
        if (-not (Test-Path -LiteralPath $CredPath)) {
            return @{ ok = $false; error = 'no-credentials' }
        }
        $oauth = (Get-Content -Raw -LiteralPath $CredPath | ConvertFrom-Json).claudeAiOauth
        if (-not $oauth.accessToken) {
            return @{ ok = $false; error = 'no-token' }
        }
        if ($oauth.expiresAt) {
            $expires = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$oauth.expiresAt)
            if ($expires -lt [DateTimeOffset]::UtcNow) {
                # Deliberately not refreshing: rotating the refresh token behind Claude
                # Code's back can invalidate its credentials and force a re-login.
                return @{ ok = $false; error = 'token-expired' }
            }
        }

        $headers = @{
            'Authorization'  = "Bearer $($oauth.accessToken)"
            'anthropic-beta' = 'oauth-2025-04-20'
            'Accept'         = 'application/json'
        }
        $body = Invoke-RestMethod -Uri $Url -Headers $headers -Method Get `
                                  -TimeoutSec 20 -UserAgent 'claude-cli/2.1.220'
        return @{ ok = $true; body = ($body | ConvertTo-Json -Depth 10 -Compress) }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

function ConvertFrom-UsageBody {
    <#
        Normalises the API response into an ordered list of rows.
        Primary source is the `limits` array (what /usage itself renders); the
        top-level five_hour / seven_day buckets are the fallback.
    #>
    param($Body)

    $rows = New-Object System.Collections.ArrayList

    $hasLimits = $false
    if ($Body.PSObject.Properties.Name -contains 'limits' -and $Body.limits) { $hasLimits = $true }

    if ($hasLimits) {
        foreach ($limit in $Body.limits) {
            $label = switch ($limit.kind) {
                'session'       { T 'limit.session' }
                'weekly_all'    { T 'limit.weekly_all' }
                'weekly_scoped' {
                    $name = $null
                    if ($limit.scope -and $limit.scope.model) { $name = $limit.scope.model.display_name }
                    if ($name) { (T 'limit.weekly_scoped') -f $name } else { T 'limit.weekly_generic' }
                }
                default         { [string]$limit.kind }
            }
            # Tooltip needs distinct short names, otherwise both weekly rows read "Week".
            $short = switch ($limit.kind) {
                'session'    { T 'short.session' }
                'weekly_all' { T 'short.weekly' }
                'weekly_scoped' {
                    if ($limit.scope -and $limit.scope.model -and $limit.scope.model.display_name) {
                        $limit.scope.model.display_name
                    } else { T 'short.model' }
                }
                default      { [string]$limit.kind }
            }
            [void]$rows.Add([pscustomobject]@{
                Kind     = [string]$limit.kind
                Label    = $label
                Short    = $short
                Percent  = [double]$limit.percent
                ResetsAt = $limit.resets_at
            })
        }
    } else {
        $fallback = @(
            @{ Kind = 'session';    Bucket = 'five_hour'; Label = (T 'limit.session');    Short = (T 'short.session') },
            @{ Kind = 'weekly_all'; Bucket = 'seven_day'; Label = (T 'limit.weekly_all'); Short = (T 'short.weekly') }
        )
        foreach ($f in $fallback) {
            if ($Body.PSObject.Properties.Name -notcontains $f.Bucket) { continue }
            $bucket = $Body.($f.Bucket)
            if (-not $bucket) { continue }
            [void]$rows.Add([pscustomobject]@{
                Kind     = $f.Kind
                Label    = $f.Label
                Short    = $f.Short
                Percent  = [double]$bucket.utilization
                ResetsAt = $bucket.resets_at
            })
        }
    }

    return $rows
}

function Save-Cache {
    param($Rows)
    try {
        $payload = [pscustomobject]@{
            fetchedAt = (Get-Date).ToString('o')
            rows      = @($Rows)
        }
        # Note: only percentages and reset timestamps. Never the token.
        $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:CachePath -Encoding utf8
    } catch {
        Write-Log "cache write failed: $($_.Exception.Message)" 'WARN'
    }
}

function Restore-Cache {
    try {
        if (-not (Test-Path -LiteralPath $script:CachePath)) { return $null }
        $cached = Get-Content -Raw -LiteralPath $script:CachePath | ConvertFrom-Json
        return [pscustomobject]@{
            FetchedAt = [datetime]$cached.fetchedAt
            Rows      = @($cached.rows)
        }
    } catch { return $null }
}

# Live state shared between the timers and the UI.
$script:Rows        = @()
$script:FetchedAt   = $null
$script:Stale       = $true
$script:LastError   = (T 'err.nodata')
$script:FetchPs     = $null
$script:FetchHandle = $null
$script:PollTimer   = $null
$script:TickTimer   = $null

$restored = Restore-Cache
if ($restored) {
    $script:Rows      = $restored.Rows
    $script:FetchedAt = $restored.FetchedAt
    Write-Log "restored cache from $($restored.FetchedAt)"
}

function Start-Fetch {
    if ($script:FetchHandle) { return }   # already in flight
    try {
        $script:FetchPs = [powershell]::Create()
        [void]$script:FetchPs.AddScript($script:FetchScript)
        [void]$script:FetchPs.AddArgument($script:CredPath)
        [void]$script:FetchPs.AddArgument($script:UsageUrl)
        $script:FetchHandle = $script:FetchPs.BeginInvoke()
        if ($script:TickTimer) { $script:TickTimer.Enabled = $true }
    } catch {
        Write-Log "could not start fetch: $($_.Exception.Message)" 'ERROR'
        [void](Complete-Fetch -Force)
    }
}

function Complete-Fetch {
    param([switch]$Force)

    if (-not $script:FetchHandle) { return $false }
    if (-not $Force -and -not $script:FetchHandle.IsCompleted) { return $false }

    $result = $null
    try {
        if (-not $Force) { $result = $script:FetchPs.EndInvoke($script:FetchHandle) }
    } catch {
        Write-Log "fetch threw: $($_.Exception.Message)" 'ERROR'
    } finally {
        if ($script:FetchPs) { $script:FetchPs.Dispose() }
        $script:FetchPs     = $null
        $script:FetchHandle = $null
    }

    # BeginInvoke returns a collection; unwrap the single hashtable.
    $payload = $null
    if ($result) { foreach ($item in $result) { if ($item -is [hashtable]) { $payload = $item; break } } }

    if ($payload -and $payload.ok) {
        try {
            $body = $payload.body | ConvertFrom-Json
            $rows = ConvertFrom-UsageBody $body
            if ($rows.Count -gt 0) {
                $script:Rows      = @($rows)
                $script:FetchedAt = Get-Date
                $script:Stale     = $false
                $script:LastError = $null
                Save-Cache $script:Rows
                Write-Log ("ok: " + (($rows | ForEach-Object { "$($_.Kind)=$($_.Percent)%" }) -join ' '))
            } else {
                $script:Stale     = $true
                $script:LastError = (T 'err.nolimits')
                Write-Log 'response contained no limit rows' 'WARN'
            }
        } catch {
            $script:Stale     = $true
            $script:LastError = (T 'err.unreadable')
            Write-Log "parse failed: $($_.Exception.Message)" 'ERROR'
        }
    } else {
        $script:Stale = $true
        $err = if ($payload) { [string]$payload.error } else { (T 'err.noresponse') }
        $script:LastError = switch ($err) {
            'no-credentials' { T 'err.login' }
            'no-token'       { T 'err.login' }
            'token-expired'  { T 'err.expired' }
            default          { $err }
        }
        Write-Log "fetch failed: $err" 'WARN'
    }

    Update-Ui
    return $true
}

function Get-Row {
    param([string]$Kind)
    foreach ($row in $script:Rows) { if ($row.Kind -eq $Kind) { return $row } }
    return $null
}

function Get-VisibleKinds {
    $kinds = New-Object System.Collections.ArrayList
    foreach ($kind in @('session', 'weekly_all', 'weekly_scoped')) {
        $row = Get-Row $kind
        if (-not $row) { continue }
        if ($kind -eq 'weekly_scoped') {
            # The per-model row only earns its space once that model has been used.
            if (-not $script:Config.showScopedRow -or $row.Percent -le 0) { continue }
        }
        [void]$kinds.Add($kind)
    }
    return $kinds
}

function Format-Reset {
    param($ResetsAt)
    if (-not $ResetsAt) { return (T 'reset.none') }
    try {
        $when = [datetimeoffset]::Parse([string]$ResetsAt).ToLocalTime()
        $span = $when - [datetimeoffset]::Now
        if ($span.TotalSeconds -le 0) { return (T 'reset.imminent') }
        if ($span.TotalDays -ge 1) { return ((T 'reset.days') -f [int]$span.TotalDays, $span.Hours) }
        if ($span.TotalHours -ge 1) { return ((T 'reset.hours') -f [int]$span.TotalHours, $span.Minutes) }
        return ((T 'reset.minutes') -f [math]::Max(1, [int]$span.TotalMinutes))
    } catch { return (T 'reset.invalid') }
}

function Format-ResetShort {
    # Compact form for the tooltip, which .NET caps at 63 characters.
    param($ResetsAt)
    if (-not $ResetsAt) { return '?' }
    try {
        $span = [datetimeoffset]::Parse([string]$ResetsAt).ToLocalTime() - [datetimeoffset]::Now
        if ($span.TotalSeconds -le 0) { return (T 'short.now') }
        if ($span.TotalDays -ge 1)  { return ('{0}d{1}h' -f [int]$span.TotalDays, $span.Hours) }
        if ($span.TotalHours -ge 1) { return ('{0}h{1}m' -f [int]$span.TotalHours, $span.Minutes) }
        return ('{0}m' -f [math]::Max(1, [int]$span.TotalMinutes))
    } catch { return '?' }
}

# ---------------------------------------------------------------------------
# Tray icon rendering
#
# The notification area gives us 16x16 physical pixels. Antialiased TrueType text
# at that size is unreadable, so digits come from hand-built pixel fonts: a 5x7
# face for one and two digits (the normal case) and a narrow 3x5 face for three,
# since 3 x 5px glyphs would not fit across 16 pixels.
# ---------------------------------------------------------------------------

$script:Font5x7 = @{
    '0' = @('01110','10001','10001','10001','10001','10001','01110')
    '1' = @('00100','01100','00100','00100','00100','00100','01110')
    '2' = @('01110','10001','00001','00010','00100','01000','11111')
    '3' = @('11111','00010','00100','00010','00001','10001','01110')
    '4' = @('00010','00110','01010','10010','11111','00010','00010')
    '5' = @('11111','10000','11110','00001','00001','10001','01110')
    '6' = @('00110','01000','10000','11110','10001','10001','01110')
    '7' = @('11111','00001','00010','00100','01000','01000','01000')
    '8' = @('01110','10001','10001','01110','10001','10001','01110')
    '9' = @('01110','10001','10001','01111','00001','00010','01100')
    '-' = @('00000','00000','00000','11111','00000','00000','00000')
}

$script:Font3x5 = @{
    '0' = @('111','101','101','101','111'); '1' = @('010','110','010','010','111')
    '2' = @('111','001','111','100','111'); '3' = @('111','001','111','001','111')
    '4' = @('101','101','111','001','001'); '5' = @('111','100','111','001','111')
    '6' = @('111','100','111','101','111'); '7' = @('111','001','010','010','010')
    '8' = @('111','101','111','101','111'); '9' = @('111','101','111','001','111')
    '-' = @('000','000','111','000','000')
}

function Write-GlyphRow {
    <#
        Draws $Text centred horizontally, vertically centred inside a 7px band
        starting at $BandTop. Returns nothing; paints straight into the bitmap.
    #>
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Text,
        [int]$BandTop,
        [System.Drawing.Color]$Color,
        [bool]$Outline
    )

    $chars = $Text.ToCharArray()
    if ($chars.Count -ge 3) {
        $font = $script:Font3x5; $gw = 3; $gh = 5
    } else {
        $font = $script:Font5x7; $gw = 5; $gh = 7
    }

    $width = ($chars.Count * $gw) + ($chars.Count - 1)
    $x0    = [int][math]::Floor((16 - $width) / 2)
    $y0    = $BandTop + [int][math]::Floor((7 - $gh) / 2)

    # Collect the lit pixels first so the outline can be laid down underneath them.
    $lit = New-Object System.Collections.Generic.HashSet[int]
    $x = $x0
    foreach ($ch in $chars) {
        $glyph = $font[[string]$ch]
        if ($glyph) {
            for ($row = 0; $row -lt $gh; $row++) {
                for ($col = 0; $col -lt $gw; $col++) {
                    if ($glyph[$row][$col] -eq '1') {
                        $px = $x + $col; $py = $y0 + $row
                        if ($px -ge 0 -and $px -lt 16 -and $py -ge 0 -and $py -lt 16) {
                            [void]$lit.Add(($py * 16) + $px)
                        }
                    }
                }
            }
        }
        $x += $gw + 1
    }

    # A translucent dark halo keeps the digits readable on a light taskbar.
    if ($Outline) {
        $halo = [System.Drawing.Color]::FromArgb(170, 0, 0, 0)
        $ring = New-Object System.Collections.Generic.HashSet[int]
        foreach ($key in $lit) {
            $px = $key % 16; $py = [int][math]::Floor($key / 16)
            foreach ($dx in -1, 0, 1) {
                foreach ($dy in -1, 0, 1) {
                    $nx = $px + $dx; $ny = $py + $dy
                    if ($nx -lt 0 -or $nx -ge 16 -or $ny -lt 0 -or $ny -ge 16) { continue }
                    $nkey = ($ny * 16) + $nx
                    if (-not $lit.Contains($nkey)) { [void]$ring.Add($nkey) }
                }
            }
        }
        foreach ($key in $ring) {
            $Bitmap.SetPixel(($key % 16), [int][math]::Floor($key / 16), $halo)
        }
    }

    foreach ($key in $lit) {
        $Bitmap.SetPixel(($key % 16), [int][math]::Floor($key / 16), $Color)
    }
}

function Format-IconNumber {
    param($Percent)
    if ($null -eq $Percent) { return '-' }
    $value = [int][math]::Round([double]$Percent)
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 999) { $value = 999 }
    return [string]$value
}

function New-TrayIcon {
    param($TopPercent, $BottomPercent, [bool]$Stale)

    $outline = [bool]$script:Config.iconOutline
    $bmp = New-Object System.Drawing.Bitmap 16, 16, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        # Two 7px bands with a 2px gutter: rows 0-6 and 9-15.
        Write-GlyphRow -Bitmap $bmp -Text (Format-IconNumber $TopPercent) -BandTop 0 `
                       -Color (Get-SeverityColor $TopPercent $Stale) -Outline $outline
        Write-GlyphRow -Bitmap $bmp -Text (Format-IconNumber $BottomPercent) -BandTop 9 `
                       -Color (Get-SeverityColor $BottomPercent $Stale) -Outline $outline

        $handle = $bmp.GetHicon()
        return [pscustomobject]@{
            Icon   = [System.Drawing.Icon]::FromHandle($handle)
            Handle = $handle
        }
    } finally {
        $bmp.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Detail panel
#
# Controls are created once per data shape and then only have their text and
# widths updated. Rebuilding them on every tick is what caused the flicker.
# ---------------------------------------------------------------------------

$script:PanelBg     = [System.Drawing.Color]::FromArgb(32, 33, 36)
$script:PanelBorder = [System.Drawing.Color]::FromArgb(70, 72, 76)
$script:TextMain    = [System.Drawing.Color]::FromArgb(235, 236, 238)
$script:TextDim     = [System.Drawing.Color]::FromArgb(150, 152, 157)
$script:TrackColor  = [System.Drawing.Color]::FromArgb(58, 60, 64)
$script:PanelWidth  = 290
$script:BarWidth    = 258

function Set-DoubleBuffered {
    param([System.Windows.Forms.Control]$Control)
    try {
        $prop = [System.Windows.Forms.Control].GetProperty(
            'DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $prop.SetValue($Control, $true, $null)
    } catch { }
}

$script:Panel = New-Object System.Windows.Forms.Form
$script:Panel.FormBorderStyle = 'None'
$script:Panel.ShowInTaskbar   = $false
$script:Panel.TopMost         = $true
$script:Panel.StartPosition   = 'Manual'
$script:Panel.BackColor       = $script:PanelBg
$script:Panel.Width           = $script:PanelWidth
$script:Panel.Height          = 200
$script:Panel.Visible         = $false
Set-DoubleBuffered $script:Panel

$script:Panel.Add_Paint({
    param($sender, $e)
    $pen = New-Object System.Drawing.Pen $script:PanelBorder
    try {
        $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
    } finally { $pen.Dispose() }
})

$script:PanelHiddenAt = [datetime]::MinValue
$script:Panel.Add_Deactivate({
    $script:Panel.Hide()
    $script:PanelHiddenAt = Get-Date
    if ($script:TickTimer -and -not $script:FetchHandle) { $script:TickTimer.Enabled = $false }
})

# Cached control references, keyed by limit kind.
$script:PanelControls = @{}
$script:PanelHeader   = $null
$script:PanelStatus   = $null
$script:PanelBuiltFor = $null

$script:PlanCache   = $null
$script:PlanCachedAt = [datetime]::MinValue

function Get-PlanCaption {
    <# Which subscription these numbers belong to. Read from the local credential
       file, so it costs no request; re-read every 5 minutes in case the user
       switches plans or signs in again while the tray is running. #>
    if (-not $script:LibLoaded) { return '' }
    if (-not $script:PlanCache -or ((Get-Date) - $script:PlanCachedAt).TotalMinutes -gt 5) {
        try {
            $script:PlanCache    = Get-ClaudePlan -CredPath $script:CredPath
            $script:PlanCachedAt = Get-Date
        } catch {
            return ''
        }
    }
    if (-not $script:PlanCache) { return '' }
    if ($script:PlanCache.Expired) {
        return ('{0} - {1}' -f $script:PlanCache.PlanName, (T 'plan.expired'))
    }
    return [string]$script:PlanCache.PlanName
}

function New-PanelLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height,
          [System.Drawing.Color]$Color, [single]$Size, [string]$Style = 'Regular',
          [string]$Align = 'MiddleLeft')
    $label = New-Object System.Windows.Forms.Label
    $label.Text      = $Text
    $label.AutoSize  = $false
    $label.Location  = New-Object System.Drawing.Point $X, $Y
    $label.Size      = New-Object System.Drawing.Size $Width, $Height
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.Font      = New-Object System.Drawing.Font 'Segoe UI', $Size, ([System.Drawing.FontStyle]::$Style)
    $label.TextAlign = [System.Drawing.ContentAlignment]::$Align
    return $label
}

function Build-Panel {
    param($Kinds)

    $script:Panel.SuspendLayout()
    foreach ($control in @($script:Panel.Controls)) {
        $script:Panel.Controls.Remove($control)
        $control.Dispose()
    }
    $script:PanelControls = @{}

    $y = 12
    $script:Panel.Controls.Add((New-PanelLabel (T 'panel.title') 16 $y 150 18 $script:TextMain 10 'Bold'))
    $script:PanelHeader = New-PanelLabel '' 130 $y 144 18 $script:TextDim 8 'Regular' 'MiddleRight'
    $script:Panel.Controls.Add($script:PanelHeader)
    $y += 18

    # Which plan these numbers belong to. Read locally, costs no extra request.
    $script:PanelPlan = New-PanelLabel (Get-PlanCaption) 16 $y 258 14 $script:TextDim 7.5
    $script:Panel.Controls.Add($script:PanelPlan)
    $y += 20

    foreach ($kind in $Kinds) {
        $row = Get-Row $kind

        $nameLabel = New-PanelLabel $row.Label 16 $y 180 20 $script:TextMain 9
        $pctLabel  = New-PanelLabel '' 170 ($y - 4) 104 26 $script:TextMain 14 'Bold' 'MiddleRight'
        $script:Panel.Controls.Add($nameLabel)
        $script:Panel.Controls.Add($pctLabel)
        $y += 22

        $track = New-Object System.Windows.Forms.Panel
        $track.Location  = New-Object System.Drawing.Point 16, $y
        $track.Size      = New-Object System.Drawing.Size $script:BarWidth, 5
        $track.BackColor = $script:TrackColor
        $fill = New-Object System.Windows.Forms.Panel
        $fill.Location   = New-Object System.Drawing.Point 0, 0
        $fill.Size       = New-Object System.Drawing.Size 0, 5
        $track.Controls.Add($fill)
        $script:Panel.Controls.Add($track)
        $y += 11

        $resetLabel = New-PanelLabel '' 16 $y $script:BarWidth 16 $script:TextDim 8
        $script:Panel.Controls.Add($resetLabel)
        $y += 24

        $script:PanelControls[$kind] = @{
            Name = $nameLabel; Pct = $pctLabel; Fill = $fill; Reset = $resetLabel
        }
    }

    if ($Kinds.Count -eq 0) {
        $script:Panel.Controls.Add((New-PanelLabel (T 'panel.empty') 16 $y 258 18 $script:TextDim 9))
        $y += 24
    }

    $script:PanelStatus = New-PanelLabel '' 16 $y 258 16 $script:ColStale 8
    $script:PanelStatus.Visible = $false
    $script:Panel.Controls.Add($script:PanelStatus)

    # Discreet credit, in the same grey the app uses for "no data" so it never
    # competes with the percentages. Underlines on hover, opens the site on click.
    $script:PanelCredit = New-PanelLabel 'developed by iaeks.com' 16 $y 258 14 `
                              $script:ColStale 7 'Regular' 'MiddleRight'
    $script:PanelCredit.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:PanelCredit.Add_MouseEnter({
        $this.ForeColor = $script:TextDim
        $this.Font = New-Object System.Drawing.Font 'Segoe UI', 7, ([System.Drawing.FontStyle]::Underline)
    })
    $script:PanelCredit.Add_MouseLeave({
        $this.ForeColor = $script:ColStale
        $this.Font = New-Object System.Drawing.Font 'Segoe UI', 7, ([System.Drawing.FontStyle]::Regular)
    })
    $script:PanelCredit.Add_Click({
        try { Start-Process 'https://iaeks.com' } catch { Write-Log "could not open site: $($_.Exception.Message)" 'WARN' }
    })
    $script:Panel.Controls.Add($script:PanelCredit)

    $script:PanelBaseHeight = $y
    $script:Panel.ResumeLayout()
}

function Update-Panel {
    $kinds = @(Get-VisibleKinds)
    $signature = ($kinds -join '|')

    if ($signature -ne $script:PanelBuiltFor) {
        Build-Panel $kinds
        $script:PanelBuiltFor = $signature
    }

    $header = if ($script:FetchedAt) {
        if ($script:Stale) { (T 'panel.offline') -f $script:FetchedAt.ToString('HH:mm') }
        else { (T 'panel.updated') -f $script:FetchedAt.ToString('HH:mm') }
    } else { T 'panel.nodata' }
    # Assigning an identical string is a no-op in WinForms, so unchanged labels
    # never repaint. That is what keeps the panel from flickering every second.
    if ($script:PanelHeader.Text -ne $header) { $script:PanelHeader.Text = $header }

    foreach ($kind in $kinds) {
        $row  = Get-Row $kind
        $ctl  = $script:PanelControls[$kind]
        if (-not $ctl) { continue }

        $percent = [double]$row.Percent
        $color   = Get-SeverityColor $percent $script:Stale
        $pctText = '{0}%' -f [int][math]::Round($percent)
        $resText = Format-Reset $row.ResetsAt
        $fillW   = [int][math]::Round($script:BarWidth * ([math]::Min(100, [math]::Max(0, $percent)) / 100))

        if ($ctl.Name.Text      -ne $row.Label) { $ctl.Name.Text = $row.Label }
        if ($ctl.Pct.Text       -ne $pctText)   { $ctl.Pct.Text = $pctText }
        if ($ctl.Pct.ForeColor  -ne $color)     { $ctl.Pct.ForeColor = $color }
        if ($ctl.Reset.Text     -ne $resText)   { $ctl.Reset.Text = $resText }
        if ($ctl.Fill.BackColor -ne $color)     { $ctl.Fill.BackColor = $color }
        if ($ctl.Fill.Width     -ne $fillW)     { $ctl.Fill.Width = $fillW }
    }

    $showStatus = [bool]($script:Stale -and $script:LastError)
    if ($script:PanelStatus.Visible -ne $showStatus) { $script:PanelStatus.Visible = $showStatus }
    if ($showStatus -and $script:PanelStatus.Text -ne $script:LastError) {
        $script:PanelStatus.Text = $script:LastError
    }

    $plan = Get-PlanCaption
    if ($script:PanelPlan -and $script:PanelPlan.Text -ne $plan) { $script:PanelPlan.Text = $plan }

    # The credit sits under whichever of the two is last: the error line when it is
    # showing, the final limit row otherwise.
    $creditTop = $script:PanelBaseHeight + $(if ($showStatus) { 22 } else { 2 })
    if ($script:PanelCredit.Top -ne $creditTop) { $script:PanelCredit.Top = $creditTop }

    $height = $creditTop + 22
    if ($script:Panel.Height -ne $height) { $script:Panel.Height = $height }
}

function Show-Panel {
    # Clicking the icon while the panel is open fires Deactivate first; without this
    # guard the click would immediately reopen what the user meant to close.
    if (((Get-Date) - $script:PanelHiddenAt).TotalMilliseconds -lt 300) { return }

    Update-Panel

    $cursor = [System.Windows.Forms.Cursor]::Position
    $work   = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea

    $x = $cursor.X - [int]($script:Panel.Width / 2)
    $y = $cursor.Y - $script:Panel.Height - 12
    if ($x + $script:Panel.Width -gt $work.Right) { $x = $work.Right - $script:Panel.Width - 8 }
    if ($x -lt $work.Left) { $x = $work.Left + 8 }
    if ($y -lt $work.Top) { $y = $cursor.Y + 16 }
    if ($y + $script:Panel.Height -gt $work.Bottom) { $y = $work.Bottom - $script:Panel.Height - 8 }

    $script:Panel.Location = New-Object System.Drawing.Point $x, $y
    $script:Panel.Show()
    $script:Panel.Activate()

    if ($script:TickTimer) { $script:TickTimer.Enabled = $true }

    # Opening the panel is a good moment to top up a stale reading.
    if (-not $script:FetchedAt -or ((Get-Date) - $script:FetchedAt).TotalSeconds -gt 60) {
        Start-Fetch
    }
}

# ---------------------------------------------------------------------------
# Tray icon wiring
# ---------------------------------------------------------------------------

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:IconHandle = [IntPtr]::Zero

function Get-TooltipText {
    # NotifyIcon.Text is hard-capped at 63 characters; anything longer throws and
    # the tooltip silently keeps whatever it had before. Hence the compact form.
    $lines = New-Object System.Collections.ArrayList
    foreach ($kind in @(Get-VisibleKinds)) {
        $row = Get-Row $kind
        [void]$lines.Add(('{0} {1}% - {2}' -f $row.Short, [int][math]::Round($row.Percent), (Format-ResetShort $row.ResetsAt)))
    }
    if ($lines.Count -eq 0) {
        [void]$lines.Add($(if ($script:LastError) { $script:LastError } else { T 'panel.nodata' }))
    } elseif ($script:Stale) {
        [void]$lines.Add((T 'tip.offline'))
    }

    $text = ($lines -join "`n")
    while ($text.Length -gt 63 -and $lines.Count -gt 1) {
        $lines.RemoveAt($lines.Count - 1)
        $text = ($lines -join "`n")
    }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    return $text
}

function Update-Ui {
    $session = Get-Row 'session'
    $weekly  = Get-Row 'weekly_all'
    $topPct    = if ($session) { $session.Percent } else { $null }
    $bottomPct = if ($weekly)  { $weekly.Percent }  else { $null }

    $created = New-TrayIcon $topPct $bottomPct $script:Stale
    $previousIcon   = $script:NotifyIcon.Icon
    $previousHandle = $script:IconHandle

    $script:NotifyIcon.Icon = $created.Icon
    $script:IconHandle      = $created.Handle

    # GetHicon hands us an unmanaged handle the GC will never reclaim. Releasing the
    # previous one on every refresh is what keeps this from leaking GDI handles.
    if ($previousIcon) { $previousIcon.Dispose() }
    if ($previousHandle -ne [IntPtr]::Zero) { [void][ClaudeTray.Native]::DestroyIcon($previousHandle) }

    try {
        $tip = Get-TooltipText
        if ($script:NotifyIcon.Text -ne $tip) { $script:NotifyIcon.Text = $tip }
    } catch {
        Write-Log "tooltip update failed: $($_.Exception.Message)" 'WARN'
    }

    if ($script:Panel.Visible) { Update-Panel }
}

function Test-AutoStart {
    try {
        $entry = Get-ItemProperty -Path $script:RunKey -Name $script:RunValue -ErrorAction Stop
        return [bool]$entry.$($script:RunValue)
    } catch { return $false }
}

function Set-AutoStart {
    param([bool]$Enabled)
    try {
        if ($Enabled) {
            $vbs = Join-Path $script:AppDir 'launch.vbs'
            $command = if (Test-Path -LiteralPath $vbs) {
                'wscript.exe "{0}"' -f $vbs
            } else {
                'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $script:AppDir 'tray.ps1')
            }
            # HKCU only: this never touches other users or the machine-wide hive.
            New-ItemProperty -Path $script:RunKey -Name $script:RunValue -Value $command `
                             -PropertyType String -Force | Out-Null
            Write-Log 'autostart enabled'
        } else {
            Remove-ItemProperty -Path $script:RunKey -Name $script:RunValue -ErrorAction SilentlyContinue
            Write-Log 'autostart disabled'
        }
    } catch {
        Write-Log "autostart toggle failed: $($_.Exception.Message)" 'ERROR'
    }
}

function Save-ConfigValue {
    param([string]$Name, $Value)
    try {
        $existing = [ordered]@{}
        if (Test-Path -LiteralPath $configPath) {
            $current = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
            foreach ($prop in $current.PSObject.Properties) { $existing[$prop.Name] = $prop.Value }
        }
        $existing[$Name] = $Value
        ([pscustomobject]$existing | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath $configPath -Encoding utf8
        # Our own write must not look like a synced update, or the self-updater
        # would restart the app every time a setting changes.
        $script:SourceStamp  = Get-SourceStamp
        $script:PendingStamp = $null
        Write-Log "config $Name = $Value"
    } catch {
        Write-Log "could not save config: $($_.Exception.Message)" 'WARN'
    }
}

function Set-PollInterval {
    param([int]$Seconds)
    $script:Config.pollSeconds = $Seconds
    if ($script:PollTimer) {
        $script:PollTimer.Stop()
        $script:PollTimer.Interval = $Seconds * 1000
        $script:PollTimer.Start()
    }
    Save-ConfigValue 'pollSeconds' $Seconds
    foreach ($item in $script:PollMenuItems) {
        $item.Checked = ($item.Tag -eq $Seconds)
    }
    Start-Fetch
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miRefresh = $menu.Items.Add((T 'menu.refresh'))
$miRefresh.Add_Click({ Start-Fetch })

$miFrequency = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.frequency')
$script:PollMenuItems = @()
foreach ($choice in $script:PollChoices) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem (T $choice.Key)
    $item.Tag     = $choice.Seconds
    $item.Checked = ($choice.Seconds -eq $script:Config.pollSeconds)
    $item.Add_Click({ Set-PollInterval ([int]$this.Tag) }.GetNewClosure())
    [void]$miFrequency.DropDownItems.Add($item)
    $script:PollMenuItems += $item
}
[void]$menu.Items.Add($miFrequency)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miLanguage = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.language')
foreach ($choice in @(
    @{ Value = 'auto'; Label = (T 'menu.lang.auto') }
    @{ Value = 'en';   Label = 'English' }
    @{ Value = 'es';   Label = 'Espanol' }
)) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $choice.Label
    $item.Tag     = $choice.Value
    $item.Checked = ([string]$script:Config.language -eq $choice.Value)
    # Switching language rebuilds every label, menu item and tooltip. Restarting is
    # both simpler and less error-prone than re-theming the live controls.
    $item.Add_Click({
        Save-ConfigValue 'language' ([string]$this.Tag)
        Restart-Self
    }.GetNewClosure())
    [void]$miLanguage.DropDownItems.Add($item)
}
[void]$menu.Items.Add($miLanguage)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miFolder = $menu.Items.Add((T 'menu.folder'))
$miFolder.Add_Click({ Start-Process explorer.exe $script:AppDir })

$miLog = $menu.Items.Add((T 'menu.log'))
$miLog.Add_Click({
    if (Test-Path -LiteralPath $script:LogPath) { Start-Process notepad.exe $script:LogPath }
})

$script:MiAutoStart = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.autostart')
$script:MiAutoStart.CheckOnClick = $false
$script:MiAutoStart.Checked = Test-AutoStart
$script:MiAutoStart.Add_Click({
    Set-AutoStart (-not $script:MiAutoStart.Checked)
    $script:MiAutoStart.Checked = Test-AutoStart
})
[void]$menu.Items.Add($script:MiAutoStart)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miExit = $menu.Items.Add((T 'menu.exit'))
$miExit.Add_Click({ [System.Windows.Forms.Application]::Exit() })

$script:NotifyIcon.ContextMenuStrip = $menu
$script:NotifyIcon.Add_MouseUp({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($script:Panel.Visible) { $script:Panel.Hide() } else { Show-Panel }
    }
})

# ---------------------------------------------------------------------------
# Diagnostic modes
# ---------------------------------------------------------------------------

function Invoke-FetchSync {
    <# Blocking fetch for the non-interactive modes, where there is no message loop. #>
    Start-Fetch
    $deadline = (Get-Date).AddSeconds(30)
    while ($script:FetchHandle -and -not $script:FetchHandle.IsCompleted -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    $timedOut = [bool]($script:FetchHandle -and -not $script:FetchHandle.IsCompleted)
    return Complete-Fetch -Force:$timedOut
}

if ($Once) {
    [void](Invoke-FetchSync)
    if ($script:Stale) {
        "FALLO: $script:LastError"
        exit 1
    }
    foreach ($row in $script:Rows) {
        '{0,-32} {1,5}%  {2}' -f $row.Label, [int][math]::Round($row.Percent), (Format-Reset $row.ResetsAt)
    }
    'tooltip: ' + (Get-TooltipText).Replace("`n", ' | ')
    exit 0
}

if ($Preview) {
    [void](Invoke-FetchSync)
    Update-Panel

    # DrawToBitmap only captures child controls once their handles exist and have
    # painted, so the form is briefly shown off-screen.
    $script:Panel.Location = New-Object System.Drawing.Point -4000, -4000
    $script:Panel.Show()
    $script:Panel.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $panelBmp = New-Object System.Drawing.Bitmap $script:Panel.Width, $script:Panel.Height
    $script:Panel.DrawToBitmap($panelBmp, (New-Object System.Drawing.Rectangle 0, 0, $script:Panel.Width, $script:Panel.Height))
    $script:Panel.Hide()

    $session = Get-Row 'session'
    $weekly  = Get-Row 'weekly_all'
    $created = New-TrayIcon $(if ($session) { $session.Percent } else { $null }) `
                            $(if ($weekly)  { $weekly.Percent }  else { $null }) $script:Stale
    $iconBmp = $created.Icon.ToBitmap()

    $zoom = 11
    $pad  = 18
    $outW = ($pad * 3) + (16 * $zoom) + $panelBmp.Width
    $outH = ($pad * 2) + [math]::Max(16 * $zoom, $panelBmp.Height)
    $out  = New-Object System.Drawing.Bitmap $outW, $outH
    $g    = [System.Drawing.Graphics]::FromImage($out)
    try {
        $g.Clear([System.Drawing.Color]::FromArgb(22, 23, 25))
        # Nearest-neighbour so the magnified icon shows the actual pixels.
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $g.DrawImage($iconBmp, $pad, $pad, 16 * $zoom, 16 * $zoom)
        $g.DrawImage($panelBmp, ($pad * 2) + (16 * $zoom), $pad)
    } finally { $g.Dispose() }

    $out.Save($Preview, [System.Drawing.Imaging.ImageFormat]::Png)
    $out.Dispose(); $panelBmp.Dispose(); $iconBmp.Dispose()
    $created.Icon.Dispose()
    [void][ClaudeTray.Native]::DestroyIcon($created.Handle)

    "Preview saved to $Preview"
    exit 0
}

# ---------------------------------------------------------------------------
# Self-update
#
# OneDrive syncs a new tray.ps1 to every PC on its own; this makes the already
# running copy pick it up without anyone having to touch the machine.
# ---------------------------------------------------------------------------

$script:TrayPath = Join-Path $script:AppDir 'tray.ps1'

function Get-SourceStamp {
    $parts = @()
    $watched = @($script:TrayPath, $configPath,
                 (Join-Path $script:AppDir 'lib\i18n.ps1'),
                 (Join-Path $script:AppDir 'lib\plan.ps1'))
    foreach ($file in $watched) {
        try {
            if (Test-Path -LiteralPath $file) {
                $item = Get-Item -LiteralPath $file
                $parts += ('{0}:{1}:{2}' -f $item.Name, $item.LastWriteTimeUtc.Ticks, $item.Length)
            }
        } catch { }
    }
    return ($parts -join '|')
}

$script:SourceStamp  = Get-SourceStamp
$script:PendingStamp = $null

function Restart-Self {
    Write-Log 'new version on disk, restarting'
    $vbs = Join-Path $script:AppDir 'launch.vbs'
    try {
        if (Test-Path -LiteralPath $vbs) {
            Start-Process wscript.exe -ArgumentList "`"$vbs`""
        } else {
            Start-Process powershell.exe -ArgumentList `
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script:TrayPath`""
        }
    } catch {
        Write-Log "restart failed, staying on the old version: $($_.Exception.Message)" 'ERROR'
        return
    }
    [System.Windows.Forms.Application]::Exit()
}

# ---------------------------------------------------------------------------
# Single instance guard
# ---------------------------------------------------------------------------

$createdNew = $false
$script:Mutex = $null
# "Local\" scopes the mutex to this logon session: another user running their own
# copy is unaffected. The retry loop covers the hand-over during a self-restart,
# where the replacement starts before the outgoing process has finished exiting.
for ($attempt = 0; $attempt -lt 12; $attempt++) {
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeUsageTray', [ref]$createdNew)
    if ($createdNew) { break }
    $script:Mutex.Dispose()
    $script:Mutex = $null
    Start-Sleep -Milliseconds 500
}
if (-not $createdNew) {
    Write-Log 'another instance is already running, exiting' 'WARN'
    exit 0
}

# ---------------------------------------------------------------------------
# Timers and message loop
# ---------------------------------------------------------------------------

# Fires the periodic refresh.
$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = [int]$script:Config.pollSeconds * 1000
$script:PollTimer.Add_Tick({ Start-Fetch })

# Only runs while a fetch is in flight or the panel is open, so the process stays
# fully idle the rest of the time.
$script:TickTimer = New-Object System.Windows.Forms.Timer
$script:TickTimer.Interval = 1000
$script:TickTimer.Add_Tick({
    [void](Complete-Fetch)
    if ($script:Panel.Visible) {
        Update-Panel                      # keeps the reset countdown live
    } elseif (-not $script:FetchHandle) {
        $script:TickTimer.Enabled = $false
    }
})
$script:TickTimer.Enabled = $false

# Watches for a newer tray.ps1 arriving via OneDrive. A change has to be observed
# twice in a row before acting, so a half-synced file is never launched.
$script:UpdateTimer = New-Object System.Windows.Forms.Timer
$script:UpdateTimer.Interval = 20000
$script:UpdateTimer.Add_Tick({
    if (-not $script:Config.autoUpdate) { return }
    $current = Get-SourceStamp
    if ($current -eq $script:SourceStamp -or [string]::IsNullOrEmpty($current)) {
        $script:PendingStamp = $null
        return
    }
    if ($current -eq $script:PendingStamp) { Restart-Self } else { $script:PendingStamp = $current }
})

# After a resume the cached figures are usually stale; refresh instead of waiting
# out the rest of the poll interval.
$script:PowerHandler = [Microsoft.Win32.PowerModeChangedEventHandler] {
    param($sender, $e)
    if ($e.Mode -eq [Microsoft.Win32.PowerModes]::Resume) { Start-Fetch }
}
try { [Microsoft.Win32.SystemEvents]::add_PowerModeChanged($script:PowerHandler) } catch { }

try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Update-Ui
    $script:NotifyIcon.Visible = $true
    Start-Fetch
    $script:PollTimer.Start()
    $script:UpdateTimer.Start()
    Write-Log "started (poll every $($script:Config.pollSeconds)s)"
    [System.Windows.Forms.Application]::Run()
} finally {
    Write-Log 'shutting down'
    try { [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:PowerHandler) } catch { }
    try { $script:PollTimer.Dispose() } catch { }
    try { $script:TickTimer.Dispose() } catch { }
    try { $script:UpdateTimer.Dispose() } catch { }
    try { $script:NotifyIcon.Visible = $false } catch { }
    try { if ($script:NotifyIcon.Icon) { $script:NotifyIcon.Icon.Dispose() } } catch { }
    try { if ($script:IconHandle -ne [IntPtr]::Zero) { [void][ClaudeTray.Native]::DestroyIcon($script:IconHandle) } } catch { }
    try { $script:NotifyIcon.Dispose() } catch { }
    try { $script:Panel.Dispose() } catch { }
    try { if ($script:FetchPs) { $script:FetchPs.Dispose() } } catch { }
    try { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } catch { }
}
