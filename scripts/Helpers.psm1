#Requires -Version 7.0
<#
    Shared helpers for New-Repo.ps1,
    which creates a new repo derived from the template repo it is run from.
    See scripts/README.md for the design.

    Keep this file identical at every layer: it is inherited by merge,
    so a per-layer edit conflicts on every future template change.
    Layer-specific behaviour goes in an additive Helpers-<NN>-<slug>.psm1.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference,
# so the calling script's 'Stop' does not reach these functions.
# Without this, a failing cmdlet would be reported as a success
# by the Write-Ok on the next line.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# Configuration
#───────────────────────────────────────────────────────────────────────────────

$script:RepoOwner = 'TaffarelJr'
$script:TemplateBranch = 'main'

function Get-RepoOwner {
    <#
    .SYNOPSIS
        Returns the GitHub account that owns every template layer,
        and everything derived from one.
    #>
    return $script:RepoOwner
}

function Get-TemplateBranch {
    <#
    .SYNOPSIS
        Returns the branch every template is tracked on. Always 'main'.
    #>
    return $script:TemplateBranch
}

#───────────────────────────────────────────────────────────────────────────────
# Per-layer customization
#───────────────────────────────────────────────────────────────────────────────

function Get-LayerModule {
    <#
    .SYNOPSIS
        Finds this chain's Helpers-<NN>-<slug>.psm1 layer modules, in load order.
    .DESCRIPTION
        <NN> is the layer tier, since alphabetical order does not match ancestry.
        The extension is checked explicitly
        because a Windows -Filter of '*.psm1' matches loosely.
    #>
    $files = Get-ChildItem -Path $PSScriptRoot `
        -Filter 'Helpers-*' `
        -File `
        -ErrorAction SilentlyContinue
    $files = $files | Where-Object { $_.Extension -eq '.psm1' }
    return @($files | Sort-Object Name)
}

function Import-LayerModule {
    <#
    .SYNOPSIS
        Loads every layer module and returns its module/entry-point pairs in order.
    .DESCRIPTION
        Imported -Global, so each layer's exported helpers are visible
        to the layers below it.
        The entry point is found from the module's own ExportedFunctions
        by the Invoke-*Scaffold pattern, so it is never coupled to the filename.
    #>
    $loaded = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-LayerModule) {
        $mod = Import-Module $file.FullName -Force -Global -PassThru
        $pattern = 'Invoke-*Scaffold'
        $exported = $mod.ExportedFunctions.Values
        $entry = @($exported | Where-Object { $_.Name -like $pattern })
        if ($entry.Count -ne 1) {
            $found = if ($entry) { ": $($entry.Name -join ', ')" }
            throw ("$($file.Name) must export exactly one " +
                "Invoke-*Scaffold entry point, " +
                "but exports $($entry.Count)$found.")
        }
        $loaded.Add([pscustomobject]@{
                Name   = $file.Name
                Module = $mod
                Entry  = $entry[0]
            })
    }
    return $loaded.ToArray()
}

function Remove-LayerModule {
    <#
    .SYNOPSIS
        Unloads the layer modules so an interactive session isn't left holding them.
    #>
    foreach ($file in Get-LayerModule) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        Remove-Module $name -Force -ErrorAction SilentlyContinue
    }
}

# Files that exist ONLY in the base .github repo.
# Single source of truth: the same table drives both the deletion
# and the README de-linking, so the two can't drift apart.
# 'Label' is the markdown link-reference label the README uses for that file.
$script:TemplateOnlyFiles = @(
    @{ Path = '.github/FUNDING.yml'; Label = 'fundingFile' }
    @{ Path = '.github/ISSUE_TEMPLATE/config.yml'; Label = 'issueChooserFile' }
)

#───────────────────────────────────────────────────────────────────────────────
# Internal state & logging
#───────────────────────────────────────────────────────────────────────────────

$script:SkipManualPrompts = $false
$script:CurrentStep = ''
$script:CurrentStepTitle = ''

# Pushed by Use-GhAccount, popped by Reset-GhAccount.
$script:GhStatePushed = $false
$script:PriorGhToken = $null
$script:PriorGhAccount = $null
$script:ManualItems = [System.Collections.Generic.List[object]]::new()

# Display tallies for the end-of-run summary.
$script:OkCount = 0
$script:SkipCount = 0
$script:WarnCount = 0

# Not a tally: did this run change anything?
# Gates the Template Sync dispatch and the "already fully scaffolded" message,
# so a successful no-op must not count.
$script:ChangeCount = 0

$script:Rule = '─' * 72

# One marker per outcome, so the log reads consistently:
#   ✅ succeeded   ⏭️ already done   ⚠️ warning   ❌ failed   ℹ️ neutral note
function Write-Ok {
    param([string]$Msg)
    $script:OkCount++
    Write-Host "  ✅ $Msg" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Msg)
    $script:SkipCount++
    Write-Host "  ⏭️  $Msg" -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Msg)
    $script:WarnCount++
    Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Msg)
    Write-Host "  ❌ $Msg" -ForegroundColor Red
}

function Write-Info {
    param([string]$Msg)
    Write-Host "  ℹ️  $Msg" -ForegroundColor Gray
}

# Indented continuation line, for detail belonging to the marker above it.
function Write-Detail {
    param([string]$Msg)
    Write-Host "       $Msg" -ForegroundColor DarkGray
}

# Flags that this run changed real state; see $script:ChangeCount.
function Add-Change { $script:ChangeCount++ }

# Aligned label/value pair, for the run header in step 0.
function Write-Field {
    # An empty -Label is allowed:
    # it renders a continuation line under the field above.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [string]$Value
    )
    Write-Host ("  ·  {0,-18}{1}" -f $Label, $Value) -ForegroundColor Gray
}

function Assert-LastExit {
    <#
    .SYNOPSIS
        Throws if the last native command exited non-zero.
    #>
    param([Parameter(Mandatory)][string]$What)
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

function Format-Slug {
    <#
    .SYNOPSIS
        Normalises and validates a repo-name slug:
        one regex and one error wording for the whole chain.
    #>
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )
    $slug = $Value.Trim().ToLowerInvariant()
    if ($slug -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
        throw "$Label must be kebab-case (letters/digits/hyphens): '$slug'"
    }
    return $slug
}

function Confirm-Proceed {
    <#
    .SYNOPSIS
        Returns $true when the run should continue - the final go/no-go gate.
    .DESCRIPTION
        Honours the module's own skip-prompts state,
        rather than a second copy of the switch in each script,
        and reports an abort through Write-Warn,
        so it looks like every other warning.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    if ($script:SkipManualPrompts) { return $true }
    if ((Read-Host "  Type 'yes' to create/verify $OwnerRepo") -eq 'yes') {
        return $true
    }
    Write-Warn 'Aborted by user.'
    return $false
}

function Write-Step {
    <#
    .SYNOPSIS
        Starts a step, recording it so a failure banner can name what went wrong.
    #>
    param(
        [Parameter(Mandatory)][string]$Number,
        [Parameter(Mandatory)][string]$Title
    )
    $script:CurrentStep = $Number
    $script:CurrentStepTitle = $Title
    $head = "═══ STEP $Number · $Title "
    Write-Host ""
    $pad = '═' * [Math]::Max(0, 72 - $head.Length)
    Write-Host ($head + $pad) -ForegroundColor Cyan
}

# Reports whether this run changed anything; see Add-Change.
function Get-ChangeCount { return $script:ChangeCount }

function Show-Summary {
    <#
    .SYNOPSIS
        Prints a one-line tally, so the end of a run reads at a glance.
    #>
    Write-Host ""
    $tally = '  {0} ok · {1} already done · {2} warning(s)'
    $counts = $script:OkCount, $script:SkipCount, $script:WarnCount
    Write-Host ($tally -f $counts) -ForegroundColor Gray
}

function Show-Failure {
    <#
    .SYNOPSIS
        Renders a terminating error as a readable banner,
        instead of a raw PowerShell dump.
    .DESCRIPTION
        Reports which step failed, the message, the offending line,
        and the script stack trace.
        Scaffolding is resumable, so it also says what to do next.
    #>
    param([Parameter(Mandatory)]$ErrorRecord)
    Write-Host ""
    Write-Host $script:Rule -ForegroundColor Red
    $where = if ($script:CurrentStep -ne '') {
        " — STEP $($script:CurrentStep) · $($script:CurrentStepTitle)"
    }
    else { '' }
    Write-Host " ❌ SCAFFOLDING FAILED$where" -ForegroundColor Red
    Write-Host $script:Rule -ForegroundColor Red
    Write-Host ""
    Write-Host "  $($ErrorRecord.Exception.Message)" -ForegroundColor Red

    $inv = $ErrorRecord.InvocationInfo
    if ($inv -and $inv.ScriptName) {
        Write-Host ""
        $at = "$(Split-Path -Leaf $inv.ScriptName):$($inv.ScriptLineNumber)"
        Write-Host "  at $at" -ForegroundColor DarkGray
        if ($inv.Line) { Write-Detail $inv.Line.Trim() }
    }
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Host ""
        Write-Host "  Stack trace:" -ForegroundColor DarkGray
        foreach ($line in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
            if ($line.Trim()) { Write-Detail $line.Trim() }
        }
    }
    Show-Summary
    Write-Host ""
    Write-Host '  Nothing rolled back. Re-run to resume where it left off.' `
        -ForegroundColor Yellow
    Write-Host ""
}

function Invoke-Git {
    <#
    .SYNOPSIS
        Runs git with its chatter captured rather than dumped to the console.
    .DESCRIPTION
        Turns a non-zero exit into a clean error,
        with git's own output included as detail.

        Only for calls where failure is genuinely an error.
        Calls that USE the exit code as a boolean stay raw -
        show-ref --quiet, diff --cached --quiet, rev-parse --verify.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    # -Arguments must be an explicit array: loose tokens like '-C' bind as
    # PowerShell parameters instead of git arguments, without any error.
    $argv = if ($RepoPath) {
        @('-C', $RepoPath) + $Arguments
    }
    else { $Arguments }
    $out = & git @argv 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($out | Out-String).Trim()
        throw ("$What failed: git $($argv -join ' ') (exit $LASTEXITCODE)" +
            $(if ($detail) { "`n$detail" } else { '' }))
    }
    return $out
}

function Invoke-Gh {
    <#
    .SYNOPSIS
        Runs gh exactly as Invoke-Git runs git.
        -Arguments must be an explicit array.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $out = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($out | Out-String).Trim()
        throw ("$What failed: gh $($Arguments -join ' ') (exit $LASTEXITCODE)" +
            $(if ($detail) { "`n$detail" } else { '' }))
    }
    return $out
}

function Set-SkipPrompts {
    <#
    .SYNOPSIS
        Suppresses every prompt, for an unattended run.
    #>
    param([Parameter(Mandatory)][bool]$Skip)
    $script:SkipManualPrompts = $Skip
}

#───────────────────────────────────────────────────────────────────────────────
# Input resolution (command line OR prompt)
#───────────────────────────────────────────────────────────────────────────────

function Resolve-Input {
    <#
    .SYNOPSIS
        Returns a value that may come from the command line or a prompt.
    .DESCRIPTION
        - If the caller passed the parameter
          (tracked in $Bound = $PSBoundParameters),
          uses $Value as-is and does NOT prompt,
          even if it is an empty string.
        - Otherwise, if prompts are suppressed (Set-SkipPrompts $true),
          returns $Default without prompting, so unattended runs never block.
        - Otherwise prompts. A non-empty -Default is shown as [default],
          and ENTER accepts it. -Secret prompts without echo, for tokens.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Bound,
        $Value,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [switch]$Secret
    )
    if ($Bound.ContainsKey($Name)) { return [string]$Value }
    if ($script:SkipManualPrompts) { return $Default }

    if ($Secret) {
        $sec = Read-Host -AsSecureString $Prompt
        return [System.Net.NetworkCredential]::new('', $sec).Password
    }
    $label = if ($Default -ne '') { "$Prompt [$Default]" } else { $Prompt }
    $entered = Read-Host $label
    if ([string]::IsNullOrEmpty($entered)) { return $Default }
    return $entered
}

#───────────────────────────────────────────────────────────────────────────────
# Manual follow-up checklist (things with no API)
#───────────────────────────────────────────────────────────────────────────────

function Add-ManualItem {
    <#
    .SYNOPSIS
        Adds one entry to the end-of-run manual checklist.
    #>
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Steps = @()
    )
    $script:ManualItems.Add([pscustomobject]@{
            Category = $Category
            Title    = $Title
            Steps    = $Steps
        })
}

function Register-ManualSettings {
    <#
    .SYNOPSIS
        Queues the repo settings GitHub only exposes in the web UI (no REST API).
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    # NB: release immutability is NOT listed here - it has a real API now,
    # handled by Enable-ImmutableReleases, which re-adds it to this
    # list only if the call fails.
    $cat = 'GitHub settings — web UI only (no API)'
    $url = "https://github.com/$OwnerRepo/settings"

    $steps = @(
        "$url  →  General"
        "check 'Limit how many branches and tags can be updated"
        "in a single push'  →  set 2"
    )
    Add-ManualItem -Category $cat `
        -Title 'Limit branches/tags updated per push to 2' `
        -Steps $steps

    $steps = @(
        "$url  →  Moderation options  →  Code review limits"
        "check 'Limit to users explicitly granted read or higher access'"
    )
    Add-ManualItem -Category $cat `
        -Title 'Restrict code review to users with read+ access' `
        -Steps $steps

    $steps = @(
        "$url/security_analysis  →  enable 'Grouped security updates'"
    )
    Add-ManualItem -Category $cat `
        -Title 'Enable grouped security updates' `
        -Steps $steps

    $steps = @(
        "$url/security_analysis  →  enable 'Dependency graph'"
        'Public repos always have it on; the toggle is not offered.'
    )
    Add-ManualItem -Category $cat `
        -Title 'Enable the Dependency graph — only if this repo is PRIVATE' `
        -Steps $steps

    $steps = @(
        "https://github.com/$OwnerRepo"
        'the Settings app applies settings.yml within a few minutes'
    )
    Add-ManualItem -Category $cat `
        -Title 'Verify the description and topics appear on the home page' `
        -Steps $steps
}

function Show-ManualChecklist {
    <#
    .SYNOPSIS
        Prints everything Add-ManualItem queued, grouped by category.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    if ($script:ManualItems.Count -eq 0) {
        Write-Host "`n✅ No manual follow-up needed." -ForegroundColor Green
        return
    }
    $rule = '─' * 72
    Write-Host ""
    Write-Host $rule -ForegroundColor Yellow
    Write-Host " 📋 MANUAL FOLLOW-UP — $OwnerRepo" -ForegroundColor Yellow
    Write-Host "    Not automatable; do them in the web UI when convenient." `
        -ForegroundColor Yellow
    Write-Host $rule -ForegroundColor Yellow
    foreach ($group in ($script:ManualItems | Group-Object Category)) {
        Write-Host ""
        Write-Host "  ▸ $($group.Name)" -ForegroundColor Cyan
        $n = 1
        foreach ($item in $group.Group) {
            Write-Host ("    {0}. [ ] {1}" -f $n, $item.Title) `
                -ForegroundColor White
            foreach ($s in $item.Steps) {
                Write-Host "           $s" -ForegroundColor DarkGray
            }
            $n++
        }
    }
    Write-Host ""
}

#───────────────────────────────────────────────────────────────────────────────
# Context & prerequisites
#───────────────────────────────────────────────────────────────────────────────

function Get-TemplateContext {
    <#
    .SYNOPSIS
        Discovers the SOURCE template repo from the calling script's location.
    .DESCRIPTION
        The scripts live in <templateRepo>/scripts,
        so the repo root is the parent of $ScriptRoot,
        and new repos are cloned next to it (ParentDir).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptRoot)

    $sourceRoot = Split-Path -Parent $ScriptRoot
    if (-not (Test-Path (Join-Path $sourceRoot '.git'))) {
        throw ("No git repo at '$sourceRoot'. " +
            "Run this from a template repo's scripts/ folder.")
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git not found on PATH."
    }
    if (-not (Get-Command gh  -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found on PATH."
    }

    $originUrl = (git -C $sourceRoot remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $originUrl) {
        throw "Could not read 'origin' remote from '$sourceRoot'."
    }
    $originUrl = $originUrl.Trim()

    if ($originUrl -notmatch '[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$') {
        throw "Could not parse owner/repo from origin URL '$originUrl'."
    }
    if ($Matches['owner'] -ne $script:RepoOwner) {
        Write-Warn ("This repo's origin owner is '$($Matches['owner'])' " +
            "but the configured owner is '$($script:RepoOwner)'. " +
            "Update `$script:RepoOwner in Helpers.psm1 if that's wrong.")
    }
    [pscustomobject]@{
        SourceOwner     = $Matches['owner']
        SourceRepo      = $Matches['repo']
        SourceOwnerRepo = "$($Matches['owner'])/$($Matches['repo'])"
        SourceRoot      = $sourceRoot
        # SourceUrl is reused verbatim as the new repo's 'template' remote.
        SourceUrl       = $originUrl
        ParentDir       = Split-Path -Parent $sourceRoot
    }
}

function Get-ActiveGhAccount {
    <#
    .SYNOPSIS
        Returns the login gh is authenticating as, or $null if the call failed.
    .DESCRIPTION
        gh writes error bodies to STDOUT,
        so a failed call returns JSON rather than nothing -
        which would otherwise be captured and later fed to
        `gh auth switch --user`.
        Guard on the exit code, then reject anything with JSON punctuation.
        Deny-listing rather than allow-listing,
        because logins legitimately contain characters like the underscore
        in enterprise-managed accounts.
    #>
    $login = gh api user --jq .login 2>$null
    $ok = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0
    if (-not $ok -or -not $login) { return $null }
    $login = ($login | Out-String).Trim()
    if (-not $login -or $login -match '[\s{}\[\]":,]') { return $null }
    return $login
}

function Use-GhAccount {
    <#
    .SYNOPSIS
        Points this process's gh calls at the repo owner,
        then verifies it has admin access.
    .DESCRIPTION
        Borrows the owner's token into $env:GH_TOKEN,
        rather than running `gh auth switch`,
        which would repoint every other shell on the machine.
        Records any prior GH_TOKEN and active account first,
        so Reset-GhAccount can put both back exactly as they were.
    #>
    param([Parameter(Mandatory)][string]$ProbeOwnerRepo)

    $account = $script:RepoOwner

    # Push the state we are about to change,
    # so the pop can be exact rather than approximate.
    $script:PriorGhToken = $env:GH_TOKEN
    $script:PriorGhAccount = Get-ActiveGhAccount
    $script:GhStatePushed = $true

    $token = gh auth token --user $account 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        $global:LASTEXITCODE = 0
        if ($script:SkipManualPrompts) {
            throw ("No stored credentials for gh account '$account', " +
                'and prompts are suppressed. ' +
                'Run: gh auth login   (then re-run unattended.)')
        }
        Write-Warn ("No stored credentials for gh account '$account' - " +
            "starting 'gh auth login'")
        Write-Detail "sign in as '$account'; your other accounts stay logged in"
        gh auth login --hostname github.com
        if ($LASTEXITCODE -ne 0) {
            $global:LASTEXITCODE = 0
            throw "'gh auth login' did not complete."
        }
        $global:LASTEXITCODE = 0

        $token = gh auth token --user $account 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $token) {
            $global:LASTEXITCODE = 0
            throw ("Still no credentials for '$account' - " +
                'did you sign in as a different account?')
        }
        $global:LASTEXITCODE = 0
    }
    $env:GH_TOKEN = $token.Trim()
    Write-Ok "Using gh account '$account' for this run only"

    $active = Get-ActiveGhAccount
    if (-not $active) {
        throw "Not authenticated with gh. Run 'gh auth login' first."
    }

    # Admin probe:
    # being logged in is not the same as having the scopes we need.
    $probe = "repos/$ProbeOwnerRepo/actions/permissions/workflow"
    gh api $probe --silent 2>$null | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0
    if (-not $ok) {
        throw ("Account '$active' lacks admin access to " +
            "'$ProbeOwnerRepo'. If it is a scope issue, run: gh auth refresh " +
            '-h github.com -s admin:repo_hook,workflow,security_events')
    }
    Write-Ok "Admin access confirmed (gh account: $active)"
}

function Reset-GhAccount {
    <#
    .SYNOPSIS
        Restores the gh token and active account recorded by Use-GhAccount.
    .DESCRIPTION
        Puts back a GH_TOKEN that was already set,
        rather than just clearing ours,
        and switches the active account back if `gh auth login` changed it.
        Safe to call more than once,
        and a no-op if nothing was ever pushed,
        so it can run on both the success and failure paths.
    #>
    if (-not $script:GhStatePushed) { return }

    if ($script:PriorGhToken) { $env:GH_TOKEN = $script:PriorGhToken }
    elseif ($env:GH_TOKEN) {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    }

    # `gh auth login` makes the account it signed in as active;
    # put the previous one back.
    if ($script:PriorGhAccount) {
        $active = Get-ActiveGhAccount
        if ($active -and $active -ne $script:PriorGhAccount) {
            gh auth switch --user $script:PriorGhAccount 2>$null | Out-Null
            $global:LASTEXITCODE = 0
            Write-Info ("Restored '$($script:PriorGhAccount)' " +
                'as the active gh account')
        }
    }

    $script:GhStatePushed = $false
    Write-Info 'Released the borrowed gh token'
}

#───────────────────────────────────────────────────────────────────────────────
# Step: create the repo (idempotent)
#───────────────────────────────────────────────────────────────────────────────

function New-GitHubRepo {
    <#
    .SYNOPSIS
        Creates an empty public repo. No-op if it already exists.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    gh repo view $OwnerRepo --json name 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Skip "Repo $OwnerRepo already exists"
        return
    }
    Invoke-Gh -What "Creating $OwnerRepo" `
        -Arguments @('repo', 'create', $OwnerRepo, '--public') | Out-Null
    Add-Change
    Write-Ok "Created empty public repo $OwnerRepo"
}

#───────────────────────────────────────────────────────────────────────────────
# Step: repo settings (API-settable, all idempotent)
#───────────────────────────────────────────────────────────────────────────────

function Set-ActionsPermissions {
    <#
    .SYNOPSIS
        Allows GitHub Actions to create and approve PRs,
        preserving the default permissions.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    # gh writes its error body to STDOUT,
    # so a failed GET still parses - into an object with message/status.
    # Under StrictMode, reading a missing property throws, so test first.
    $endpoint = "repos/$OwnerRepo/actions/permissions/workflow"
    $json = gh api $endpoint 2>$null
    $cur = $json | ConvertFrom-Json
    $global:LASTEXITCODE = 0
    $props = if ($cur) { @($cur.PSObject.Properties.Name) } else { @() }

    if ($props -contains 'can_approve_pull_request_reviews' -and
        $cur.can_approve_pull_request_reviews) {
        Write-Skip 'Actions create/approve PRs already enabled'; return
    }
    $perm = if ($props -contains 'default_workflow_permissions') {
        $cur.default_workflow_permissions
    }
    else { 'read' }
    $ghArgs = @(
        'api', '--method', 'PUT', $endpoint
        '-f', "default_workflow_permissions=$perm"
        '-F', 'can_approve_pull_request_reviews=true'
    )
    Invoke-Gh -What 'Allowing Actions to create and approve PRs' `
        -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Ok "Actions: allowed to create and approve pull requests"
}

function Enable-PrivateVulnReporting {
    <#
    .SYNOPSIS
        Enables private vulnerability reporting. No-op if already on.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    $endpoint = "repos/$OwnerRepo/private-vulnerability-reporting"
    $enabled = gh api $endpoint --jq '.enabled' 2>$null
    if ($LASTEXITCODE -eq 0 -and $enabled -eq 'true') {
        Write-Skip 'Private vulnerability reporting already enabled'
        return
    }
    $ghArgs = @('api', '--method', 'PUT', $endpoint, '--silent')
    Invoke-Gh -What 'Enabling private vulnerability reporting' `
        -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Ok "Enabled private vulnerability reporting"
}

function Set-CodecovSecret {
    <#
    .SYNOPSIS
        Adds the CODECOV_TOKEN repo secret.
        No-op if it already exists; it never overwrites.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo, [string]$Token)
    $secrets = gh secret list --repo $OwnerRepo 2>$null
    # Listing may legitimately fail; don't leak that to a later Assert-LastExit.
    $global:LASTEXITCODE = 0
    $exists = @($secrets) -match '^CODECOV_TOKEN\b'
    if ($exists) {
        Write-Skip "CODECOV_TOKEN already set (change it with 'gh secret set')"
        return
    }
    if (-not $Token) {
        Write-Warn 'CODECOV_TOKEN not provided - add it with gh secret set'
        return
    }
    $ghArgs = @(
        'secret', 'set', 'CODECOV_TOKEN'
        '--repo', $OwnerRepo
        '--body', $Token
    )
    Invoke-Gh -What 'Setting the CODECOV_TOKEN secret' `
        -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Ok "Added repo secret CODECOV_TOKEN"
}

function Initialize-Topics {
    <#
    .SYNOPSIS
        Seeds one throwaway topic, so settings.yml can manage topics after that.
    .DESCRIPTION
        The Settings app's topics call does not land on a repo
        that has never had a topic.
        The real list stays in settings.yml,
        which overwrites this seed on the next sync.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)

    $current = gh api "repos/$OwnerRepo/topics" --jq '.names | length' 2>$null
    $global:LASTEXITCODE = 0
    if ($current -and [int]$current -gt 0) {
        Write-Skip "Topics already seeded ($current) - settings.yml owns them"
        return
    }

    $ghArgs = @(
        'api', '--method', 'PUT', "repos/$OwnerRepo/topics"
        '-f', 'names[]=github'
    )
    Invoke-Gh -What 'Seeding a placeholder topic' `
        -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Ok "Seeded topic 'github'"
    Write-Detail 'settings.yml replaces this on the next sync'
}

function Enable-ImmutableReleases {
    <#
    .SYNOPSIS
        Enables immutable releases, locking assets and tags once published.
    .DESCRIPTION
        Uses the dedicated /immutable-releases endpoints;
        the repo PATCH endpoint has no field for it.
        Still in preview, so a failure falls back to the manual checklist.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)

    # GET returns 204 when enabled and 404 when not,
    # so the exit code is the answer.
    $endpoint = "repos/$OwnerRepo/immutable-releases"
    gh api $endpoint --silent 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $global:LASTEXITCODE = 0
        Write-Skip 'Immutable releases already enabled'
        return
    }
    $global:LASTEXITCODE = 0

    gh api --method PUT $endpoint --silent 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $global:LASTEXITCODE = 0
        Add-Change
        Write-Ok 'Enabled immutable releases'
        return
    }
    $global:LASTEXITCODE = 0
    Write-Warn ("Couldn't enable immutable releases via the API " +
        '(still in preview) - added to the checklist')
    $steps = @(
        "https://github.com/$OwnerRepo/settings  →  General"
        "check 'Enable release immutability'"
    )
    Add-ManualItem -Category 'GitHub settings — web UI only (no API)' `
        -Title 'Enable release immutability' `
        -Steps $steps
}

# CodeQL languages this run should analyse. Layers add to it;
# Enable-Codeql applies the union at the end. Seeded with 'actions'
# because every repo here carries workflows, AND the inherited "Status checks
# must pass" ruleset requires the `Analyze (actions)` check - dropping it would
# leave that check permanently pending and block every PR.
$script:CodeqlLanguages = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('actions'), [System.StringComparer]::OrdinalIgnoreCase)

# The complete set GitHub accepts for code scanning default setup.
$script:CodeqlValidLanguages = @(
    'actions'                 # GitHub Actions workflows
    'c-cpp'                   # C and C++
    'csharp'                  # C#
    'go'                      # Go
    'java-kotlin'             # Java and Kotlin
    'javascript-typescript'   # JavaScript and TypeScript
    'python'                  # Python
    'ruby'                    # Ruby
    'swift'                   # Swift
)

function Add-CodeqlLanguage {
    <#
    .SYNOPSIS
        Registers CodeQL languages for this layer, adding to the inherited list.
    .PARAMETER Language
        One or more of: actions, c-cpp, csharp, go, java-kotlin,
        javascript-typescript, python, ruby, swift.
        Anything else throws.
    #>
    param([Parameter(Mandatory)][string[]]$Language)
    foreach ($lang in $Language) {
        $l = $lang.Trim()
        if ($l -notin $script:CodeqlValidLanguages) {
            throw ("'$l' is not a CodeQL language. Valid values: " +
                ($script:CodeqlValidLanguages -join ', '))
        }
        if ($script:CodeqlLanguages.Add($l)) {
            Write-Detail "CodeQL will analyse '$l'"
        }
    }
}

function Get-CodeqlLanguage {
    <#
    .SYNOPSIS
        Returns the languages registered so far, for inspection or testing.
    #>
    return @($script:CodeqlLanguages | Sort-Object)
}

function Enable-Codeql {
    <#
    .SYNOPSIS
        Enables CodeQL default setup for every language the chain registered.
    .DESCRIPTION
        Languages come from Add-CodeqlLanguage.
        Call this AFTER the first push - the repo needs content.

        Unlike the other settings helpers,
        this does NOT simply skip when already configured:
        a layer may have added a language since,
        so it extends the existing list instead.
        What is already configured is always kept,
        so a language enabled by hand is never removed.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)

    $endpoint = "repos/$OwnerRepo/code-scanning/default-setup"
    $existing = @(gh api $endpoint --jq '.languages[]?' 2>$null)
    $state = gh api $endpoint --jq '.state' 2>$null
    $global:LASTEXITCODE = 0

    $wanted = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$existing, [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($l in $script:CodeqlLanguages) { [void]$wanted.Add($l) }
    $langs = @($wanted | Sort-Object)

    $added = @($langs | Where-Object { $_ -notin $existing })
    if ($state -eq 'configured' -and -not $added) {
        Write-Skip "CodeQL already analysing: $($langs -join ', ')"
        return
    }

    # PATCH, not PUT: GitHub does not route PUT here and answers with a bare,
    # generic 404.
    $ghArgs = @('api', '--method', 'PATCH', $endpoint,
        '-f', 'state=configured')
    foreach ($l in $langs) { $ghArgs += @('-f', "languages[]=$l") }
    & gh @ghArgs --silent 2>$null | Out-Null
    $enabled = ($LASTEXITCODE -eq 0)
    # This failure is tolerated; don't leak it to a later Assert-LastExit.
    $global:LASTEXITCODE = 0

    if (-not $enabled) {
        # GitHub 422s on a language the repo does not contain -
        # expected for a template that declares csharp before it has any C#.
        # Fall back to whatever is actually there.
        $retry = @(
            'api', '--method', 'PATCH', $endpoint
            '-f', 'state=configured'
        )
        & gh @retry --silent 2>$null | Out-Null
        $enabled = ($LASTEXITCODE -eq 0)
        $global:LASTEXITCODE = 0
        if ($enabled) {
            $now = @(gh api $endpoint --jq '.languages[]?' 2>$null)
            $global:LASTEXITCODE = 0
            $missing = @($langs | Where-Object { $_ -notin $now })
            $nowList = ($now | Sort-Object) -join ', '
            $fresh = @($now | Where-Object { $_ -notin $existing })
            $changed = $fresh -or -not $existing
            if ($changed) {
                Add-Change
                Write-Ok "CodeQL default setup enabled: $nowList"
            }
            else {
                # Nothing moved, so report a skip -
                # this keeps the change count at zero
                # for an already-scaffolded repo.
                Write-Skip "CodeQL already analysing: $nowList"
            }
            if ($missing) {
                Write-Detail ('not in the repo yet, so not enabled: ' +
                    ($missing -join ', '))
                Write-Detail 're-run once that code exists to add them'
            }
            return
        }
    }

    if ($enabled) {
        Add-Change
        Write-Ok "CodeQL default setup enabled: $($langs -join ', ')"
    }
    else {
        # Code scanning may be unavailable on the repo entirely.
        # Hand it to the checklist rather than failing;
        # a later re-run will pick it up.
        Write-Warn ('CodeQL default setup not enabled automatically - ' +
            'added to the checklist')
        $steps = @(
            "https://github.com/$OwnerRepo/settings/security_analysis"
            'Code scanning  →  Default  →  Enable'
            'Or just re-run this script once the repo is a few minutes old.'
        )
        Add-ManualItem -Category 'GitHub settings — web UI only (no API)' `
            -Title 'Set up CodeQL default analysis' `
            -Steps $steps
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Step: clone & wire up remotes (resume-safe)
#───────────────────────────────────────────────────────────────────────────────

function Get-NewRepoUrl {
    <#
    .SYNOPSIS
        Builds the git URL for a sibling repo,
        by swapping the owner/repo path in the source URL.
    .DESCRIPTION
        Preserves the host and protocol,
        including a custom SSH alias like git@github.com-personal:...,
        so the new repo's origin uses the same credentials.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$RepoName
    )
    $old = "$($Context.SourceOwner)/$($Context.SourceRepo)"
    $new = "$($Context.SourceOwner)/$RepoName"
    $url = $Context.SourceUrl -replace [regex]::Escape($old), $new
    if ($url -eq $Context.SourceUrl) {
        throw "Could not derive sibling URL from '$($Context.SourceUrl)'."
    }
    return $url
}

function Get-TemplateChain {
    <#
    .SYNOPSIS
        Walks the inheritance chain upward from $StartRepoPath,
        following each repo's 'template' remote.
    .DESCRIPTION
        Returns the LOCAL paths of every layer, nearest first:
            [ .template-nuget, .template-dotnet, .github ]

        Each ancestor is located by repo name,
        as a sibling folder in $ParentDir.
        Walking stops when a repo has no 'template' remote (the base),
        or when the next ancestor isn't cloned locally.
        Cycles and runaway depth are guarded.
    #>
    param(
        [Parameter(Mandatory)][string]$StartRepoPath,
        [Parameter(Mandatory)][string]$ParentDir,
        [int]$MaxDepth = 10
    )
    $chain = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()

    $cur = (Resolve-Path $StartRepoPath).Path
    [void]$seen.Add($cur.ToLowerInvariant())
    $chain.Add($cur)

    for ($i = 0; $i -lt $MaxDepth; $i++) {
        $url = git -C $cur remote get-url template 2>$null
        # A missing 'template' remote means the base layer was reached.
        if ($LASTEXITCODE -ne 0 -or -not $url) { break }
        if ($url.Trim() -notmatch '[:/][^/]+/([^/]+?)(\.git)?$') { break }
        $ancestorPath = Join-Path $ParentDir $Matches[1]
        if (-not (Test-Path (Join-Path $ancestorPath '.git'))) {
            Write-Info ("Ancestor '$($Matches[1])' isn't cloned locally - " +
                'ending chain walk')
            break
        }
        $resolved = (Resolve-Path $ancestorPath).Path
        if (-not $seen.Add($resolved.ToLowerInvariant())) { break }    # cycle
        $chain.Add($resolved)
        $cur = $resolved
    }
    # Reaching the base layer means the last `git remote get-url template`
    # failed by design. Clear the leaked exit code so a later Assert-LastExit
    # doesn't see a phantom failure.
    $global:LASTEXITCODE = 0
    return $chain.ToArray()
}

function Set-RemotesAndConfig {
    <#
    .SYNOPSIS
        Ensures the 'template' remote, the push default, the commit template,
        and that 'main' exists and is checked out.
    .DESCRIPTION
        Idempotent. Creates main from the template branch
        ONLY if it doesn't already exist,
        so resuming never resets existing history.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$TemplateUrl
    )
    git -C $RepoPath config remote.pushdefault origin | Out-Null
    $remotes = git -C $RepoPath remote 2>$null
    if ($remotes -notcontains 'template') {
        Invoke-Git -What "Adding the 'template' remote" `
            -RepoPath $RepoPath `
            -Arguments @('remote', 'add', 'template', $TemplateUrl) | Out-Null
    }
    else {
        git -C $RepoPath remote set-url template $TemplateUrl | Out-Null
    }
    Invoke-Git -What 'Fetching the template remote' `
        -RepoPath $RepoPath -Arguments @('fetch', 'template') | Out-Null
    git -C $RepoPath config commit.template .gitmessage | Out-Null

    git -C $RepoPath show-ref --verify --quiet refs/heads/main
    if ($LASTEXITCODE -ne 0) {
        $templateRef = "template/$($script:TemplateBranch)"
        Invoke-Git -What "Creating main from $templateRef" `
            -RepoPath $RepoPath `
            -Arguments @('checkout', '-B', 'main', $templateRef) | Out-Null
    }
    else {
        $branch = git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null
        if ($branch -ne 'main') {
            Invoke-Git -What 'Switching to main' -RepoPath $RepoPath `
                -Arguments @('checkout', 'main') | Out-Null
        }
    }
}

function Initialize-Clone {
    <#
    .SYNOPSIS
        Clones the new repo next to the template,
        or reuses an existing local clone.
    #>
    param(
        [Parameter(Mandatory)][string]$OriginUrl,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$TemplateUrl
    )
    if (Test-Path $TargetPath) {
        if (-not (Test-Path (Join-Path $TargetPath '.git'))) {
            throw ("Path exists but is not a git repo: $TargetPath " +
                '(remove it and retry).')
        }
        Write-Skip "Local clone already present - reusing without reset"
    }
    else {
        # git clone (not `gh repo clone`) keeps the URL's host alias/creds.
        Invoke-Git -What "Cloning $OriginUrl" `
            -Arguments @('clone', $OriginUrl, $TargetPath) | Out-Null
        Add-Change
        Write-Ok "Cloned $OriginUrl"
        Write-Detail "-> $TargetPath"
    }
    Set-RemotesAndConfig -RepoPath $TargetPath -TemplateUrl $TemplateUrl
    Write-Ok "'template' remote -> $TemplateUrl; on branch main"
}

function Test-CommitExists {
    <#
    .SYNOPSIS
        Returns true if THIS repo already made a commit with this exact subject.
    .DESCRIPTION
        Scoped to template/<branch>..HEAD.
        Searching all history would match the same commits
        inherited from an already-scaffolded parent,
        and skip customizing the new repo entirely.
        Returns false when the template ref is missing,
        so the step re-runs harmlessly.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message
    )
    $ref = "template/$($script:TemplateBranch)"
    git -C $RepoPath rev-parse --verify --quiet $ref | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0   # no template ref yet
        return $false
    }

    # Exact subject match, so one group's message can't satisfy another's
    # gate by prefix.
    # A reverted step still reads as done,
    # since the original subject remains in the range.
    $subjects = git -C $RepoPath log --format='%s' "$ref..HEAD" 2>$null
    return [bool](@($subjects) -ceq $Message)
}

#───────────────────────────────────────────────────────────────────────────────
# Step: customize files (each edit is idempotent on its own)
#───────────────────────────────────────────────────────────────────────────────

function Remove-TemplateOnlyFiles {
    <#
    .SYNOPSIS
        Deletes the files listed in $TemplateOnlyFiles,
        which live ONLY in the base .github repo.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $gone = 0
    foreach ($entry in $script:TemplateOnlyFiles) {
        $f = Join-Path $RepoPath $entry.Path
        if (Test-Path $f) {
            Remove-Item $f
            Write-Ok "Deleted $($entry.Path)"
            $gone++
        }
    }
    if ($gone -eq 0) { Write-Skip 'No template-only files left to delete' }
}

function Update-RepoReferences {
    <#
    .SYNOPSIS
        Replaces references to the source template's owner/repo with the new one's.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$OldOwnerRepo,
        [Parameter(Mandatory)][string]$NewOwnerRepo
    )
    $targets = [System.Collections.Generic.List[string]]::new()
    $targets.AddRange(
        [string[]]@('CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md'))
    $issueDir = Join-Path $RepoPath '.github/ISSUE_TEMPLATE'
    if (Test-Path $issueDir) {
        $forms = Get-ChildItem $issueDir -File
        foreach ($form in $forms) {
            $targets.Add(".github/ISSUE_TEMPLATE/$($form.Name)")
        }
    }
    foreach ($rel in $targets) {
        $f = Join-Path $RepoPath $rel
        if (Test-Path $f) {
            $raw = Get-Content -Raw $f
            if ($raw.Contains($OldOwnerRepo)) {
                $updated = $raw.Replace($OldOwnerRepo, $NewOwnerRepo)
                Set-Content -Path $f -Value $updated -NoNewline
                Write-Ok "Updated references in $rel"
            }
        }
    }
}

function Update-Readme {
    <#
    .SYNOPSIS
        De-links the README rows for the template-only files,
        then prunes the orphaned link definitions.
    .DESCRIPTION
        De-links rather than deletes:
        the table's "Exists only in .github repo" column
        is what documents that the file is deliberately absent here,
        so the row must survive.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$Labels = @($script:TemplateOnlyFiles.Label)
    )
    $f = Join-Path $RepoPath 'README.md'
    if (-not (Test-Path $f)) { Write-Skip 'README.md not found'; return }

    $raw = Get-Content -Raw $f
    $original = $raw

    # 1) '[Display Name][label]' -> 'Display Name', keeping the table row.
    foreach ($label in $Labels) {
        $raw = $raw -replace "\[([^\]]+)\]\[$([regex]::Escape($label))\]", '$1'
    }

    # 2) Garbage-collect '[label]: url' definitions nothing references any more.
    $lines = [System.Collections.Generic.List[string]]@($raw -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '^\[(?<label>[^\]]+)\]:\s') { continue }
        $token = "[$($Matches['label'])]"
        $used = $false
        for ($j = 0; $j -lt $lines.Count; $j++) {
            if ($j -eq $i) { continue }
            # Other definitions aren't usages.
            if ($lines[$j] -match '^\[[^\]]+\]:\s') { continue }
            if ($lines[$j].Contains($token)) { $used = $true; break }
        }
        if (-not $used) { $lines.RemoveAt($i) }
    }
    $raw = ($lines -join "`r`n")
    if (-not $raw.EndsWith("`r`n")) { $raw += "`r`n" }

    if ($raw -eq $original) {
        Write-Skip 'README.md already has no template-only links'
        return
    }
    $raw | Set-Content -NoNewline -Encoding utf8 $f
    Write-Ok 'De-linked the template-only files in README.md'
}

function Set-TemplateSyncConfig {
    <#
    .SYNOPSIS
        Points Template Sync at this repo's parent and enables the schedule.
    .DESCRIPTION
        Retargeting matters: TEMPLATE_REPO_URL is inherited verbatim,
        so without this a level-2 repo keeps syncing from its GRANDparent,
        and never sees its actual parent's changes.
    .PARAMETER TemplateOwnerRepo
        The parent template as owner/repo,
        normalised to the https URL the workflow needs.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$TemplateOwnerRepo
    )
    $f = Join-Path $RepoPath '.github/workflows/template-sync.yml'
    if (-not (Test-Path $f)) {
        Write-Warn 'template-sync.yml not found'
        return
    }

    $raw = Get-Content -Raw $f
    $original = $raw

    # Use [^\r\n] and [ \t], never '.' or \s:
    # '.' matches CR and would convert CRLF to LF.
    $httpsUrl = "https://github.com/$TemplateOwnerRepo.git"
    $urlPattern = '(?m)^([ \t]*TEMPLATE_REPO_URL:[ \t]*)[^\r\n]*'
    $raw = $raw -replace $urlPattern, "`${1}$httpsUrl"

    # Match the SHAPE of the lines, never a specific cron:
    # half-uncommenting the block yields a 'schedule:' with no entries,
    # which GitHub rejects.
    # No '$' anchor - CRLF defeats it.
    $raw = $raw -replace '(?m)^([ \t]*)#[ \t]*(schedule:)', '$1$2'
    $raw = $raw -replace '(?m)^([ \t]*)#[ \t]*(- cron:[^\r\n]*)', '$1  $2'

    if ($raw -eq $original) {
        Write-Skip 'Template Sync already targets the parent and is scheduled'
        return
    }
    $raw | Set-Content -NoNewline $f
    Write-Ok 'Configured Template Sync'
    Write-Detail "source   : $httpsUrl"
    # Report the cron the template actually declares rather than assuming a
    # cadence.
    $cron = [regex]::Match($raw, '(?m)^[ \t]*- cron:[ \t]*(.+?)[ \t]*\r?$')
    $cronLine = $cron.Groups[1].Value
    if (-not $cronLine) { $cronLine = '(no cron found)' }
    Write-Detail "schedule : $cronLine"
}

function Remove-ScriptsFolder {
    <#
    .SYNOPSIS
        Deletes the scripts/ folder in a code repo, which isn't derived from.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $dir = Join-Path $RepoPath 'scripts'
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force
        Write-Ok "Removed scripts/ (code repo won't be derived from)"
    }
}

function Add-GitExclude {
    <#
    .SYNOPSIS
        Adds a pattern to .git/info/exclude, a per-clone ignore list.
    .DESCRIPTION
        .git/info/exclude is never committed,
        so it can't leak into the template chain the way .gitignore would.
        Idempotent. Uses LF: this is a git-internal control file,
        and a stray CR would become part of the pattern.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Pattern
    )
    $excludeFile = Join-Path $RepoPath '.git/info/exclude'
    $infoDir = Split-Path -Parent $excludeFile
    if (-not (Test-Path $infoDir)) {
        New-Item -ItemType Directory -Force $infoDir | Out-Null
    }

    $lines = if (Test-Path $excludeFile) {
        @(Get-Content $excludeFile)
    }
    else { @() }
    if ($lines -contains $Pattern) {
        Write-Skip "'$Pattern' is already excluded locally"
        return
    }

    $out = @($lines) + @($Pattern)
    [System.IO.File]::WriteAllText($excludeFile, (($out -join "`n") + "`n"))
    Write-Ok "Excluded '$Pattern' via .git/info/exclude (never committed)"
}

function Write-SettingsFile {
    <#
    .SYNOPSIS
        Writes the minimal _extends settings.yml.
        Kind=Code also sets is_template: false.
    .DESCRIPTION
        Skipped only when the file already names THIS repo.
        Testing for '_extends:' alone would wrongly preserve
        the parent's inherited settings.yml.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][ValidateSet('Template', 'Code')][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExtendsRepo,
        [Parameter(Mandatory)][string]$Description,
        [string]$Homepage,
        [Parameter(Mandatory)][string]$Topics
    )
    $settingsPath = Join-Path $RepoPath '.github/settings.yml'
    if (Test-Path $settingsPath) {
        $existing = Get-Content -Raw $settingsPath
        if ($existing -match "(?m)^\s*name:\s*$([regex]::Escape($Name))\s*$") {
            Write-Skip "settings.yml already targets '$Name'"
            return
        }
    }
    $sep = '  #' + ('─' * 77)
    $repoPluginDoc = '  # https://github.com/repository-settings/app' +
    '/blob/master/docs/plugins/repository.md'
    $lines = [System.Collections.Generic.List[string]]::new()
    @(
        '# Inherit everything from the immediate parent template and override'
        '# only what differs. The Settings app resolves _extends RECURSIVELY,'
        '# so this repo also picks up every ancestor through the chain'
        '# (e.g. .template-dotnet -> .github). Bare repo name = same owner.'
        "_extends: $ExtendsRepo"
        ''
        'repository:'
        $sep
        '  # "About" section (on Home Page)'
        $repoPluginDoc
        '  # https://docs.github.com/en/rest/repos/repos#update-a-repository'
        $sep
        ''
        '  # A short description of the repo'
        '  # MUST BE A SINGLE LINE'
        "  description: $Description"
        ''
        '  # A URL with more information about the repo'
    ) | ForEach-Object { $lines.Add($_) }
    if ($Homepage) { $lines.Add("  homepage: $Homepage") }
    else { $lines.Add('  # homepage: (none)') }
    @(
        ''
        '  # A comma-separated list of topics to set on the repo'
        '  # See https://github.com/topics'
        "  topics: $Topics"
        ''
        $sep
        '  # Settings -> General'
        $repoPluginDoc
        '  # https://docs.github.com/en/rest/repos/repos#update-a-repository'
        $sep
        ''
        '  # The name of the repo'
        "  name: $Name"
    ) | ForEach-Object { $lines.Add($_) }
    if ($Kind -eq 'Code') {
        @(
            ''
            '  # Code repo: not a template (override the inherited value)'
            '  is_template: false'
            ''
            $sep
            '  # Settings -> General -> Pull Requests'
            $sep
            ''
            '  # Template layers rebase-merge so their history stays linear'
            '  # and no merge commits propagate downstream. A code repo is'
            '  # derived FROM but never derived from, so it can merge'
            '  # normally: rewrite history in a PR, then merge it as-is.'
            '  allow_merge_commit: true'
            '  allow_squash_merge: false'
            '  allow_rebase_merge: false'
        ) | ForEach-Object { $lines.Add($_) }
    }
    $settingsDir = Split-Path -Parent $settingsPath
    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Force $settingsDir | Out-Null
    }
    $content = ($lines -join "`r`n") + "`r`n"
    Set-Content -Path $settingsPath -Value $content -NoNewline -Encoding utf8
    Write-Ok "Wrote .github/settings.yml ($Kind)"
}

#───────────────────────────────────────────────────────────────────────────────
# Step: VS Code multi-root workspace
#───────────────────────────────────────────────────────────────────────────────

function Write-WorkspaceFile {
    <#
    .SYNOPSIS
        Writes a multi-root <repo>.code-workspace,
        spanning the new repo and its template chain.
    .DESCRIPTION
        Paths resolve against this file's own folder,
        so the new repo is "." and its ancestors are "../<name>",
        forward slashes only.
        The new repo is listed first,
        because tooling that is not multi-root aware only sees folders[0].
        dotnet.defaultSolution is window-scoped,
        so it must live in the workspace 'settings' block;
        it is ignored per-folder.
    .PARAMETER ChainPaths
        Ancestor template paths, nearest first.
    .PARAMETER Force
        Overwrites an existing workspace file, instead of leaving edits alone.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RepoName,
        [string[]]$ChainPaths = @(),
        [switch]$Force
    )
    $repoFull = (Resolve-Path $RepoPath).Path
    $wsPath = Join-Path $repoFull "$RepoName.code-workspace"
    if ((Test-Path $wsPath) -and -not $Force) {
        Write-Skip "$RepoName.code-workspace already exists"
        return $wsPath
    }

    # ── folders: primary repo first, then each ancestor as a sibling relative
    # path ──
    $folders = [System.Collections.Generic.List[string]]::new()
    $folders.Add(
        "`t`t// The new repo. Listed first so it is folders[0], the primary.")
    $folders.Add("`t`t{ `"name`": `"$RepoName`", `"path`": `".`" },")
    if ($ChainPaths.Count -gt 0) {
        $folders.Add(
            "`t`t// Template layers inherited from, nearest parent first.")
        foreach ($p in $ChainPaths) {
            $name = Split-Path -Leaf $p
            $full = (Resolve-Path $p).Path
            $rel = [System.IO.Path]::GetRelativePath($repoFull, $full)
            $rel = $rel -replace '\\', '/'
            $folders.Add("`t`t{ `"name`": `"$name`", `"path`": `"$rel`" },")
        }
    }

    # Pin the primary repo's solution,
    # or C# Dev Kit adopts a template layer's placeholder one -
    # or prompts on every open when it finds several.
    $slns = Get-ChildItem -LiteralPath $repoFull `
        -Include *.sln, *.slnx, *.slnf `
        -File `
        -Recurse `
        -Depth 3 `
        -ErrorAction SilentlyContinue
    $slns = $slns | Where-Object {
        $_.FullName -notmatch '[\\/](bin|obj|node_modules|\.git)[\\/]'
    }
    $slns = @($slns | Sort-Object FullName)
    $settings = [System.Collections.Generic.List[string]]::new()
    if ($slns.Count -gt 0) {
        $sln = $slns[0].FullName.Substring($repoFull.Length)
        $rel = $sln.TrimStart('\', '/') -replace '\\', '/'
        if ($slns.Count -gt 1) {
            $settings.Add(
                "`t`t// $($slns.Count) solutions found; pinned the first.")
        }
        $settings.Add(
            "`t`t// Relative to folders[0]. Forward slashes required.")
        $settings.Add("`t`t`"dotnet.defaultSolution`": `"$rel`"")
    }
    else {
        $settings.Add(
            "`t`t// No solution yet. 'disable' stops C# Dev Kit from adopting")
        $settings.Add(
            "`t`t// a TEMPLATE layer's, and silences the 'open solution' nag.")
        $settings.Add(
            "`t`t// Replace with e.g. `"MyRepo.sln`" once you add one.")
        $settings.Add("`t`t`"dotnet.defaultSolution`": `"disable`"")
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    @(
        '{'
        "`t// Multi-root workspace for $RepoName and its template layers."
        "`t// Generated by the scaffolding scripts; local-only."
        "`t// Safe to edit or delete - it is never regenerated over edits."
        "`t`"folders`": ["
    ) | ForEach-Object { $lines.Add($_) }
    $folders | ForEach-Object { $lines.Add($_) }
    @(
        "`t],"
        "`t`"settings`": {"
    ) | ForEach-Object { $lines.Add($_) }
    $settings | ForEach-Object { $lines.Add($_) }
    @(
        "`t}"
        '}'
    ) | ForEach-Object { $lines.Add($_) }

    $content = ($lines -join "`r`n") + "`r`n"
    Set-Content -Path $wsPath -Value $content -NoNewline -Encoding utf8
    Add-Change
    Write-Ok "Wrote $RepoName.code-workspace ($(1 + $ChainPaths.Count) folders)"
    return $wsPath
}

function Start-VSCode {
    <#
    .SYNOPSIS
        Opens a path in VS Code as a separate, detached process.
    .DESCRIPTION
        The path can be a folder or a .code-workspace.

        Prefers Code.exe over the code.cmd shim:
        launching the .cmd through Start-Process flashes a console window,
        while the exe returns immediately and cleanly.
        Falls back to the shim, then to Insiders.
        Never throws - failing to open an editor
        should not fail a successful scaffold.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [switch]$NewWindow
    )
    $exe = $null

    # Derive Code.exe from the shim on PATH:
    # <root>\bin\code.cmd -> <root>\Code.exe
    foreach ($cliName in 'code', 'code-insiders') {
        $cli = Get-Command $cliName -ErrorAction SilentlyContinue
        if (-not $cli) { continue }
        $shim = $cli.Source
        $exeName = if ($cliName -eq 'code-insiders') {
            'Code - Insiders.exe'
        }
        else { 'Code.exe' }
        $root = Split-Path -Parent (Split-Path -Parent $shim)
        $candidate = Join-Path $root $exeName
        if (Test-Path $candidate) { $exe = $candidate; break }
        $exe = $shim; break      # shim works too, just less tidy
    }
    if (-not $exe) {
        foreach ($p in @(
                "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
                "$env:ProgramFiles\Microsoft VS Code\Code.exe",
                "${env:ProgramFiles(x86)}\Microsoft VS Code\Code.exe"
            )) {
            if (Test-Path $p) { $exe = $p; break }
        }
    }
    if (-not $exe) {
        Write-Warn "VS Code CLI not found - open it yourself: $Target"
        return
    }

    $argList = @()
    if ($NewWindow) { $argList += '-n' }
    $argList += $Target
    try {
        Start-Process -FilePath $exe -ArgumentList $argList | Out-Null
        Write-Ok "Opening in VS Code: $(Split-Path -Leaf $Target)"
    }
    catch {
        Write-Warn ("Couldn't launch VS Code ($($_.Exception.Message)) - " +
            "open it yourself: $Target")
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Step: commit / push / workflows
#───────────────────────────────────────────────────────────────────────────────

function Invoke-GatedCommit {
    <#
    .SYNOPSIS
        Runs a group of related changes and commits them,
        unless that commit already exists.
    .DESCRIPTION
        $Message is both the commit subject and the idempotency key,
        so rewording one silently makes an already-scaffolded repo
        look unscaffolded.
    .PARAMETER Paths
        Pathspec to stage.
        Omit it to stage exactly what -Body changed,
        which is what you want for anything repo-wide.
        Either way your own uncommitted work is excluded.
    .PARAMETER Body
        Scriptblock; it still sees the calling script's variables.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [string[]]$Paths,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    if (Test-CommitExists -RepoPath $RepoPath -Message $Message) {
        Write-Skip "'$Message' already in history"
        return
    }

    if ($Paths) {
        & $Body
        Invoke-StagedCommit -RepoPath $RepoPath -Message $Message `
            -Paths $Paths
        return
    }

    # No -Paths: stage exactly what the body touched.
    # A hand-maintained list would silently omit files
    # that a repo-wide rename moved.
    $before = @(Get-DirtyPath -RepoPath $RepoPath)
    & $Body
    $after = @(Get-DirtyPath -RepoPath $RepoPath)
    $touched = @($after | Where-Object { $_ -notin $before })
    if (-not $touched) { Write-Skip "Nothing changed for: $Message"; return }
    Invoke-StagedCommit -RepoPath $RepoPath -Message $Message -Paths $touched
}

function Get-DirtyPath {
    <#
    .SYNOPSIS
        Returns the paths git currently reports as changed, one per entry.
    .DESCRIPTION
        A rename shows up as 'R old -> new'; BOTH sides are returned,
        because staging only the new path would leave the deletion
        of the old one out of the commit.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $lines = @(git -C $RepoPath status --porcelain 2>$null)
    $global:LASTEXITCODE = 0
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line.Length -le 3) { continue }
        $rest = $line.Substring(3)
        foreach ($p in ($rest -split ' -> ')) {
            $t = $p.Trim().Trim('"')
            if ($t) { $paths.Add($t) }
        }
    }
    return $paths.ToArray()
}

function Invoke-LayerModule {
    <#
    .SYNOPSIS
        Runs each layer module's entry point, base layer first.
        No-op if the chain has none.
    .DESCRIPTION
        Layers commit their own work via Invoke-GatedCommit.
        This only warns if one leaves changes uncommitted,
        since every later step stages an explicit pathspec.
    .PARAMETER Context
        RepoPath, RepoName, Kind, OwnerRepo, SourceOwnerRepo.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $layers = Import-LayerModule
    if (-not $layers) {
        Write-Skip ('No Helpers-*.psm1 layers in this chain - ' +
            'nothing template-specific to apply')
        return
    }
    # Snapshot first, so the check below reports only what the LAYERS dirtied.
    # The developer's own uncommitted work was already there,
    # and is none of our business.
    $status = {
        @(git -C $RepoPath status --porcelain 2>$null)
        $global:LASTEXITCODE = 0
    }
    $before = @(& $status)

    foreach ($layer in $layers) {
        Write-Info "$($layer.Name) -> $($layer.Entry.Name)"
        & $layer.Entry -Context $Context
    }

    # A layer that changed files but committed nothing
    # would leave them uncommitted forever:
    # every later step stages an explicit pathspec,
    # so nothing else picks them up.
    $left = @((& $status) | Where-Object { $_ -notin $before })
    if ($left) {
        Write-Warn "$($left.Count) file(s) changed by a layer, uncommitted"
        foreach ($l in $left) { Write-Detail $l.Trim() }
        Write-Detail 'a layer should commit via Invoke-GatedCommit'
    }
}

function Rename-Token {
    <#
    .SYNOPSIS
        Replaces a placeholder token in file content, file names,
        and directory names.
    .DESCRIPTION
        Deepest paths first,
        so renaming a parent cannot invalidate its children's paths.
    .PARAMETER SkipExtension
        Binary-ish extensions to leave alone.
    .PARAMETER Exclude
        Directory names to skip entirely, such as .git and build output.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [string[]]$SkipExtension = @(
            '.png', '.jpg', '.jpeg', '.gif', '.ico', '.svg',
            '.pdf', '.zip', '.dll', '.exe', '.snk'
        ),
        [string[]]$Exclude = @('.git', 'bin', 'obj', 'node_modules')
    )
    if ($From -eq $To) {
        Write-Skip "Nothing to rename ('$From' is already '$To')"
        return
    }

    $escaped = ($Exclude | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $skipRx = "[\\/]($escaped)[\\/]"
    $all = Get-ChildItem -LiteralPath $RepoPath `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
    $all = @($all | Where-Object { $_.FullName -notmatch $skipRx })

    # 1) content
    $edited = 0
    $files = @($all | Where-Object {
            -not $_.PSIsContainer -and $_.Extension -notin $SkipExtension
        })
    foreach ($f in $files) {
        $raw = Get-Content -LiteralPath $f.FullName -Raw `
            -ErrorAction SilentlyContinue
        if ($null -ne $raw -and $raw.Contains($From)) {
            $updated = $raw.Replace($From, $To)
            Set-Content -LiteralPath $f.FullName -Value $updated -NoNewline
            $edited++
        }
    }

    # 2) names, deepest first
    $renamed = 0
    $depth = { $_.FullName.Split([char]'\').Count }
    $named = $all | Where-Object { $_.Name.Contains($From) }
    $named = @($named | Sort-Object $depth -Descending)
    foreach ($item in $named) {
        # Skip anything a parent rename already moved.
        if (-not (Test-Path -LiteralPath $item.FullName)) { continue }
        Rename-Item -LiteralPath $item.FullName `
            -NewName ($item.Name.Replace($From, $To)) -ErrorAction Stop
        $renamed++
    }

    if ($edited -eq 0 -and $renamed -eq 0) {
        Write-Skip "No '$From' found to rename"
        return
    }
    Write-Ok "Renamed '$From' -> '$To'"
    Write-Detail "$edited file(s) edited, $renamed path(s) renamed"
}

function Invoke-StagedCommit {
    <#
    .SYNOPSIS
        Stages the paths this group owns and commits,
        but only if something is actually staged.
    .DESCRIPTION
        -Paths is a deliberate safety boundary.
        Staging everything ('git add -A') is unsafe on a re-run:
        if a group legitimately produces no diff,
        because the parent template already did that work,
        then no commit is made, its gate stays false,
        and the group runs again on every future run -
        sweeping a developer's unrelated uncommitted work
        into a 'chore:' commit.
        Scoping the pathspec makes an ungated no-diff group harmless.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [string[]]$Paths = @('.')
    )
    # 'git add -- <path>' is a hard error
    # when the path is neither on disk nor tracked, so drop those first -
    # e.g. scripts/ in a template repo, which is untouched.
    $spec = @($Paths | Where-Object {
            if (Test-Path (Join-Path $RepoPath $_)) { return $true }
            git -C $RepoPath ls-files --error-unmatch -- $_ 2>&1 | Out-Null
            $tracked = ($LASTEXITCODE -eq 0)
            $global:LASTEXITCODE = 0
            return $tracked
        })
    if (-not $spec) { Write-Skip "Nothing to stage for: $Message"; return }

    Invoke-Git -What 'Staging changes' -RepoPath $RepoPath `
        -Arguments (@('add', '-A', '--') + $spec) | Out-Null
    git -C $RepoPath diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        # Summarise what is going in BEFORE committing,
        # so the log shows the grouping.
        $staged = @(git -C $RepoPath diff --cached --name-status 2>$null)
        Invoke-Git -What "Committing '$Message'" -RepoPath $RepoPath `
            -Arguments @('commit', '-m', $Message) | Out-Null
        Add-Change
        Write-Ok "Committed: $Message"
        foreach ($line in $staged) {
            $parts = $line -split "`t", 2
            if ($parts.Count -eq 2) {
                Write-Detail ('{0}  {1}' -f $parts[0].PadRight(2), $parts[1])
            }
        }
    }
    else {
        Write-Skip "Nothing to commit for: $Message"
    }
}

function Push-Repo {
    <#
    .SYNOPSIS
        Pushes main. Idempotent: 'Everything up-to-date' when nothing changed.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $out = Invoke-Git -What 'Pushing main' -RepoPath $RepoPath `
        -Arguments @('push', '-u', 'origin', 'main')
    if (($out | Out-String) -match 'Everything up-to-date') {
        Write-Skip 'main already up to date on the remote'
    }
    else {
        Write-Ok 'Pushed main'
        Write-Detail "the 'Settings' app applies settings.yml in a few minutes"
    }
}

function Start-TemplateSync {
    <#
    .SYNOPSIS
        Dispatches the Template Sync workflow,
        to verify it works and initialize its baseline.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    $ghArgs = @(
        'workflow', 'run', 'template-sync.yml'
        '--repo', $OwnerRepo
        '--ref', 'main'
    )
    & gh @ghArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Add-Change
        Write-Ok 'Dispatched Template Sync'
        Write-Detail ("verify: gh run list --repo $OwnerRepo " +
            '--workflow template-sync.yml')
        Write-Detail "expect no errors and NO pull request"
    }
    else {
        Write-Warn ('Could not dispatch Template Sync yet ' +
            '(the workflow may still be registering)')
        Write-Detail "run it from https://github.com/$OwnerRepo/actions"
    }
}

Export-ModuleMember -Function @(
    # Logging vocabulary - part of the contract; the scripts use these directly.
    'Write-Ok'
    'Write-Skip'
    'Write-Warn'
    'Write-Err'
    'Write-Info'
    'Write-Detail'

    'Invoke-Git'
    'Invoke-Gh'
    'Get-RepoOwner'
    'Get-TemplateBranch'
    'Write-Step'
    'Write-Field'
    'Show-Summary'
    'Show-Failure'
    'Format-Slug'
    'Confirm-Proceed'
    'Invoke-GatedCommit'
    'Invoke-LayerModule'
    'Rename-Token'
    'Get-DirtyPath'
    'Get-LayerModule'
    'Import-LayerModule'
    'Remove-LayerModule'
    'Resolve-Input'
    'Set-SkipPrompts'
    'Get-ChangeCount'
    'Add-ManualItem'
    'Register-ManualSettings'
    'Show-ManualChecklist'
    'Get-TemplateContext'
    'Get-ActiveGhAccount'
    'Use-GhAccount'
    'Reset-GhAccount'
    'New-GitHubRepo'
    'Set-ActionsPermissions'
    'Enable-PrivateVulnReporting'
    'Set-CodecovSecret'
    'Initialize-Topics'
    'Enable-ImmutableReleases'
    'Add-CodeqlLanguage'
    'Get-CodeqlLanguage'
    'Enable-Codeql'
    'Get-NewRepoUrl'
    'Get-TemplateChain'
    'Initialize-Clone'
    'Test-CommitExists'
    'Remove-TemplateOnlyFiles'
    'Update-RepoReferences'
    'Update-Readme'
    'Set-TemplateSyncConfig'
    'Remove-ScriptsFolder'
    'Add-GitExclude'
    'Write-WorkspaceFile'
    'Start-VSCode'
    'Write-SettingsFile'
    'Invoke-StagedCommit'
    'Push-Repo'
    'Start-TemplateSync'
)
