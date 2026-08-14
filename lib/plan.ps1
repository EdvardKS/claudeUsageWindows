<#
.SYNOPSIS
    Works out which Claude plan this Windows account is signed in with.

.DESCRIPTION
    Reads only metadata from the credential file Claude Code writes. The access
    token is never read into a variable here, never returned, and never logged —
    this file deliberately touches nothing but subscriptionType, rateLimitTier and
    expiresAt.

    Note on ~\.claude.json: it looks like a richer source, but it cannot be parsed.
    It stores per-project keys that differ only by drive-letter case ("C:/..." and
    "c:/..."), which makes ConvertFrom-Json fail with DuplicateKeysInJsonString.
    Everything here comes from .credentials.json and the environment instead.

    Requires i18n.ps1 to have been dot-sourced first, for T.
#>

# rateLimitTier is the only field that separates Max 5x from Max 20x.
# Matched as a substring so a future "default_claude_max_20x_v2" still lands right.
$script:PlanTierMap = @(
    @{ Match = 'max_20x';    Key = 'plan.max20' }
    @{ Match = 'max_5x';     Key = 'plan.max5'  }
    @{ Match = 'enterprise'; Key = 'plan.enterprise' }
    @{ Match = 'team';       Key = 'plan.team'  }
    @{ Match = 'pro';        Key = 'plan.pro'   }
)

$script:ApiEnvVars = @(
    'ANTHROPIC_API_KEY'
    'ANTHROPIC_AUTH_TOKEN'
    'CLAUDE_CODE_USE_BEDROCK'
    'CLAUDE_CODE_USE_VERTEX'
)

function Get-ClaudePlan {
    <#
        Returns:
          Mode     'subscription' | 'api' | 'none' | 'unreadable'
          PlanName display name, already localised
          Tier     raw rateLimitTier, or '' when there is none
          Expired  [bool]
          Detail   localised paragraph explaining what this means
          Usable   [bool] — whether the usage endpoint can work at all
    #>
    param(
        [string]$CredPath = (Join-Path $env:USERPROFILE '.claude\.credentials.json')
    )

    $result = [pscustomobject]@{
        Mode     = 'none'
        PlanName = (T 'plan.none')
        Tier     = ''
        Expired  = $false
        Detail   = (T 'plan.detail.none')
        Usable   = $false
    }

    if (Test-Path -LiteralPath $CredPath) {
        $oauth = $null
        try {
            $oauth = (Get-Content -Raw -LiteralPath $CredPath | ConvertFrom-Json).claudeAiOauth
        } catch {
            $result.Mode     = 'unreadable'
            $result.PlanName = (T 'plan.unknown')
            $result.Detail   = (T 'plan.detail.unreadable')
            return $result
        }

        if ($oauth -and $oauth.accessToken) {
            $result.Mode   = 'subscription'
            $result.Usable = $true

            $tier = ''
            if ($oauth.PSObject.Properties.Name -contains 'rateLimitTier' -and $oauth.rateLimitTier) {
                $tier = [string]$oauth.rateLimitTier
            }
            $result.Tier = $tier

            $planKey = $null
            foreach ($entry in $script:PlanTierMap) {
                if ($tier -like ('*' + $entry.Match + '*')) { $planKey = $entry.Key; break }
            }
            if (-not $planKey) {
                # No tier, or one we have never seen: fall back to subscriptionType
                # rather than inventing a plan name.
                $subType = ''
                if ($oauth.PSObject.Properties.Name -contains 'subscriptionType' -and $oauth.subscriptionType) {
                    $subType = ([string]$oauth.subscriptionType).ToLowerInvariant()
                }
                $planKey = switch ($subType) {
                    'pro'        { 'plan.pro' }
                    'max'        { 'plan.unknown' }
                    'team'       { 'plan.team' }
                    'enterprise' { 'plan.enterprise' }
                    default      { 'plan.unknown' }
                }
            }
            $result.PlanName = (T $planKey)
            $result.Detail   = (T 'plan.detail.ok')

            # Same expiry rule the fetcher uses, so the wizard and the tray agree.
            if ($oauth.PSObject.Properties.Name -contains 'expiresAt' -and $oauth.expiresAt) {
                try {
                    $expires = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$oauth.expiresAt)
                    if ($expires -lt [DateTimeOffset]::UtcNow) {
                        $result.Expired = $true
                        $result.Detail  = (T 'plan.detail.expired')
                    }
                } catch { }
            }

            return $result
        }
    }

    # No usable OAuth credential. Direct API access is the common reason.
    foreach ($name in $script:ApiEnvVars) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) {
            $result.Mode     = 'api'
            $result.PlanName = (T 'plan.api')
            $result.Detail   = (T 'plan.detail.api')
            $result.Usable   = $false
            return $result
        }
    }

    return $result
}
