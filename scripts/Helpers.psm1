#Requires -Version 7.0
<#
    Helpers.psm1

    Shared helpers for creating new repos derived from a template repo.
    Imported by New-Repo.ps1 in this same folder, which takes -Kind Template|Code.

    New-Repo.ps1 is meant to be run FROM the template repo you are deriving from.
    Get-ScaffoldContext discovers that source repo from the script location,
    so nothing here is hard-coded to a specific owner/repo.

    KEEP THIS FILE IDENTICAL AT EVERY LAYER. It is inherited by merge, so any per-layer
    edit becomes a conflict on every future template change. Layer-specific behaviour
    belongs in additive Scaffold-<NN>-<slug>.ps1 step files alongside it (see below).

    Design goals
    ------------
    * Thin script: every step is a helper here; the script mostly just calls them.
    * Idempotent / resumable: re-running on a repo that's already (partly) set up
      verifies existing state and only does what's missing. A fully-scaffolded repo
      is a no-op - it never overwrites changes made after scaffolding.
    * Non-blocking: settings GitHub only exposes in the web UI are collected and
      printed as a checklist at the end instead of pausing mid-run.

    All file/git helpers take explicit paths (-RepoPath) and use `git -C`, so
    nothing depends on the current working directory.
#>

Set-StrictMode -Version Latest

#───────────────────────────────────────────────────────────────────────────────
# Configuration
#───────────────────────────────────────────────────────────────────────────────

# This scaffolding is for personal use only: every template layer and every repo it
# creates lives under one account. Hard-coding the owner removes a parameter, a prompt,
# and all cross-owner handling - notably the `_extends` owner trap, where the Settings
# app resolves every hop against the LEAF repo's owner rather than the parent's.
$script:ScaffoldOwner = 'TaffarelJr'

function Get-ScaffoldOwner { return $script:ScaffoldOwner }

#───────────────────────────────────────────────────────────────────────────────
# Per-layer customization steps
#───────────────────────────────────────────────────────────────────────────────
<#
    Each layer contributes its own scaffolding steps as ADDITIVE files next to this one:

        Helpers-10-dotnet.psm1    added by .template-dotnet
        Helpers-20-nuget.psm1     added by .template-nuget
        Helpers-20-winui.psm1     added by .template-winui   (sibling; never sees nuget's)

    Naming convention: Helpers-<NN>-<slug>.psm1, loaded in filename order, so <NN> is the
    layer tier. Each module exports helper functions for its descendants to reuse, PLUS exactly
    one entry point matching Invoke-*Scaffold:

        function Rename-DotnetPlaceholder { ... }        # reusable by lower layers
        function Invoke-DotnetScaffold {
            param([hashtable]$Context)   # RepoPath, RepoName, Kind, OwnerRepo, SourceOwnerRepo
            Rename-DotnetPlaceholder -RepoPath $Context.RepoPath -To $Context.RepoName
        }
        Export-ModuleMember -Function Rename-DotnetPlaceholder, Invoke-DotnetScaffold

    The entry point is found via the module's own ExportedFunctions, so the function name is
    never coupled to the filename - only to the Invoke-*Scaffold pattern. Exactly one is
    required; zero or several is a configuration error worth failing on.

    They are imported -Global so that every layer's helpers are visible to the layers below it
    (verified: a nuget module can call a dotnet module's exported helper). That is the point of
    using modules rather than plain scripts.

    WHY ONE MODULE PER LAYER: with a single fixed filename, every layer would have to EDIT its
    parent's copy to append its own steps - guaranteeing a merge conflict on that file forever,
    and forcing the child to re-state the parent's logic. With one per layer, a child ADDS a
    file and never touches an inherited one, so template merges stay clean.

    A layer module can call anything Helpers.psm1 EXPORTS (Write-Ok, Invoke-ScaffoldGit,
    Rename-ScaffoldToken, ...) - verified - but not its private internals.

    They are read from the SOURCE template (wherever New-Repo.ps1 is running from), not from the
    new repo - so a leaf still gets its ancestors' renames even though scaffolding deletes the
    leaf's own scripts/ folder. Base layers with nothing to customize contribute no file.
#>

function Get-ScaffoldLayerModule {
    <# The layer modules contributed by this template chain, in load order. #>
    # Check the extension explicitly: a Windows -Filter of '*.psm1' can behave loosely, and the
    # 'Scaffold-' prefix already excludes this file itself.
    return @(Get-ChildItem -Path $PSScriptRoot -Filter 'Helpers-*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.psm1' } | Sort-Object Name)
}

function Import-ScaffoldLayerModule {
    <#
        Load every layer module and return its (module, entry point) pairs in order.
        -Global is required so lower layers can call upper layers' exported helpers.
    #>
    $loaded = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ScaffoldLayerModule) {
        $mod = Import-Module $file.FullName -Force -Global -PassThru
        $entry = @($mod.ExportedFunctions.Values | Where-Object { $_.Name -like 'Invoke-*Scaffold' })
        if ($entry.Count -ne 1) {
            throw ("$($file.Name) must export exactly one Invoke-*Scaffold entry point, " +
                "but exports $($entry.Count)$(if ($entry) { ": $($entry.Name -join ', ')" }).")
        }
        $loaded.Add([pscustomobject]@{ Name = $file.Name; Module = $mod; Entry = $entry[0] })
    }
    return $loaded.ToArray()
}

function Remove-ScaffoldLayerModule {
    <# Unload the layer modules so an interactive session isn't left holding them. #>
    foreach ($file in Get-ScaffoldLayerModule) {
        Remove-Module ([System.IO.Path]::GetFileNameWithoutExtension($file.Name)) -Force -ErrorAction SilentlyContinue
    }
}

# Files that exist ONLY in the base .github repo. Single source of truth: the same table
# drives both the deletion and the README de-linking, so the two can't drift apart.
# 'Label' is the markdown link-reference label the README uses for that file.
$script:TemplateOnlyFiles = @(
    @{ Path = '.github/FUNDING.yml'; Label = 'fundingFile' }
    @{ Path = '.github/ISSUE_TEMPLATE/config.yml'; Label = 'issueChooserFile' }
)

#───────────────────────────────────────────────────────────────────────────────
# Internal state & logging
#───────────────────────────────────────────────────────────────────────────────

$script:SkipManualPrompts = $false                                   # suppress interactive prompts
$script:CurrentStep = ''                                             # for the failure banner
$script:CurrentStepTitle = ''
$script:ManualItems = [System.Collections.Generic.List[object]]::new()

# Two DIFFERENT axes, deliberately kept apart:
#   $Succeeded/$Skipped/$Warnings - display tallies for the end-of-run summary.
#   $Activity                     - did this run CHANGE anything that matters? Gates the
#                                   Template Sync dispatch and the "already fully
#                                   scaffolded" message, so it must NOT count mere
#                                   successful verifications (admin check, push no-op...).
$script:Succeeded = 0
$script:Skipped = 0
$script:Warnings = 0
$script:Activity = 0

$script:Rule = '─' * 72

# One marker per outcome, used by EVERY operation so the log reads consistently:
#   ✅ succeeded   ⏭️ already done   ⚠️ warning   ❌ failed   ℹ️ neutral note
function Write-Ok { param([string]$Msg) $script:Succeeded++; Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) $script:Skipped++; Write-Host "  ⏭️  $Msg" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Msg) $script:Warnings++; Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow }
function Write-Err { param([string]$Msg) Write-Host "  ❌ $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "  ℹ️  $Msg" -ForegroundColor Gray }

# Flags that this run changed real state (see $Activity above).
function Add-ScaffoldActivity { $script:Activity++ }

# Indented continuation line, for detail belonging to the marker above it.
function Write-Detail { param([string]$Msg) Write-Host "       $Msg" -ForegroundColor DarkGray }

# Aligned label/value pair, for the run header in step 0. Exported, so it is named
# Write-ScaffoldField to match the module's public prefix.
function Write-ScaffoldField {
    # An empty -Label is allowed: it renders a continuation line under the field above.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Label, [string]$Value)
    Write-Host ("  ·  {0,-18}{1}" -f $Label, $Value) -ForegroundColor Gray
}

function Assert-LastExit {
    param([Parameter(Mandatory)][string]$What)
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

function Format-ScaffoldSlug {
    <# Normalise and validate a repo-name slug. One regex, one error wording, both scripts. #>
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Label)
    $slug = $Value.Trim().ToLowerInvariant()
    if ($slug -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
        throw "$Label must be kebab-case (letters/digits/hyphens): '$slug'"
    }
    return $slug
}

function Confirm-ScaffoldProceed {
    <#
        Final go/no-go gate. Returns $true when the run should continue. Honours the module's
        own skip-prompts state rather than a second copy of the switch in each script, and
        reports an abort through Write-Warn so it looks like every other warning.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    if ($script:SkipManualPrompts) { return $true }
    if ((Read-Host "  Type 'yes' to create/verify $OwnerRepo") -eq 'yes') { return $true }
    Write-Warn 'Aborted by user.'
    return $false
}

function Write-ScaffoldStep {
    <# Start a step. Records it so a failure banner can name where things went wrong. #>
    param([Parameter(Mandatory)][string]$Number, [Parameter(Mandatory)][string]$Title)
    $script:CurrentStep = $Number
    $script:CurrentStepTitle = $Title
    $head = "═══ STEP $Number · $Title "
    Write-Host ""
    Write-Host ($head + ('═' * [Math]::Max(0, 72 - $head.Length))) -ForegroundColor Cyan
}

function Get-ScaffoldActivity { return $script:Activity }

function Show-ScaffoldSummary {
    <# One-line tally so the end of a run is readable at a glance. #>
    Write-Host ""
    Write-Host ("  {0} ok · {1} already done · {2} warning(s)" -f `
            $script:Succeeded, $script:Skipped, $script:Warnings) -ForegroundColor Gray
}

function Show-ScaffoldFailure {
    <#
        Render a terminating error as a readable banner instead of a raw PowerShell dump:
        which step failed, the message, the offending line, and the script stack trace.
        Scaffolding is resumable, so it also says what to do next.
    #>
    param([Parameter(Mandatory)]$ErrorRecord)
    Write-Host ""
    Write-Host $script:Rule -ForegroundColor Red
    $where = if ($script:CurrentStep -ne '') { " — STEP $($script:CurrentStep) · $($script:CurrentStepTitle)" } else { '' }
    Write-Host " ❌ SCAFFOLDING FAILED$where" -ForegroundColor Red
    Write-Host $script:Rule -ForegroundColor Red
    Write-Host ""
    Write-Host "  $($ErrorRecord.Exception.Message)" -ForegroundColor Red

    $inv = $ErrorRecord.InvocationInfo
    if ($inv -and $inv.ScriptName) {
        Write-Host ""
        Write-Host "  at $(Split-Path -Leaf $inv.ScriptName):$($inv.ScriptLineNumber)" -ForegroundColor DarkGray
        if ($inv.Line) { Write-Detail $inv.Line.Trim() }
    }
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Host ""
        Write-Host "  Stack trace:" -ForegroundColor DarkGray
        foreach ($line in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
            if ($line.Trim()) { Write-Detail $line.Trim() }
        }
    }
    Show-ScaffoldSummary
    Write-Host ""
    Write-Host "  Nothing was rolled back. Fix the cause and re-run - it resumes where it left off." -ForegroundColor Yellow
    Write-Host ""
}

function Invoke-ScaffoldGit {
    <#
        Run git with its chatter CAPTURED rather than dumped to the console, and turn a
        non-zero exit into a clean error that includes git's own output as detail.

        Only for calls where failure is genuinely an error. Calls that USE the exit code as
        a boolean (show-ref --quiet, diff --cached --quiet, rev-parse --verify) stay raw.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    # -Arguments must be an explicit array: passed loose, tokens like '-C' or '-A' would be
    # parsed as PowerShell parameter names instead of git arguments (ValueFromRemaining-
    # Arguments does NOT protect against that - it silently mis-binds).
    $argv = if ($RepoPath) { @('-C', $RepoPath) + $Arguments } else { $Arguments }
    $out = & git @argv 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($out | Out-String).Trim()
        throw ("$What failed: git $($argv -join ' ') (exit $LASTEXITCODE)" +
            $(if ($detail) { "`n$detail" } else { '' }))
    }
    return $out
}

function Invoke-ScaffoldGh {
    <# Same as Invoke-ScaffoldGit, for the gh CLI. -Arguments must be an explicit array. #>
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

function Set-ScaffoldSkipPrompts {
    param([Parameter(Mandatory)][bool]$Skip)
    $script:SkipManualPrompts = $Skip
}

#───────────────────────────────────────────────────────────────────────────────
# Input resolution (command line OR prompt)
#───────────────────────────────────────────────────────────────────────────────

function Resolve-ScaffoldValue {
    <#
        Return a value that may come from the command line or an interactive prompt.
        - If the caller passed the parameter (tracked in $Bound = $PSBoundParameters),
          use $Value as-is and DO NOT prompt - even if it's an empty string.
        - Otherwise, if prompts are suppressed (Set-ScaffoldSkipPrompts $true), return
          $Default without prompting (so unattended runs never block).
        - Otherwise prompt. A non-empty -Default is shown as [default]; ENTER accepts it.
          -Secret prompts without echo (for tokens).
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

function Add-ScaffoldManualItem {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Steps = @()
    )
    $script:ManualItems.Add([pscustomobject]@{ Category = $Category; Title = $Title; Steps = $Steps })
}

function Register-ScaffoldManualSettings {
    <# The four repo settings GitHub only exposes in the web UI (no REST API). #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    # NB: release immutability is NOT listed here - it has a real API now and is handled by
    # Enable-ScaffoldImmutableReleases, which re-adds it to this list only if the call fails.
    $cat = 'GitHub settings — web UI only (no API)'
    $url = "https://github.com/$OwnerRepo/settings"
    Add-ScaffoldManualItem -Category $cat -Title 'Limit branches/tags updated per push to 2' `
        -Steps @("$url  →  General  →  check 'Limit how many branches and tags can be updated in a single push'  →  set 2")
    Add-ScaffoldManualItem -Category $cat -Title 'Restrict code review to users with read+ access' `
        -Steps @("$url  →  Moderation options  →  Code review limits  →  check 'Limit to users explicitly granted read or higher access'")
    Add-ScaffoldManualItem -Category $cat -Title 'Enable grouped security updates' `
        -Steps @("$url/security_analysis  →  enable 'Grouped security updates'")
    Add-ScaffoldManualItem -Category $cat -Title 'Enable the Dependency graph — only if this repo is PRIVATE' `
        -Steps @(
            "$url/security_analysis  →  enable 'Dependency graph'",
            "Not needed for public repos: it is always on and the toggle isn't offered."
        )
    Add-ScaffoldManualItem -Category $cat -Title 'Verify the description and topics appear on the home page' `
        -Steps @("https://github.com/$OwnerRepo  (the Settings app applies settings.yml within a few minutes)")
}

function Show-ScaffoldManualChecklist {
    param([Parameter(Mandatory)][string]$OwnerRepo)
    if ($script:ManualItems.Count -eq 0) { Write-Host "`n✅ No manual follow-up needed." -ForegroundColor Green; return }
    $rule = '─' * 72
    Write-Host ""
    Write-Host $rule -ForegroundColor Yellow
    Write-Host " 📋 MANUAL FOLLOW-UP — $OwnerRepo" -ForegroundColor Yellow
    Write-Host "    These can't be automated; do them in the web UI when convenient." -ForegroundColor Yellow
    Write-Host $rule -ForegroundColor Yellow
    foreach ($group in ($script:ManualItems | Group-Object Category)) {
        Write-Host ""
        Write-Host "  ▸ $($group.Name)" -ForegroundColor Cyan
        $n = 1
        foreach ($item in $group.Group) {
            Write-Host ("    {0}. [ ] {1}" -f $n, $item.Title) -ForegroundColor White
            foreach ($s in $item.Steps) { Write-Host "           $s" -ForegroundColor DarkGray }
            $n++
        }
    }
    Write-Host ""
}

#───────────────────────────────────────────────────────────────────────────────
# Context & prerequisites
#───────────────────────────────────────────────────────────────────────────────

function Get-ScaffoldContext {
    <#
        Discover the SOURCE template repo from the calling script's location. The
        scripts live in <templateRepo>/scripts, so the repo root is the parent of
        $ScriptRoot and new repos are cloned next to it (ParentDir).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptRoot)

    $sourceRoot = Split-Path -Parent $ScriptRoot
    if (-not (Test-Path (Join-Path $sourceRoot '.git'))) {
        throw "No git repo found at '$sourceRoot'. Run this from inside the template repo's scripts/ folder."
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git not found on PATH." }
    if (-not (Get-Command gh  -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found on PATH." }

    $originUrl = (git -C $sourceRoot remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $originUrl) { throw "Could not read 'origin' remote from '$sourceRoot'." }
    $originUrl = $originUrl.Trim()

    if ($originUrl -notmatch '[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$') {
        throw "Could not parse owner/repo from origin URL '$originUrl'."
    }
    if ($Matches['owner'] -ne $script:ScaffoldOwner) {
        Write-Warn ("This repo's origin owner is '$($Matches['owner'])' but the configured owner is " +
            "'$($script:ScaffoldOwner)'. Update `$script:ScaffoldOwner in Helpers.psm1 if that's wrong.")
    }
    [pscustomobject]@{
        SourceOwner     = $Matches['owner']
        SourceRepo      = $Matches['repo']
        SourceOwnerRepo = "$($Matches['owner'])/$($Matches['repo'])"
        SourceRoot      = $sourceRoot
        SourceUrl       = $originUrl                 # reused verbatim as the new repo's 'template' remote
        ParentDir       = Split-Path -Parent $sourceRoot
    }
}

function Use-ScaffoldGhAccount {
    <#
        Point every `gh` call in THIS PROCESS at $GhAccount, then verify it really has admin
        access - without changing which account is active on the machine.

        This borrows that account's stored token (`gh auth token --user`) into $env:GH_TOKEN,
        which takes precedence over the keyring for this process and its children. That matters
        when you keep a work account and a personal account logged in side by side: `gh auth
        switch` would silently repoint every other shell too, so scaffolding must not rely on
        whichever account happens to be active.

        Call Reset-ScaffoldGhAccount when finished to leave the machine exactly as found.
    #>
    param([string]$GhAccount, [Parameter(Mandatory)][string]$ProbeOwnerRepo)

    if ($GhAccount) {
        # Whatever is active now (probably a work account) must still be active when we finish.
        $previouslyActive = gh api user --jq .login 2>$null
        $global:LASTEXITCODE = 0

        $token = gh auth token --user $GhAccount 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $token) {
            $global:LASTEXITCODE = 0
            if ($script:SkipManualPrompts) {
                throw ("No stored credentials for gh account '$GhAccount', and prompts are " +
                    "suppressed. Run: gh auth login   (then re-run unattended.)")
            }
            # First run on a new machine: walk the user through login, then put things back.
            Write-Warn "No stored credentials for gh account '$GhAccount' - starting 'gh auth login'"
            Write-Detail "sign in as '$GhAccount'; your other accounts stay logged in"
            gh auth login --hostname github.com
            if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; throw "'gh auth login' did not complete." }
            $global:LASTEXITCODE = 0

            # gh makes a freshly logged-in account active; restore what was active before.
            if ($previouslyActive) {
                gh auth switch --user $previouslyActive 2>$null | Out-Null
                $global:LASTEXITCODE = 0
                Write-Ok "Restored '$previouslyActive' as the active gh account"
            }
            $token = gh auth token --user $GhAccount 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $token) {
                $global:LASTEXITCODE = 0
                throw "Still no credentials for '$GhAccount' - did you sign in as a different account?"
            }
            $global:LASTEXITCODE = 0
        }
        $env:GH_TOKEN = $token.Trim()
        Write-Ok "Using gh account '$GhAccount' for this run only (active account untouched)"
    }

    $active = (gh api user --jq .login 2>$null)
    if (-not $active) { $global:LASTEXITCODE = 0; throw "Not authenticated with gh. Run 'gh auth login' first." }
    $global:LASTEXITCODE = 0

    # Admin probe: being logged in is not the same as having the scopes/permissions we need.
    gh api "repos/$ProbeOwnerRepo/actions/permissions/workflow" --silent 2>$null | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0
    if (-not $ok) {
        throw ("Account '$active' lacks admin access to '$ProbeOwnerRepo'. Pass -GhAccount for the " +
            'owning account, or if it is a scope issue run: ' +
            'gh auth refresh -h github.com -s admin:repo_hook,workflow,security_events')
    }
    Write-Ok "Admin access confirmed (gh account: $active)"
}

function Reset-ScaffoldGhAccount {
    <# Drop the borrowed token so the shell goes back to its normal active account. #>
    if ($env:GH_TOKEN) {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        Write-Info 'Released the borrowed gh token'
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Step: create the repo (idempotent)
#───────────────────────────────────────────────────────────────────────────────

function New-ScaffoldRepo {
    <# Create an empty public repo. No-op if it already exists. #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    gh repo view $OwnerRepo --json name 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Skip "Repo $OwnerRepo already exists"; return }
    Invoke-ScaffoldGh -What "Creating $OwnerRepo" -Arguments @('repo', 'create', $OwnerRepo, '--public') | Out-Null
    Add-ScaffoldActivity
    Write-Ok "Created empty public repo $OwnerRepo"
}

#───────────────────────────────────────────────────────────────────────────────
# Step: repo settings (API-settable, all idempotent)
#───────────────────────────────────────────────────────────────────────────────

function Set-ScaffoldActionsPermissions {
    <# Allow GitHub Actions to create and approve PRs (preserves default perms). #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    # gh writes its ERROR body to STDOUT, so a failed GET still yields a valid object - just one
    # carrying message/status instead of the fields we want. Under Set-StrictMode -Version Latest
    # a direct property read on that object THROWS, so test for the property before reading it.
    $cur = gh api "repos/$OwnerRepo/actions/permissions/workflow" 2>$null | ConvertFrom-Json
    $global:LASTEXITCODE = 0
    $props = if ($cur) { @($cur.PSObject.Properties.Name) } else { @() }

    if ($props -contains 'can_approve_pull_request_reviews' -and $cur.can_approve_pull_request_reviews) {
        Write-Skip 'Actions create/approve PRs already enabled'; return
    }
    $perm = if ($props -contains 'default_workflow_permissions') { $cur.default_workflow_permissions } else { 'read' }
    Invoke-ScaffoldGh -What 'Allowing Actions to create and approve PRs' -Arguments @(
        'api', '--method', 'PUT', "repos/$OwnerRepo/actions/permissions/workflow",
        '-f', "default_workflow_permissions=$perm", '-F', 'can_approve_pull_request_reviews=true') | Out-Null
    Add-ScaffoldActivity
    Write-Ok "Actions: allowed to create and approve pull requests"
}

function Enable-ScaffoldPrivateVulnReporting {
    param([Parameter(Mandatory)][string]$OwnerRepo)
    $enabled = gh api "repos/$OwnerRepo/private-vulnerability-reporting" --jq '.enabled' 2>$null
    if ($LASTEXITCODE -eq 0 -and $enabled -eq 'true') {
        Write-Skip 'Private vulnerability reporting already enabled'; return
    }
    Invoke-ScaffoldGh -What 'Enabling private vulnerability reporting' -Arguments @(
        'api', '--method', 'PUT', "repos/$OwnerRepo/private-vulnerability-reporting", '--silent') | Out-Null
    Add-ScaffoldActivity
    Write-Ok "Enabled private vulnerability reporting"
}

function Set-ScaffoldCodecovSecret {
    <# Add the CODECOV_TOKEN repo secret. No-op if it already exists (won't overwrite). #>
    param([Parameter(Mandatory)][string]$OwnerRepo, [string]$Token)
    $secrets = gh secret list --repo $OwnerRepo 2>$null
    $global:LASTEXITCODE = 0   # listing may legitimately fail; don't leak it to a later Assert-LastExit
    $exists = @($secrets) -match '^CODECOV_TOKEN\b'
    if ($exists) { Write-Skip "CODECOV_TOKEN already set (change it with 'gh secret set')"; return }
    if (-not $Token) {
        Write-Warn "CODECOV_TOKEN not set and none provided - add later: gh secret set CODECOV_TOKEN --repo $OwnerRepo"
        return
    }
    Invoke-ScaffoldGh -What 'Setting the CODECOV_TOKEN secret' -Arguments @(
        'secret', 'set', 'CODECOV_TOKEN', '--repo', $OwnerRepo, '--body', $Token) | Out-Null
    Add-ScaffoldActivity
    Write-Ok "Added repo secret CODECOV_TOKEN"
}

function Set-ScaffoldTopics {
    <#
        Set the repo's topics directly, rather than waiting for the Settings app to do it from
        settings.yml.

        Observed on every derived repo: description lands but topics stay empty. The app's
        repository plugin does call `PUT /repos/{owner}/{repo}/topics` whenever its `topics`
        value is truthy, splitting the comma-separated string - so the config format is right
        and there is no documented precondition. The call simply doesn't take effect on a repo
        that has never had a topic. Setting them here makes it deterministic; settings.yml then
        keeps them in sync from that point on.

        Note there is no way to do this while creating the repo: POST /user/repos has no topics
        parameter, so it is necessarily a second call.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo, [string]$Topics)

    if (-not $Topics) { Write-Skip 'No topics given'; return }
    $names = @($Topics -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if (-not $names) { Write-Skip 'No topics given'; return }

    $current = gh api "repos/$OwnerRepo/topics" --jq '.names | join(",")' 2>$null
    $global:LASTEXITCODE = 0
    if ($current -and (($current -split ',' | Sort-Object) -join ',') -eq (($names | Sort-Object) -join ',')) {
        Write-Skip "Topics already set ($current)"
        return
    }

    # -f names[]=... repeats the field to build a JSON array.
    # NB not $args - that is a PowerShell automatic variable.
    $ghArgs = @('api', '--method', 'PUT', "repos/$OwnerRepo/topics")
    foreach ($n in $names) { $ghArgs += @('-f', "names[]=$n") }
    Invoke-ScaffoldGh -What 'Setting repo topics' -Arguments $ghArgs | Out-Null
    Add-ScaffoldActivity
    Write-Ok "Set topics: $($names -join ', ')"
}

function Enable-ScaffoldImmutableReleases {
    <#
        Enable immutable releases (locks release assets and their tags after publication).

        This one USED to be on the manual checklist because the repo PATCH endpoint has no
        field for it - but GitHub shipped dedicated endpoints
        (GET/PUT/DELETE /repos/{owner}/{repo}/immutable-releases), so it can be automated.

        The feature is still rolling out, so a failure is not fatal: we fall back to putting
        it on the end-of-run checklist for you to click.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)

    # GET returns 204 when enabled and 404 when not, so the exit code is the answer.
    gh api "repos/$OwnerRepo/immutable-releases" --silent 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $global:LASTEXITCODE = 0
        Write-Skip 'Immutable releases already enabled'
        return
    }
    $global:LASTEXITCODE = 0

    gh api --method PUT "repos/$OwnerRepo/immutable-releases" --silent 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $global:LASTEXITCODE = 0
        Add-ScaffoldActivity
        Write-Ok 'Enabled immutable releases'
        return
    }
    $global:LASTEXITCODE = 0
    Write-Warn "Couldn't enable immutable releases via the API (still in preview) - added to the checklist"
    Add-ScaffoldManualItem -Category 'GitHub settings — web UI only (no API)' `
        -Title 'Enable release immutability' `
        -Steps @("https://github.com/$OwnerRepo/settings  →  General  →  check 'Enable release immutability'")
}

function Enable-ScaffoldCodeql {
    <# Enable CodeQL default setup. Call AFTER the first push (needs code to detect languages). #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    $state = gh api "repos/$OwnerRepo/code-scanning/default-setup" --jq '.state' 2>$null
    if ($LASTEXITCODE -eq 0 -and $state -eq 'configured') {
        Write-Skip 'CodeQL default setup already configured'; return
    }
    gh api --method PUT "repos/$OwnerRepo/code-scanning/default-setup" -f 'state=configured' --silent 2>$null
    $enabled = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0   # this failure is tolerated; don't leak it to a later Assert-LastExit
    if ($enabled) {
        Add-ScaffoldActivity
        Write-Ok 'CodeQL default setup enabled'
    }
    else {
        Write-Warn 'CodeQL default setup not enabled automatically'
        Write-Detail "configure it at https://github.com/$OwnerRepo/settings/security_analysis"
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Step: clone & wire up remotes (resume-safe)
#───────────────────────────────────────────────────────────────────────────────

function Get-ScaffoldSiblingUrl {
    <#
        Build the git URL for a sibling repo by swapping the owner/repo path in the
        source URL - preserving host/protocol (incl. custom SSH aliases like
        git@github.com-personal:...) so the new repo's origin uses the same creds.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$RepoName
    )
    $old = "$($Context.SourceOwner)/$($Context.SourceRepo)"
    $new = "$($Context.SourceOwner)/$RepoName"
    $url = $Context.SourceUrl -replace [regex]::Escape($old), $new
    if ($url -eq $Context.SourceUrl) { throw "Could not derive sibling URL from '$($Context.SourceUrl)'." }
    return $url
}

function Get-ScaffoldTemplateChain {
    <#
        Walk the inheritance chain upward from $StartRepoPath by following each repo's
        'template' remote, and return the LOCAL paths of every layer, nearest-first:
            [ .template-nuget, .template-dotnet, .github ]

        Each ancestor is located by repo name as a sibling folder in $ParentDir. Walking
        stops when a repo has no 'template' remote (the base) or when the next ancestor
        isn't cloned locally. Cycles and runaway depth are guarded.
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
        if ($LASTEXITCODE -ne 0 -or -not $url) { break }              # base layer reached
        if ($url.Trim() -notmatch '[:/][^/]+/([^/]+?)(\.git)?$') { break }
        $ancestorPath = Join-Path $ParentDir $Matches[1]
        if (-not (Test-Path (Join-Path $ancestorPath '.git'))) {
            Write-Info "Ancestor '$($Matches[1])' isn't cloned locally - ending chain walk"
            break
        }
        $resolved = (Resolve-Path $ancestorPath).Path
        if (-not $seen.Add($resolved.ToLowerInvariant())) { break }    # cycle
        $chain.Add($resolved)
        $cur = $resolved
    }
    # Reaching the base layer means the last `git remote get-url template` failed by design.
    # Clear the leaked exit code so a later Assert-LastExit doesn't see a phantom failure.
    $global:LASTEXITCODE = 0
    return $chain.ToArray()
}

function Set-ScaffoldRemotesAndConfig {
    <#
        Idempotently ensure the 'template' remote, push default, commit template, and
        that 'main' exists & is checked out. Creates main from the template branch ONLY
        if it doesn't already exist - so resuming never resets existing history.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$TemplateUrl,
        [string]$TemplateBranch = 'main'
    )
    git -C $RepoPath config remote.pushdefault origin | Out-Null
    $remotes = git -C $RepoPath remote 2>$null
    if ($remotes -notcontains 'template') {
        Invoke-ScaffoldGit -What "Adding the 'template' remote" -RepoPath $RepoPath -Arguments @('remote', 'add', 'template', $TemplateUrl) | Out-Null
    }
    else {
        git -C $RepoPath remote set-url template $TemplateUrl | Out-Null
    }
    Invoke-ScaffoldGit -What 'Fetching the template remote' -RepoPath $RepoPath -Arguments @('fetch', 'template') | Out-Null
    git -C $RepoPath config commit.template .gitmessage | Out-Null

    git -C $RepoPath show-ref --verify --quiet refs/heads/main
    if ($LASTEXITCODE -ne 0) {
        Invoke-ScaffoldGit -What "Creating main from template/$TemplateBranch" `
            -RepoPath $RepoPath -Arguments @('checkout', '-B', 'main', "template/$TemplateBranch") | Out-Null
    }
    else {
        $branch = git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null
        if ($branch -ne 'main') {
            Invoke-ScaffoldGit -What 'Switching to main' -RepoPath $RepoPath -Arguments @('checkout', 'main') | Out-Null
        }
    }
}

function Initialize-ScaffoldClone {
    <# Clone the new repo next to the template (or reuse an existing local clone). #>
    param(
        [Parameter(Mandatory)][string]$OriginUrl,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$TemplateUrl,
        [string]$TemplateBranch = 'main'
    )
    if (Test-Path $TargetPath) {
        if (-not (Test-Path (Join-Path $TargetPath '.git'))) {
            throw "Path exists but is not a git repo: $TargetPath (remove it and retry)."
        }
        Write-Skip "Local clone already present - reusing without reset"
    }
    else {
        # git clone (not `gh repo clone`) keeps the source URL's host alias/creds.
        Invoke-ScaffoldGit -What "Cloning $OriginUrl" -Arguments @('clone', $OriginUrl, $TargetPath) | Out-Null
        Add-ScaffoldActivity
        Write-Ok "Cloned $OriginUrl"
        Write-Detail "-> $TargetPath"
    }
    Set-ScaffoldRemotesAndConfig -RepoPath $TargetPath -TemplateUrl $TemplateUrl -TemplateBranch $TemplateBranch
    Write-Ok "'template' remote -> $TemplateUrl; on branch main"
}

function Test-ScaffoldCommitExists {
    <#
        True if a commit whose message contains $Message was made BY THIS REPO -
        i.e. it exists in 'template/<branch>..HEAD', the commits unique to this repo.

        Scoping to that range is essential: a repo derived from a template that was
        itself scaffolded inherits the parent's 'chore: customize ...' commits through
        template/main. Searching the whole history would match those inherited commits
        and silently skip customizing the new repo. Only commits made after branching
        from the template count as "this repo has already done that step".

        Falls back to the full history if the template ref is missing (returns $false
        on error, so the step re-runs - its edits are individually idempotent).
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [string]$TemplateBranch = 'main'
    )
    git -C $RepoPath rev-parse --verify --quiet "template/$TemplateBranch" | Out-Null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $false }   # no template ref yet

    # Compare SUBJECTS exactly (case-sensitively) rather than grepping the whole message, so one
    # group's message can't satisfy another's gate when one is a prefix of the other.
    #
    # It does NOT make a reverted step re-run: a `git revert` leaves the ORIGINAL subject in the
    # range too, so the gate still reports "done". That is arguably the behaviour we want -
    # scaffolding should not fight a deliberate revert - but don't mistake it for protection.
    $subjects = git -C $RepoPath log --format='%s' "template/$TemplateBranch..HEAD" 2>$null
    return [bool](@($subjects) -ceq $Message)
}

#───────────────────────────────────────────────────────────────────────────────
# Step: customize files (each edit is idempotent on its own)
#───────────────────────────────────────────────────────────────────────────────

function Remove-ScaffoldTemplateOnlyFiles {
    <# Delete the files that live ONLY in the base .github repo (see $TemplateOnlyFiles). #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $gone = 0
    foreach ($entry in $script:TemplateOnlyFiles) {
        $f = Join-Path $RepoPath $entry.Path
        if (Test-Path $f) { Remove-Item $f; Write-Ok "Deleted $($entry.Path)"; $gone++ }
    }
    if ($gone -eq 0) { Write-Skip 'No template-only files left to delete' }
}

function Update-ScaffoldReferences {
    <# Replace references to the source template's owner/repo with the new repo's. #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$OldOwnerRepo,
        [Parameter(Mandatory)][string]$NewOwnerRepo
    )
    $targets = [System.Collections.Generic.List[string]]::new()
    'CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md' | ForEach-Object { $targets.Add($_) }
    $issueDir = Join-Path $RepoPath '.github/ISSUE_TEMPLATE'
    if (Test-Path $issueDir) {
        Get-ChildItem $issueDir -File | ForEach-Object { $targets.Add(".github/ISSUE_TEMPLATE/$($_.Name)") }
    }
    foreach ($rel in $targets) {
        $f = Join-Path $RepoPath $rel
        if (Test-Path $f) {
            $raw = Get-Content -Raw $f
            if ($raw.Contains($OldOwnerRepo)) {
                $raw.Replace($OldOwnerRepo, $NewOwnerRepo) | Set-Content -NoNewline $f
                Write-Ok "Updated references in $rel"
            }
        }
    }
}

function Update-ScaffoldReadme {
    <#
        De-link the README rows documenting the template-only files we just deleted, then
        garbage-collect the link definitions that leaves orphaned.

        DE-LINK, not delete: the table's column is literally "Exists only in .github repo",
        so the row is what documents that this file is deliberately absent here. Deleting the
        row would throw away the information the column exists to convey. So
        '📄[FUNDING.yml][fundingFile]' becomes '📄FUNDING.yml', keeping the row and its ✅ -
        which matches how these repos were maintained by hand.

        Idempotent: once de-linked there is nothing left to match.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$Labels = @($script:TemplateOnlyFiles.Label)
    )
    $f = Join-Path $RepoPath 'README.md'
    if (-not (Test-Path $f)) { Write-Skip 'README.md not found'; return }

    $raw = Get-Content -Raw $f
    $original = $raw

    # 1) '[Display Name][label]' -> 'Display Name', keeping the surrounding table row intact.
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
            if ($lines[$j] -match '^\[[^\]]+\]:\s') { continue }   # other definitions aren't usages
            if ($lines[$j].Contains($token)) { $used = $true; break }
        }
        if (-not $used) { $lines.RemoveAt($i) }
    }
    $raw = ($lines -join "`r`n")
    if (-not $raw.EndsWith("`r`n")) { $raw += "`r`n" }

    if ($raw -eq $original) { Write-Skip 'README.md already has no template-only links'; return }
    $raw | Set-Content -NoNewline -Encoding utf8 $f
    Write-Ok 'De-linked the template-only files in README.md'
}

function Set-ScaffoldTemplateSyncConfig {
    <#
        Point the Template Sync workflow at THIS repo's parent template and switch the
        nightly schedule on.

        Both edits live here because both are read-modify-write of the same file, and because
        doing only the cron (as this used to) leaves a real bug: the workflow's
        TEMPLATE_REPO_URL is inherited verbatim, so a level-2 repo keeps syncing from the
        GRANDparent and silently never receives its immediate parent's changes.

        -TemplateUrl is the source repo's git URL in any form; it is normalised to the https
        form the workflow expects (it runs with a GITHUB_TOKEN, not your SSH key).
        Idempotent: re-running finds nothing to change.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$TemplateOwnerRepo
    )
    $f = Join-Path $RepoPath '.github/workflows/template-sync.yml'
    if (-not (Test-Path $f)) { Write-Warn 'template-sync.yml not found'; return }

    $raw = Get-Content -Raw $f
    $original = $raw

    # Retarget the sync source to the immediate parent.
    # Match only non-newline characters: '.' matches CR, so '.*$' in multiline mode would eat
    # the CR and turn that line's CRLF into a lone LF. Likewise use [ \t] not \s for the
    # indent, since \s also matches newlines.
    $httpsUrl = "https://github.com/$TemplateOwnerRepo.git"
    $raw = $raw -replace '(?m)^([ \t]*TEMPLATE_REPO_URL:[ \t]*)[^\r\n]*', "`${1}$httpsUrl"

    # Uncomment the schedule block. Match the SHAPE of the lines, not a specific cron
    # expression: hard-coding '0 0 * * *' silently uncommented 'schedule:' while leaving the
    # cron line commented on a template whose cadence had been changed, producing a
    # 'schedule:' key with no entries - invalid workflow YAML that GitHub then refuses.
    # [^\r\n] rather than .* so the trailing CR survives (see the retarget above).
    # NB no '$' anchor: in multiline mode '$' matches before the LF, but CRLF puts a CR there
    # first, so an anchored pattern silently fails to match and only half the block gets
    # uncommented - which is just as invalid as not uncommenting it at all.
    $raw = $raw -replace '(?m)^([ \t]*)#[ \t]*(schedule:)', '$1$2'
    $raw = $raw -replace '(?m)^([ \t]*)#[ \t]*(- cron:[^\r\n]*)', '$1  $2'

    if ($raw -eq $original) { Write-Skip 'Template Sync already targets the parent and is scheduled'; return }
    $raw | Set-Content -NoNewline $f
    Write-Ok 'Configured Template Sync'
    Write-Detail "source   : $httpsUrl"
    # Report the cron the template actually declares rather than assuming a cadence.
    $cronLine = ([regex]::Match($raw, '(?m)^[ \t]*- cron:[ \t]*(.+?)[ \t]*\r?$')).Groups[1].Value
    Write-Detail "schedule : $(if ($cronLine) { $cronLine } else { '(no cron found)' })"
}

function Remove-ScaffoldScripts {
    <# Delete the scripts/ folder in a code repo (which aren't derived from). #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $dir = Join-Path $RepoPath 'scripts'
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force; Write-Ok "Removed scripts/ (code repo won't be derived from)" }
}

function Add-ScaffoldGitExclude {
    <#
        Add a pattern to .git/info/exclude - a per-clone ignore list that is never
        committed, so it can't leak into the template chain the way .gitignore would.
        Idempotent. Uses LF: this is a git-internal control file, and a stray CR would
        become part of the pattern.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Pattern
    )
    $excludeFile = Join-Path $RepoPath '.git/info/exclude'
    $infoDir = Split-Path -Parent $excludeFile
    if (-not (Test-Path $infoDir)) { New-Item -ItemType Directory -Force $infoDir | Out-Null }

    $lines = if (Test-Path $excludeFile) { @(Get-Content $excludeFile) } else { @() }
    if ($lines -contains $Pattern) { Write-Skip "'$Pattern' is already excluded locally"; return }

    $out = @($lines) + @($Pattern)
    [System.IO.File]::WriteAllText($excludeFile, (($out -join "`n") + "`n"))
    Write-Ok "Excluded '$Pattern' locally via .git/info/exclude (never committed)"
}

function Write-ScaffoldSettings {
    <#
        Write the minimal _extends settings.yml. Kind=Code also sets is_template: false.

        Idempotent: skipped only if the file already declares THIS repo's name - meaning
        we (or you) already wrote it, so post-scaffold edits are never clobbered.

        Testing for '_extends:' alone would be wrong: a repo derived from a template that
        was itself scaffolded inherits the PARENT's settings.yml (which has _extends and
        the parent's name/description/topics). That must be overwritten, not preserved.
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
    $lines = [System.Collections.Generic.List[string]]::new()
    @(
        "# Inherit everything from the immediate parent template, and override only what"
        "# differs. The Settings app resolves _extends RECURSIVELY, so this repo also picks"
        "# up every ancestor's settings through the chain (e.g. .template-dotnet -> .github)."
        "# Bare repo name = same owner."
        "_extends: $ExtendsRepo"
        ''
        'repository:'
        $sep
        '  # "About" section (on Home Page)'
        '  # https://github.com/repository-settings/app/blob/master/docs/plugins/repository.md'
        '  # https://docs.github.com/en/rest/repos/repos#update-a-repository'
        $sep
        ''
        '  # A short description of the repo'
        '  # MUST BE A SINGLE LINE'
        "  description: $Description"
        ''
        '  # A URL with more information about the repo'
    ) | ForEach-Object { $lines.Add($_) }
    if ($Homepage) { $lines.Add("  homepage: $Homepage") } else { $lines.Add('  # homepage: (none)') }
    @(
        ''
        '  # A comma-separated list of topics to set on the repo'
        '  # See https://github.com/topics'
        "  topics: $Topics"
        ''
        $sep
        '  # Settings -> General'
        '  # https://github.com/repository-settings/app/blob/master/docs/plugins/repository.md'
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
            '  # Template layers rebase-merge so their history stays linear and no merge commits'
            '  # propagate downstream. A code repo is derived FROM but never derived from, so it'
            '  # can merge normally: rewrite history within a PR, then merge it as-is.'
            '  allow_merge_commit: true'
            '  allow_squash_merge: false'
            '  allow_rebase_merge: false'
        ) | ForEach-Object { $lines.Add($_) }
    }
    ($lines -join "`r`n") + "`r`n" | Set-Content -NoNewline -Encoding utf8 $settingsPath
    Write-Ok "Wrote .github/settings.yml ($Kind)"
}

#───────────────────────────────────────────────────────────────────────────────
# Step: VS Code multi-root workspace
#───────────────────────────────────────────────────────────────────────────────

function Write-ScaffoldWorkspaceFile {
    <#
        Write a multi-root <repo>.code-workspace in the new repo's root, containing the
        new repo plus every template layer in its inheritance chain - so template tweaks
        can be made without leaving the window.

        Format notes (all verified against the VS Code workspace schema):
        * .code-workspace is JSONC - comments and trailing commas are allowed
          (the schema sets allowComments/allowTrailingCommas and VS Code uses a
          fault-tolerant parser), so the file can document itself.
        * 'path' resolves against the folder containing THIS file, so the new repo is "."
          and its siblings are "../<name>". Forward slashes only - never backslashes.
        * The primary repo is listed FIRST: deprecated rootPath, extensions that aren't
          multi-root aware, and settings migration all look at folders[0].
        * dotnet.defaultSolution must live in the workspace-level 'settings' block; it is
          a window-scoped setting and is IGNORED in a folder's .vscode/settings.json inside
          a multi-root workspace.

        Not overwritten if it already exists (unless -Force), so your edits survive.
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

    # ── folders: primary repo first, then each ancestor as a sibling relative path ──
    $folders = [System.Collections.Generic.List[string]]::new()
    $folders.Add("`t`t// The new repo. Listed first so it is folders[0] (the de facto primary).")
    $folders.Add("`t`t{ `"name`": `"$RepoName`", `"path`": `".`" },")
    if ($ChainPaths.Count -gt 0) {
        $folders.Add("`t`t// Template layers this repo inherits from, nearest parent first.")
        foreach ($p in $ChainPaths) {
            $name = Split-Path -Leaf $p
            $rel = [System.IO.Path]::GetRelativePath($repoFull, (Resolve-Path $p).Path) -replace '\\', '/'
            $folders.Add("`t`t{ `"name`": `"$name`", `"path`": `"$rel`" },")
        }
    }

    # ── dotnet.defaultSolution: pin the PRIMARY repo's solution ────────────────────
    # Without this, C# Dev Kit globs the whole workspace and would happily adopt a
    # template layer's placeholder solution (e.g. .template-nuget/Placeholder.sln), or
    # prompt on every open when several are found.
    $slns = @(
        Get-ChildItem -LiteralPath $repoFull -Include *.sln, *.slnx, *.slnf -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|\.git)[\\/]' } |
            Sort-Object FullName
    )
    $settings = [System.Collections.Generic.List[string]]::new()
    if ($slns.Count -gt 0) {
        $rel = ($slns[0].FullName.Substring($repoFull.Length).TrimStart('\', '/')) -replace '\\', '/'
        if ($slns.Count -gt 1) {
            $settings.Add("`t`t// $($slns.Count) solutions found; pinned the first. Change if that's the wrong one.")
        }
        $settings.Add("`t`t// Relative to folders[0] (this repo). Forward slashes required.")
        $settings.Add("`t`t`"dotnet.defaultSolution`": `"$rel`"")
    }
    else {
        $settings.Add("`t`t// No solution here yet. 'disable' stops C# Dev Kit from adopting a")
        $settings.Add("`t`t// TEMPLATE layer's solution and suppresses the 'open a solution' nag.")
        $settings.Add("`t`t// Replace with e.g. `"MyRepo.sln`" once you add one.")
        $settings.Add("`t`t`"dotnet.defaultSolution`": `"disable`"")
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    @(
        '{'
        "`t// Multi-root workspace for $RepoName and the template layers it derives from."
        "`t// Generated by the scaffolding scripts; local-only (see .git/info/exclude)."
        "`t// Safe to edit or delete - it is never regenerated over your changes."
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

    ($lines -join "`r`n") + "`r`n" | Set-Content -NoNewline -Encoding utf8 $wsPath
    Add-ScaffoldActivity
    Write-Ok "Wrote $RepoName.code-workspace ($(1 + $ChainPaths.Count) folders)"
    return $wsPath
}

function Start-ScaffoldVSCode {
    <#
        Open a path (folder or .code-workspace) in VS Code as a separate, detached process.

        Prefers Code.exe over the code.cmd shim: launching the .cmd through Start-Process
        flashes a console window, while the exe returns immediately and cleanly. Falls back
        to the shim, then to Insiders. Never throws - failing to open an editor should not
        fail a successful scaffold.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [switch]$NewWindow
    )
    $exe = $null

    # Derive Code.exe from the shim on PATH: <root>\bin\code.cmd -> <root>\Code.exe
    foreach ($cliName in 'code', 'code-insiders') {
        $cli = Get-Command $cliName -ErrorAction SilentlyContinue
        if (-not $cli) { continue }
        $shim = $cli.Source
        $candidate = Join-Path (Split-Path -Parent (Split-Path -Parent $shim)) `
        $(if ($cliName -eq 'code-insiders') { 'Code - Insiders.exe' } else { 'Code.exe' })
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
        Write-Warn "Couldn't launch VS Code ($($_.Exception.Message)) - open it yourself: $Target"
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Step: commit / push / workflows
#───────────────────────────────────────────────────────────────────────────────

function Invoke-ScaffoldGatedCommit {
    <#
        Run one logical group of related changes, then commit them as $Message - unless that
        commit is already in THIS repo's own history, in which case skip the whole group.

        $Message drives both the history check and the commit, so the gate and the commit can
        never disagree. That matters: the message text IS the idempotency key (the gate greps
        for it), so a reworded message silently makes an already-scaffolded repo look unscaffolded.

        -Body is a scriptblock defined in the calling script, so it still sees that script's
        variables ($targetPath, $ctx, ...) even though it is invoked from inside the module.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string[]]$Paths,
        [string]$TemplateBranch = 'main',
        [Parameter(Mandatory)][scriptblock]$Body
    )
    if (Test-ScaffoldCommitExists -RepoPath $RepoPath -Message $Message -TemplateBranch $TemplateBranch) {
        Write-Skip "'$Message' already in history"
        return
    }
    & $Body
    Invoke-ScaffoldCommit -RepoPath $RepoPath -Message $Message -Paths $Paths
}

function Invoke-ScaffoldLayerCommit {
    <#
        Run this layer's Template.psm1 entry point, then commit exactly what it changed.

        No-op when the layer has no Template.psm1 (e.g. the base .github repo).

        The layer declares nothing about which paths it touches - we diff `git status` around
        the call and stage precisely that set. That keeps the single-entry-point contract the
        layer wants while preserving the scoped-staging guarantee: an unrelated dirty file can
        never be swept into this commit, even on a resumed run.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][hashtable]$Context,
        [string]$TemplateBranch = 'main'
    )
    $layers = Import-ScaffoldLayerModule
    if (-not $layers) {
        Write-Skip 'No Helpers-*.psm1 layers in this chain - nothing template-specific to apply'
        return
    }
    $message = 'chore: apply template-specific customizations'
    if (Test-ScaffoldCommitExists -RepoPath $RepoPath -Message $message -TemplateBranch $TemplateBranch) {
        Write-Skip "'$message' already in history"
        return
    }

    $statusPaths = {
        # Second field onward of each porcelain line; handles 'R  old -> new' by taking the new side.
        @(git -C $RepoPath status --porcelain 2>$null) | ForEach-Object {
            $p = $_.Substring(3)
            if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }
            $p.Trim('"')
        }
    }
    $before = @(& $statusPaths)

    foreach ($layer in $layers) {
        Write-Info "$($layer.Name) -> $($layer.Entry.Name)"
        & $layer.Entry -Context $Context
    }

    $after = @(& $statusPaths)
    $touched = @($after | Where-Object { $_ -notin $before })
    if (-not $touched) { Write-Skip "Template.psm1 changed nothing for: $message"; return }

    Invoke-ScaffoldCommit -RepoPath $RepoPath -Message $message -Paths $touched
}

function Invoke-ScaffoldCommit {
    <#
        Stage the paths this group owns and commit, but only if something is actually staged.

        -Paths is a deliberate safety boundary. Staging everything ('git add -A') is unsafe on
        a re-run: if a group legitimately produces no diff (because the parent template
        already did that work), no commit is made, so its gate stays false and the group runs
        again on every future run - sweeping a developer's unrelated uncommitted work into a
        'chore:' commit. Scoping the pathspec makes an ungated no-diff group harmless.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [string[]]$Paths = @('.')
    )
    # 'git add -- <path>' is a hard error when the path is neither on disk nor tracked, so
    # drop those first (e.g. scripts/ in a template repo, which is untouched).
    $spec = @($Paths | Where-Object {
            if (Test-Path (Join-Path $RepoPath $_)) { return $true }
            git -C $RepoPath ls-files --error-unmatch -- $_ 2>&1 | Out-Null
            $tracked = ($LASTEXITCODE -eq 0)
            $global:LASTEXITCODE = 0
            return $tracked
        })
    if (-not $spec) { Write-Skip "Nothing to stage for: $Message"; return }

    Invoke-ScaffoldGit -What 'Staging changes' -RepoPath $RepoPath -Arguments (@('add', '-A', '--') + $spec) | Out-Null
    git -C $RepoPath diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        # Summarise what is going in BEFORE committing, so the log shows the grouping.
        $staged = @(git -C $RepoPath diff --cached --name-status 2>$null)
        Invoke-ScaffoldGit -What "Committing '$Message'" -RepoPath $RepoPath -Arguments @('commit', '-m', $Message) | Out-Null
        Add-ScaffoldActivity
        Write-Ok "Committed: $Message"
        foreach ($line in $staged) {
            $parts = $line -split "`t", 2
            if ($parts.Count -eq 2) { Write-Detail ("{0}  {1}" -f $parts[0].PadRight(2), $parts[1]) }
        }
    }
    else {
        Write-Skip "Nothing to commit for: $Message"
    }
}

function Push-ScaffoldRepo {
    <# Push main. Idempotent: 'Everything up-to-date' when nothing changed. #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $out = Invoke-ScaffoldGit -What 'Pushing main' -RepoPath $RepoPath -Arguments @('push', '-u', 'origin', 'main')
    if (($out | Out-String) -match 'Everything up-to-date') {
        Write-Skip 'main already up to date on the remote'
    }
    else {
        Write-Ok 'Pushed main'
        Write-Detail "the 'Settings' app applies settings.yml within a few minutes"
    }
}

function Start-ScaffoldTemplateSync {
    <# Dispatch the Template Sync workflow to verify it works & initialize its baseline. #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    & gh workflow run template-sync.yml --repo $OwnerRepo --ref main 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Add-ScaffoldActivity
        Write-Ok 'Dispatched Template Sync'
        Write-Detail "verify: gh run list --repo $OwnerRepo --workflow template-sync.yml"
        Write-Detail "expect no errors and NO pull request"
    }
    else {
        Write-Warn 'Could not dispatch Template Sync yet (the workflow may still be registering)'
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

    'Invoke-ScaffoldGit'
    'Invoke-ScaffoldGh'
    'Get-ScaffoldOwner'
    'Write-ScaffoldStep'
    'Write-ScaffoldField'
    'Show-ScaffoldSummary'
    'Show-ScaffoldFailure'
    'Format-ScaffoldSlug'
    'Confirm-ScaffoldProceed'
    'Invoke-ScaffoldGatedCommit'
    'Invoke-ScaffoldLayerCommit'
    'Get-ScaffoldLayerModule'
    'Import-ScaffoldLayerModule'
    'Remove-ScaffoldLayerModule'
    'Resolve-ScaffoldValue'
    'Set-ScaffoldSkipPrompts'
    'Get-ScaffoldActivity'
    'Add-ScaffoldManualItem'
    'Register-ScaffoldManualSettings'
    'Show-ScaffoldManualChecklist'
    'Get-ScaffoldContext'
    'Use-ScaffoldGhAccount'
    'Reset-ScaffoldGhAccount'
    'New-ScaffoldRepo'
    'Set-ScaffoldActionsPermissions'
    'Enable-ScaffoldPrivateVulnReporting'
    'Set-ScaffoldCodecovSecret'
    'Set-ScaffoldTopics'
    'Enable-ScaffoldImmutableReleases'
    'Enable-ScaffoldCodeql'
    'Get-ScaffoldSiblingUrl'
    'Get-ScaffoldTemplateChain'
    'Initialize-ScaffoldClone'
    'Test-ScaffoldCommitExists'
    'Remove-ScaffoldTemplateOnlyFiles'
    'Update-ScaffoldReferences'
    'Update-ScaffoldReadme'
    'Set-ScaffoldTemplateSyncConfig'
    'Remove-ScaffoldScripts'
    'Add-ScaffoldGitExclude'
    'Write-ScaffoldWorkspaceFile'
    'Start-ScaffoldVSCode'
    'Write-ScaffoldSettings'
    'Invoke-ScaffoldCommit'
    'Push-ScaffoldRepo'
    'Start-ScaffoldTemplateSync'
)
