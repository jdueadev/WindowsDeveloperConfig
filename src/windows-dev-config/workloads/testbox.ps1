<#
.SYNOPSIS
  Testbox: a lean, headless subset of Windows Dev Config for test and throwaway machines.

.DESCRIPTION
  Workload definition read by dev-config.ps1. It keeps the parts of the full setup that
  tests and scripts depend on (Developer Mode, long paths, PowerShell 7, Git, GitHub CLI,
  uv, and WSL + Ubuntu) and drops the desktop polish: GUI apps, the large VS Code, .NET SDK,
  and PowerToys downloads, fonts, Terminal theming, Explorer, taskbar, and Edge tweaks, and
  Copilot. The phase files under steps\ do the work.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# WSL stays last so its required reboot happens after other phases.
@{
    Name      = 'Testbox'
    Actions   = @('Full')
    SetupNote = 'one reboot expected if WSL is not installed yet'
    Notes     = @(
        'Open a new terminal so pwsh, git, gh, and uv are on PATH.'
        'Need more? Add a toolchain workload, for example: irm https://aka.ms/devconfig/dotnet/setup.ps1 | iex'
    )
    Phases    = @(
        @{
            File     = 'prerequisites.ps1'
            Function = 'Invoke-PrerequisitesPhase'
            Title    = 'Getting ready'
        }
        @{
            File     = 'registry-system.ps1'
            Function = 'Invoke-RegistrySystemPhase'
            Title    = 'Developer Mode & long paths'
            Steps    = @('DeveloperMode', 'LongPaths')
        }
        @{
            File       = 'packages.ps1'
            Function   = 'Invoke-PackagesPhase'
            Title      = 'Packages'
            Parameters = @{ Packages = @('PowerShell', 'Git', 'GitHubCLI', 'UV') }
        }
        @{
            File     = 'wsl.ps1'
            Function = 'Invoke-WslPhase'
            Title    = 'WSL + Ubuntu'
        }
    )
}
