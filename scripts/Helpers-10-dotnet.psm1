#Requires -Version 7.0
<#
    Helpers-10-dotnet.psm1

    The .NET layer's contribution to scaffolding, owned by .template-dotnet
    and inherited by every repo derived from it - directly, or through a
    deeper template such as .template-nuget.

    Two roles, per the Helpers-*.psm1 convention:
      1. HELPERS lower layers may reuse. They are exported, and layer modules
         are imported -Global, so .template-nuget's module can call them.
      2. ONE entry point matching Invoke-*Scaffold, which Helpers.psm1
         discovers and calls.

    This file is the ONLY thing this layer should need to edit. Helpers.psm1
    and New-Repo.ps1 are inherited verbatim and must stay byte-identical at
    every layer, or every future template merge conflicts on them.

    Anything Helpers.psm1 exports is available here - Write-Ok, Write-Detail,
    Write-Skip, Rename-Token, Invoke-GatedCommit,
    Resolve-Input, Invoke-Git - but its internals are not.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' does not
# reach these functions.
$ErrorActionPreference = 'Stop'

# The token this template's .NET payload uses for the project, assembly and
# namespace name. It appears in directory names, file names AND file content,
# which is why renaming it needs Rename-Token, not a find/replace.
$script:DotnetPlaceholder = 'Placeholder'

function ConvertTo-DotnetProjectName {
    <#
    .SYNOPSIS
        Turn a kebab-case repo name into the PascalCase name .NET wants.
    .DESCRIPTION
            my-service               -> MyService
            onion-seed.data          -> OnionSeed.Data
            onion-seed.helpers-async -> OnionSeed.HelpersAsync

        Dots are NAMESPACE SEPARATORS and survive; only '-' and '_' are word
        breaks. So each dot-delimited segment is PascalCased on its own and
        the dots are put back.

        Only used as the DEFAULT for the prompt - the answer is always the
        developer's.
    #>
    param([Parameter(Mandatory)][string]$RepoName)
    $segments = @($RepoName -split '\.' | Where-Object { $_ })
    $pascal = @($segments | ForEach-Object {
            $words = @($_ -split '[-_]+' | Where-Object { $_ })
            -join ($words | ForEach-Object {
                    $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1)
                })
        })
    return ($pascal -join '.')
}

function Get-DotnetPlaceholder {
    <#
    .SYNOPSIS
        The placeholder token this layer renames. Exposed for lower layers.
    #>
    return $script:DotnetPlaceholder
}

function Rename-DotnetProject {
    <#
    .SYNOPSIS
        Rename this template's placeholder project to $To, everywhere.
    .DESCRIPTION
        Exported so a lower layer can call it directly - e.g. .template-nuget
        may want to rename, then fix up its NuGet-specific files in the same
        pass.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$To
    )
    Rename-Token -RepoPath $RepoPath `
        -From $script:DotnetPlaceholder -To $To
}

function Invoke-DotnetScaffold {
    <#
    .SYNOPSIS
        This layer's entry point, found by the Invoke-*Scaffold pattern.
    .DESCRIPTION
        It owns its own commits: one concern per commit, each gated
        independently so a resumed run skips what is already done.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)

    # Additive: .github already registered 'actions', and a deeper layer can
    # add its own. Declared rather than left to GitHub's auto-detection, which
    # only sees what exists the moment default setup is switched on - so a
    # template enabled while still empty would never analyse its later C#.
    Add-CodeqlLanguage csharp

    $default = ConvertTo-DotnetProjectName -RepoName $Context.RepoName

    # -Bound @{} means "nothing was supplied on the command line", so this
    # prompts with the derived default - and returns that default untouched
    # during an unattended run.
    $projectName = Resolve-Input -Name DotnetProjectName `
        -Bound @{} -Value '' -Default $default `
        -Prompt 'Project / root-namespace name (PascalCase)'

    $namespaceRx = '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$'
    if ($projectName -notmatch $namespaceRx) {
        throw ("'$projectName' is not a valid .NET namespace: " +
            'use PascalCase, optionally dotted.')
    }

    Invoke-GatedCommit -RepoPath $Context.RepoPath `
        -Message 'chore: rename the placeholder project' -Body {
        Rename-DotnetProject -RepoPath $Context.RepoPath -To $projectName
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-DotnetProjectName'
    'Get-DotnetPlaceholder'
    'Rename-DotnetProject'
    'Invoke-DotnetScaffold'
)
