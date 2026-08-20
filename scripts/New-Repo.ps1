#Requires -Version 7.0

<#
.SYNOPSIS
    Creates a new repo derived from THIS template repo -
    either another TEMPLATE layer or a plain CODE repo.

.DESCRIPTION
    Run this from inside the template repo you want to derive from.
    The source template is auto-detected from this repo's 'origin' remote;
    the new repo is created on GitHub and cloned next to this one,
    reusing the same 'origin' URL style.

    -Kind selects the only two behavioural differences:
      Template : keeps scripts/ (the child can spawn its own children);
                 is_template stays inherited.
      Code     : removes scripts/ (a code repo isn't derived from,
                 and outside contributors have no use for the personal
                 templating infrastructure) and sets is_template: false.

    Scaffolding produces a complete, known-good baseline and stops.
    Its work is grouped into cohesive commits, each with a single concern.
    It never pauses for you to add repo-specific customizations -
    those are normal commits you make afterwards, on a branch, as a PR
    (also required: once the Settings app applies the rulesets,
    direct pushes to main are rejected).

    Every value is an OPTIONAL parameter.
    Anything you omit is prompted for, with a sensible default where one exists.
    Supply all of them plus -SkipManualPrompts for a fully unattended run.

    Idempotent & resumable: re-running verifies what's already done
    and only fills gaps. It never overwrites post-scaffold changes.

.PARAMETER Kind
    'Template' for a new template layer, 'Code' for a leaf code repo.
    Default: Code.

.PARAMETER Name
    The new repo's name, in kebab-case.
    For -Kind Template the '.template-' prefix is optional:
    'dotnet' and '.template-dotnet' both produce '.template-dotnet'.

.PARAMETER Description
    settings.yml description (single line).

.PARAMETER Homepage
    settings.yml homepage URL. Empty = omit.

.PARAMETER Topics
    settings.yml topics (comma-separated).

.PARAMETER CodecovToken
    CODECOV_TOKEN secret value. Empty = skip.
    Prompted without echo when omitted.

.PARAMETER SkipManualPrompts
    Skip all interactive prompts and the confirmation gate (unattended runs).

.EXAMPLE
    ./scripts/New-Repo.ps1
    Fully interactive - prompts for everything, including -Kind.

.EXAMPLE
    ./scripts/New-Repo.ps1 -Kind Template -Name dotnet
    Creates .template-dotnet; prompts only for the rest.

.EXAMPLE
    ./scripts/New-Repo.ps1 `
        -Kind Code `
        -Name my-service `
        -Description 'My service' `
        -Homepage '' `
        -Topics 'dotnet, service' `
        -CodecovToken $env:CODECOV `
        -SkipManualPrompts
    Fully unattended.
#>
[CmdletBinding()]
param(
    [ValidateSet('Template', 'Code')][string]$Kind,
    [string]$Name,
    [string]$Description,
    [string]$Homepage,
    [string]$Topics,
    [string]$CodecovToken,
    [switch]$SkipManualPrompts
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Helpers.psm1') -Force
Set-SkipPrompts $SkipManualPrompts.IsPresent
$bound = $PSBoundParameters

# Show terminating errors as a readable banner, not a raw PowerShell dump,
# and release the borrowed gh token on the way out.
# The trap also fires on Ctrl-C, so the token never outlives the run.
trap {
    Remove-LayerModule
    Reset-GhAccount
    Show-Failure -ErrorRecord $_
    exit 1
}

#───────────────────────────────────────────────────────────────────────────────
# Step 0: context + inputs
#───────────────────────────────────────────────────────────────────────────────

Write-Step '0' 'Prerequisites & inputs'
$ctx = Get-TemplateContext -ScriptRoot $PSScriptRoot
$owner = Get-RepoOwner

$Kind = Resolve-Input -Name Kind -Bound $bound -Value $Kind `
    -Prompt 'Kind - Template (a new layer) or Code (a leaf repo)' `
    -Default 'Code'
if ($Kind -notin 'Template', 'Code') {
    throw "Kind must be 'Template' or 'Code', not '$Kind'."
}

$namePrompt = if ($Kind -eq 'Template') {
    "Template type (kebab-case, e.g. 'dotnet' -> '.template-dotnet')"
}
else {
    "New repo name (kebab-case, e.g. 'my-service')"
}
$Name = Resolve-Input -Name Name -Bound $bound `
    -Value $Name -Prompt $namePrompt

# Accept either 'dotnet' or '.template-dotnet' for a template layer.
$slug = if ($Kind -eq 'Template') {
    $Name -replace '^\.template-', ''
}
else { $Name }
$slug = Format-Slug -Value $slug -Label 'Name'
$repo = if ($Kind -eq 'Template') { ".template-$slug" } else { $slug }

$ownerRepo = "$owner/$repo"
$targetPath = Join-Path $ctx.ParentDir $repo

Write-Field 'Source template' $ctx.SourceOwnerRepo
Write-Field ''                $ctx.SourceRoot
Write-Field "New $($Kind.ToLowerInvariant()) repo" $ownerRepo
Write-Field 'Clone to'        $targetPath

Use-GhAccount -ProbeOwnerRepo $ctx.SourceOwnerRepo

$Description = Resolve-Input -Name Description -Bound $bound `
    -Value $Description -Prompt 'Repo description (single line)'
$Homepage = Resolve-Input -Name Homepage -Bound $bound `
    -Value $Homepage -Prompt 'Homepage URL (optional - blank to omit)'
$Topics = Resolve-Input -Name Topics -Bound $bound `
    -Value $Topics -Prompt 'Topics (comma-separated)'

if (-not $bound.ContainsKey('CodecovToken')) {
    Write-Field 'Codecov token at' `
        "https://app.codecov.io/account/gh/$owner/org-upload-token"
}
$CodecovToken = Resolve-Input -Name CodecovToken -Bound $bound `
    -Value $CodecovToken `
    -Prompt 'CODECOV_TOKEN value (blank to skip)' `
    -Secret

if (-not (Confirm-Proceed -OwnerRepo $ownerRepo)) { return }

#───────────────────────────────────────────────────────────────────────────────
# Step 1: create
#───────────────────────────────────────────────────────────────────────────────

Write-Step '1' 'Create the new repo'
New-GitHubRepo -OwnerRepo $ownerRepo

#───────────────────────────────────────────────────────────────────────────────
# Step 2: settings (API)
#───────────────────────────────────────────────────────────────────────────────

Write-Step '2' 'Configure repo settings (API)'
Set-ActionsPermissions      -OwnerRepo $ownerRepo
Enable-PrivateVulnReporting -OwnerRepo $ownerRepo
Enable-ImmutableReleases    -OwnerRepo $ownerRepo
Initialize-Topics           -OwnerRepo $ownerRepo
Set-CodecovSecret           -OwnerRepo $ownerRepo -Token $CodecovToken

#───────────────────────────────────────────────────────────────────────────────
# Step 3: clone + remotes
#───────────────────────────────────────────────────────────────────────────────

Write-Step '3' 'Clone the new repo'
# Preserves the origin URL style, including any custom SSH host alias.
$originUrl = Get-NewRepoUrl -Context $ctx -RepoName $repo
Initialize-Clone -OriginUrl $originUrl `
    -TargetPath $targetPath `
    -TemplateUrl $ctx.SourceUrl

#───────────────────────────────────────────────────────────────────────────────
# Step 4: drop what belongs only to the parent
#───────────────────────────────────────────────────────────────────────────────

# Deletions run BEFORE the README pass,
# so the README stops documenting files that have already gone,
# rather than the other way round.
Write-Step '4' 'Remove template-only files'
$paths = @('.github', 'README.md', 'scripts')
Invoke-GatedCommit -RepoPath $targetPath `
    -Message 'chore: remove template-only files' `
    -Paths $paths `
    -Body {
    Remove-TemplateOnlyFiles -RepoPath $targetPath
    if ($Kind -eq 'Code') { Remove-ScriptsFolder -RepoPath $targetPath }
    Update-Readme            -RepoPath $targetPath
}

#───────────────────────────────────────────────────────────────────────────────
# Step 5: point this repo's docs at itself
#───────────────────────────────────────────────────────────────────────────────

Write-Step '5' 'Retarget template references'
$paths = @(
    '.github/ISSUE_TEMPLATE'
    'CONTRIBUTING.md'
    'SECURITY.md'
    'SUPPORT.md'
)
Invoke-GatedCommit -RepoPath $targetPath `
    -Message 'chore: retarget template references' `
    -Paths $paths `
    -Body {
    Update-RepoReferences -RepoPath $targetPath `
        -OldOwnerRepo $ctx.SourceOwnerRepo `
        -NewOwnerRepo $ownerRepo
}

#───────────────────────────────────────────────────────────────────────────────
# Step 6: start syncing from the immediate parent
#───────────────────────────────────────────────────────────────────────────────

Write-Step '6' 'Enable Template Sync'
$paths = @('.github/workflows/template-sync.yml')
Invoke-GatedCommit -RepoPath $targetPath `
    -Message 'ci: enable the template sync schedule' `
    -Paths $paths `
    -Body {
    Set-TemplateSyncConfig -RepoPath $targetPath `
        -TemplateOwnerRepo $ctx.SourceOwnerRepo
}

#───────────────────────────────────────────────────────────────────────────────
# Step 7: whatever THIS template layer needs (optional Helpers-*.psm1)
#───────────────────────────────────────────────────────────────────────────────

Write-Step '7' 'Apply template-specific customizations'
Invoke-LayerModule -RepoPath $targetPath -Context @{
    RepoPath        = $targetPath
    RepoName        = $repo
    Kind            = $Kind
    OwnerRepo       = $ownerRepo
    SourceOwnerRepo = $ctx.SourceOwnerRepo
}

#───────────────────────────────────────────────────────────────────────────────
# Step 8: this repo's own settings
#───────────────────────────────────────────────────────────────────────────────

Write-Step '8' 'Customize repo settings'
$paths = @('.github/settings.yml')
Invoke-GatedCommit -RepoPath $targetPath `
    -Message 'chore: customize repo settings' `
    -Paths $paths `
    -Body {
    # _extends resolves recursively, so this inherits the whole chain.
    Write-SettingsFile -RepoPath $targetPath `
        -Kind $Kind `
        -Name $repo `
        -ExtendsRepo $ctx.SourceRepo `
        -Description $Description `
        -Homepage $Homepage `
        -Topics $Topics
}

#───────────────────────────────────────────────────────────────────────────────
# Step 9: push (triggers Settings app) + CodeQL
#───────────────────────────────────────────────────────────────────────────────

Write-Step '9' 'Push & enable CodeQL'
Push-Repo     -RepoPath $targetPath
Enable-Codeql -OwnerRepo $ownerRepo   # only now does the repo have content

#───────────────────────────────────────────────────────────────────────────────
# Step 10: initialize workflows, if anything changed
#───────────────────────────────────────────────────────────────────────────────

Write-Step '10' 'Initialize Template Sync'
if ((Get-ChangeCount) -gt 0) {
    Start-TemplateSync -OwnerRepo $ownerRepo
}
else {
    Write-Skip 'Nothing changed this run - Template Sync is already initialized'
}

#───────────────────────────────────────────────────────────────────────────────
# Step 11: VS Code multi-root workspace, then open it
#───────────────────────────────────────────────────────────────────────────────

Write-Step '11' 'Set up the VS Code workspace'
# Exclude BEFORE creating:
# if the run dies between the two,
# an unexcluded workspace file would be committed,
# and then synced to every descendant.
Add-GitExclude -RepoPath $targetPath -Pattern "$repo.code-workspace"

# The chain is the source template plus every ancestor cloned locally,
# nearest first.
$chain = Get-TemplateChain -StartRepoPath $ctx.SourceRoot `
    -ParentDir $ctx.ParentDir
$wsFile = Write-WorkspaceFile -RepoPath $targetPath `
    -RepoName $repo `
    -ChainPaths $chain
Start-VSCode -Target $wsFile

#───────────────────────────────────────────────────────────────────────────────
# Manual follow-up checklist
#───────────────────────────────────────────────────────────────────────────────

Remove-LayerModule
Reset-GhAccount
Register-ManualSettings -OwnerRepo $ownerRepo
Show-ManualChecklist    -OwnerRepo $ownerRepo
Show-Summary

if ((Get-ChangeCount) -eq 0) {
    Write-Host "  ✅ $ownerRepo was already fully scaffolded." `
        -ForegroundColor Green
}
else {
    $kindLabel = $Kind.ToLowerInvariant()
    Write-Host "  🎉 $kindLabel repo $ownerRepo ready at $targetPath." `
        -ForegroundColor Green
}
Write-Host ""
