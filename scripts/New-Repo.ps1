#Requires -Version 7.0
<#
.SYNOPSIS
    Create a new repo derived from THIS template repo - either another TEMPLATE layer or a
    plain CODE repo.

.DESCRIPTION
    Run this from inside the template repo you want to derive from. The source template is
    auto-detected from this repo's 'origin' remote; the new repo is created on GitHub and
    cloned next to this one, reusing the same 'origin' URL style.

    -Kind selects the only two behavioural differences:
      Template : keeps scripts/ (the child can spawn its own children); is_template stays inherited.
      Code     : removes scripts/ (a code repo isn't derived from, and outside contributors
                 have no use for the personal templating infrastructure) and sets
                 is_template: false.

    Scaffolding produces a complete, known-good baseline and stops. Its work is grouped into
    four commits, each with a single concern. It never pauses for you to add repo-specific
    customizations - those are normal commits you make afterwards, on a branch, as a PR
    (also required: once the Settings app applies the rulesets, direct pushes to main are
    rejected).

    Every value is an OPTIONAL parameter. Anything you omit is prompted for, with a sensible
    default where one exists. Supply all of them plus -SkipManualPrompts for a fully
    unattended run.

    Idempotent & resumable: re-running verifies what's already done and only fills gaps. It
    never overwrites post-scaffold changes.

.PARAMETER Kind
    'Template' for a new template layer, 'Code' for a leaf code repo. Default: Code.

.PARAMETER Name
    The new repo's name, in kebab-case.
    For -Kind Template the '.template-' prefix is optional: 'dotnet' and '.template-dotnet'
    both produce '.template-dotnet'.

.PARAMETER GhAccount
    gh account that admins the owner. Switched to & verified first. Blank = use current.
.PARAMETER Description
    settings.yml description (single line).
.PARAMETER Homepage
    settings.yml homepage URL. Empty = omit.
.PARAMETER Topics
    settings.yml topics (comma-separated).
.PARAMETER CodecovToken
    CODECOV_TOKEN secret value. Empty = skip. Prompted without echo when omitted.
.PARAMETER TemplateBranch
    Branch on the template remote to base 'main' on. Default: main.
.PARAMETER SkipManualPrompts
    Skip all interactive prompts and the confirmation gate (unattended runs).

.EXAMPLE
    ./scripts/New-Repo.ps1
    Fully interactive - prompts for everything, including -Kind.

.EXAMPLE
    ./scripts/New-Repo.ps1 -Kind Template -Name dotnet
    Creates .template-dotnet; prompts only for the rest.

.EXAMPLE
    ./scripts/New-Repo.ps1 -Kind Code -Name my-service -GhAccount TaffarelJr `
        -Description 'My service' -Homepage '' -Topics 'dotnet, service' `
        -CodecovToken $env:CODECOV -SkipManualPrompts
    Fully unattended.
#>
[CmdletBinding()]
param(
    [ValidateSet('Template', 'Code')][string]$Kind,
    [string]$Name,
    [string]$GhAccount,
    [string]$Description,
    [string]$Homepage,
    [string]$Topics,
    [string]$CodecovToken,
    [string]$TemplateBranch = 'main',
    [switch]$SkipManualPrompts
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Helpers.psm1') -Force
Set-ScaffoldSkipPrompts $SkipManualPrompts.IsPresent
$bound = $PSBoundParameters

# Render any terminating error as a readable banner (which step, message, stack) instead of
# a raw PowerShell dump, then stop with a non-zero exit code.
trap { Remove-ScaffoldLayerModule; Reset-ScaffoldGhAccount; Show-ScaffoldFailure -ErrorRecord $_; exit 1 }

# ── Step 0: context + inputs ──────────────────────────────────────────────────
Write-ScaffoldStep '0' 'Prerequisites & inputs'
$ctx = Get-ScaffoldContext -ScriptRoot $PSScriptRoot
$owner = Get-ScaffoldOwner

$Kind = Resolve-ScaffoldValue -Name Kind -Bound $bound -Value $Kind `
    -Prompt 'Kind - Template (a new layer) or Code (a leaf repo)' -Default 'Code'
if ($Kind -notin 'Template', 'Code') { throw "Kind must be 'Template' or 'Code', not '$Kind'." }

$namePrompt = if ($Kind -eq 'Template') {
    "Template type (kebab-case, e.g. 'dotnet' -> '.template-dotnet')"
}
else {
    "New repo name (kebab-case, e.g. 'my-service')"
}
$Name = Resolve-ScaffoldValue -Name Name -Bound $bound -Value $Name -Prompt $namePrompt

# Accept either 'dotnet' or '.template-dotnet' for a template layer.
$slug = if ($Kind -eq 'Template') { $Name -replace '^\.template-', '' } else { $Name }
$slug = Format-ScaffoldSlug -Value $slug -Label 'Name'
$repo = if ($Kind -eq 'Template') { ".template-$slug" } else { $slug }

$ownerRepo = "$owner/$repo"
$targetPath = Join-Path $ctx.ParentDir $repo

Write-ScaffoldField 'Source template' $ctx.SourceOwnerRepo
Write-ScaffoldField ''                $ctx.SourceRoot
Write-ScaffoldField "New $($Kind.ToLowerInvariant()) repo" $ownerRepo
Write-ScaffoldField 'Clone to'        $targetPath

$GhAccount = Resolve-ScaffoldValue -Name GhAccount -Bound $bound -Value $GhAccount -Prompt "gh account that admins '$owner'" -Default $owner
Use-ScaffoldGhAccount -GhAccount $GhAccount -ProbeOwnerRepo $ctx.SourceOwnerRepo

$Description = Resolve-ScaffoldValue -Name Description -Bound $bound -Value $Description -Prompt 'Repo description (single line)'
$Homepage = Resolve-ScaffoldValue -Name Homepage    -Bound $bound -Value $Homepage    -Prompt 'Homepage URL (optional - blank to omit)'
$Topics = Resolve-ScaffoldValue -Name Topics      -Bound $bound -Value $Topics      -Prompt 'Topics (comma-separated)'

if (-not $bound.ContainsKey('CodecovToken')) {
    Write-ScaffoldField 'Codecov token at' "https://app.codecov.io/account/gh/$owner/org-upload-token"
}
$CodecovToken = Resolve-ScaffoldValue -Name CodecovToken -Bound $bound -Value $CodecovToken -Prompt 'CODECOV_TOKEN value (blank to skip)' -Secret

if (-not (Confirm-ScaffoldProceed -OwnerRepo $ownerRepo)) { return }

# ── Step 1: create ────────────────────────────────────────────────────────────
Write-ScaffoldStep '1' 'Create the new repo'
New-ScaffoldRepo -OwnerRepo $ownerRepo

# ── Step 2: settings (API) ────────────────────────────────────────────────────
Write-ScaffoldStep '2' 'Configure repo settings (API)'
Set-ScaffoldActionsPermissions      -OwnerRepo $ownerRepo
Enable-ScaffoldPrivateVulnReporting -OwnerRepo $ownerRepo
Enable-ScaffoldImmutableReleases    -OwnerRepo $ownerRepo
Set-ScaffoldTopics                  -OwnerRepo $ownerRepo -Topics $Topics
Set-ScaffoldCodecovSecret           -OwnerRepo $ownerRepo -Token $CodecovToken

# ── Step 3: clone + remotes ───────────────────────────────────────────────────
Write-ScaffoldStep '3' 'Clone the new repo'
$originUrl = Get-ScaffoldSiblingUrl -Context $ctx -RepoName $repo   # preserves origin style
Initialize-ScaffoldClone -OriginUrl $originUrl -TargetPath $targetPath -TemplateUrl $ctx.SourceUrl -TemplateBranch $TemplateBranch

# ── Step 4: drop what belongs only to the parent ──────────────────────────────
# Deletions run BEFORE the README pass, so the README stops documenting files that
# have already gone rather than the other way round.
Write-ScaffoldStep '4' 'Remove template-only files'
Invoke-ScaffoldGatedCommit -RepoPath $targetPath -TemplateBranch $TemplateBranch `
    -Message 'chore: remove template-only files' -Paths @('.github', 'README.md', 'scripts') -Body {
    Remove-ScaffoldTemplateOnlyFiles -RepoPath $targetPath
    if ($Kind -eq 'Code') { Remove-ScaffoldScripts -RepoPath $targetPath }
    Update-ScaffoldReadme            -RepoPath $targetPath
}

# ── Step 5: point this repo's docs at itself ──────────────────────────────────
Write-ScaffoldStep '5' 'Retarget template references'
Invoke-ScaffoldGatedCommit -RepoPath $targetPath -TemplateBranch $TemplateBranch `
    -Message 'chore: retarget template references' `
    -Paths @('.github/ISSUE_TEMPLATE', 'CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md') -Body {
    Update-ScaffoldReferences -RepoPath $targetPath -OldOwnerRepo $ctx.SourceOwnerRepo -NewOwnerRepo $ownerRepo
}

# ── Step 6: start syncing from the immediate parent ───────────────────────────
Write-ScaffoldStep '6' 'Enable Template Sync'
Invoke-ScaffoldGatedCommit -RepoPath $targetPath -TemplateBranch $TemplateBranch `
    -Message 'ci: enable the template sync schedule' `
    -Paths @('.github/workflows/template-sync.yml') -Body {
    Set-ScaffoldTemplateSyncConfig -RepoPath $targetPath -TemplateOwnerRepo $ctx.SourceOwnerRepo
}

# ── Step 7: whatever THIS template layer needs (optional Template.psm1) ───────
Write-ScaffoldStep '7' 'Apply template-specific customizations'
Invoke-ScaffoldLayerCommit -RepoPath $targetPath -TemplateBranch $TemplateBranch -Context @{
    RepoPath        = $targetPath
    RepoName        = $repo
    Kind            = $Kind
    OwnerRepo       = $ownerRepo
    SourceOwnerRepo = $ctx.SourceOwnerRepo
}

# ── Step 8: this repo's own settings ──────────────────────────────────────────
Write-ScaffoldStep '8' 'Customize repo settings'
Invoke-ScaffoldGatedCommit -RepoPath $targetPath -TemplateBranch $TemplateBranch `
    -Message 'chore: customize repo settings' -Paths @('.github/settings.yml') -Body {
    # Inherit from the repo we derived from (_extends resolves recursively up the chain).
    Write-ScaffoldSettings -RepoPath $targetPath -Kind $Kind -Name $repo `
        -ExtendsRepo $ctx.SourceRepo `
        -Description $Description -Homepage $Homepage -Topics $Topics
}

# ── Step 9: push (triggers Settings app) + CodeQL ─────────────────────────────
Write-ScaffoldStep '9' 'Push & enable CodeQL'
Push-ScaffoldRepo     -RepoPath $targetPath
Enable-ScaffoldCodeql -OwnerRepo $ownerRepo   # now that code/workflows exist

# ── Step 10: initialize workflows (only if something changed this run) ─────────
Write-ScaffoldStep '10' 'Initialize Template Sync'
if ((Get-ScaffoldActivity) -gt 0) {
    Start-ScaffoldTemplateSync -OwnerRepo $ownerRepo
}
else {
    Write-Skip 'Nothing changed this run - Template Sync is already initialized'
}

# ── Step 11: VS Code multi-root workspace, then open it ───────────────────────
Write-ScaffoldStep '11' 'Set up the VS Code workspace'
# Exclude BEFORE creating: if the run dies between the two, an unexcluded workspace file
# would be swept into a later scaffold commit and then sync into every descendant.
Add-ScaffoldGitExclude -RepoPath $targetPath -Pattern "$repo.code-workspace"
# Chain = the source template plus every ancestor cloned locally, nearest first.
$chain = Get-ScaffoldTemplateChain -StartRepoPath $ctx.SourceRoot -ParentDir $ctx.ParentDir
$wsFile = Write-ScaffoldWorkspaceFile -RepoPath $targetPath -RepoName $repo -ChainPaths $chain
Start-ScaffoldVSCode   -Target $wsFile

# ── Manual follow-up checklist ────────────────────────────────────────────────
Remove-ScaffoldLayerModule
Reset-ScaffoldGhAccount
Register-ScaffoldManualSettings -OwnerRepo $ownerRepo
Show-ScaffoldManualChecklist    -OwnerRepo $ownerRepo
Show-ScaffoldSummary

if ((Get-ScaffoldActivity) -eq 0) {
    Write-Host "  ✅ $ownerRepo was already fully scaffolded - nothing to change." -ForegroundColor Green
}
else {
    Write-Host "  🎉 $($Kind.ToLowerInvariant()) repo $ownerRepo ready at $targetPath." -ForegroundColor Green
}
Write-Host ""
