#Requires -Version 7.0
<#
    Scaffold-10-dotnet.psm1

    The .NET layer's contribution to scaffolding, owned by .template-dotnet and inherited by
    every repo derived from it (directly or through a deeper template such as .template-nuget).

    Two roles, per the Scaffold-*.psm1 convention:
      1. HELPERS that lower layers may reuse (they are exported, and layer modules are imported
         -Global, so .template-nuget's module can call them directly).
      2. ONE entry point matching Invoke-*Scaffold, which Scaffold.psm1 discovers and calls.

    This file is the ONLY thing this layer should need to edit. Scaffold.psm1 and New-Repo.ps1
    are inherited verbatim and must stay byte-identical at every layer, or every future template
    merge conflicts on them.

    Anything Scaffold.psm1 EXPORTS is available here - Write-Ok, Write-Detail, Write-Skip,
    Rename-ScaffoldToken, Invoke-ScaffoldGatedCommit, Resolve-ScaffoldValue, Invoke-ScaffoldGit -
    but its private internals are not.
#>

Set-StrictMode -Version Latest

# The token used throughout this template's .NET payload for the project/assembly/namespace
# name. It appears in directory names, file names AND file content, which is precisely why
# renaming it needs Rename-ScaffoldToken rather than a find/replace.
$script:DotnetPlaceholder = 'Placeholder'

# Paths the .NET payload occupies. Used as the commit pathspec so the rename commit can never
# pick up unrelated uncommitted work. EXTEND THIS as the template grows: anything not listed
# here will be renamed on disk but left out of the commit.
$script:DotnetPaths = @(
    'src'
    'test'
    '*.sln'
    '*.slnx'
    'Directory.Build.props'
    'Directory.Packages.props'
    'Common.props'
    'GitVersion.yml'
    'global.json'
    'nuget.config'
    'StyleCop.json'
    '.editorconfig'
)

function ConvertTo-DotnetProjectName {
    <#
        Turn a kebab-case repo name into the PascalCase name .NET wants:
            my-service      -> MyService
            onion-seed.data -> OnionSeedData

        Only used as the DEFAULT for the prompt - the answer is always the developer's.
    #>
    param([Parameter(Mandatory)][string]$RepoName)
    $parts = @($RepoName -split '[-_.]+' | Where-Object { $_ })
    return -join ($parts | ForEach-Object {
            $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1)
        })
}

function Get-DotnetPlaceholder {
    <# The placeholder token this layer renames. Exposed so lower layers can reuse it. #>
    return $script:DotnetPlaceholder
}

function Rename-DotnetProject {
    <#
        Rename this template's placeholder project to $To, everywhere it appears.

        Exported so a lower layer can call it directly - e.g. .template-nuget may want to rename
        and then immediately fix up its own NuGet-specific files in the same pass.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$To
    )
    Rename-ScaffoldToken -RepoPath $RepoPath -From $script:DotnetPlaceholder -To $To
}

function Invoke-DotnetScaffold {
    <#
        This layer's entry point. Scaffold.psm1 finds it by the Invoke-*Scaffold pattern and
        calls it with the scaffolding context.

        It owns its own commits: one concern, one commit, each independently gated so a resumed
        run skips what is already done.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)

    $default = ConvertTo-DotnetProjectName -RepoName $Context.RepoName

    # -Bound @{} means "nothing was supplied on the command line", so this prompts with the
    # derived default - and returns the default untouched during an unattended run.
    $projectName = Resolve-ScaffoldValue -Name DotnetProjectName -Bound @{} -Value '' `
        -Prompt 'Project / root-namespace name (PascalCase)' -Default $default

    if ($projectName -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$') {
        throw "'$projectName' is not a valid .NET namespace: use PascalCase, optionally dotted."
    }

    Invoke-ScaffoldGatedCommit -RepoPath $Context.RepoPath -TemplateBranch $Context.TemplateBranch `
        -Message 'chore: rename the placeholder project' -Paths $script:DotnetPaths -Body {
        Rename-DotnetProject -RepoPath $Context.RepoPath -To $projectName
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-DotnetProjectName'
    'Get-DotnetPlaceholder'
    'Rename-DotnetProject'
    'Invoke-DotnetScaffold'
)
