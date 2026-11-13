<#
.SYNOPSIS
  Links a personal dotfiles repository into the user profile.

.DESCRIPTION
  Opt-in: the phase does nothing unless %USERPROFILE%\.dotfiles exists or the
  DEVCONFIG_DOTFILES_REPO user environment variable names a repository to clone there.

  The repository declares its links in devconfig.links.psd1, a data file read with
  Import-PowerShellDataFile, so setup never runs code from the repository:

    @{
        Links = @{
            '~\.gitconfig'                     = 'git\.gitconfig'
            '%APPDATA%\Code\User\settings.json' = 'vscode\settings.json'
        }
    }

  Keys are link paths and must resolve inside %USERPROFILE%; values are paths inside the
  repository. Anything already at a link path is moved to <path>.devconfig-backup first,
  and cleanup removes only links that point into the repository, restoring those backups.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigDotfilesRepoVariable = 'DEVCONFIG_DOTFILES_REPO'
$Script:DevConfigDotfilesLinksFile    = 'devconfig.links.psd1'
$Script:DevConfigDotfilesBackupSuffix = '.devconfig-backup'

function Get-DevConfigDotfilesHome {
    return [Environment]::GetFolderPath('UserProfile')
}

function Get-DevConfigDotfilesDirectory {
    param(
        [string] $HomeDirectory = (Get-DevConfigDotfilesHome)
    )
    return (Join-Path $HomeDirectory '.dotfiles')
}

# Elevation can start a fresh environment block, so the persisted user value is the fallback.
function Get-DevConfigDotfilesRepo {
    $repo = [Environment]::GetEnvironmentVariable($Script:DevConfigDotfilesRepoVariable, 'Process')
    if ([string]::IsNullOrWhiteSpace($repo)) {
        $repo = [Environment]::GetEnvironmentVariable($Script:DevConfigDotfilesRepoVariable, 'User')
    }
    if ([string]::IsNullOrWhiteSpace($repo)) {
        return $null
    }
    $repo = $repo.Trim()
    # Only remote URLs, so the value cannot become a git option or a local path to an unexpected tree.
    if ($repo -notmatch '^(https://[^\s]+|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^\s]+|ssh://[^\s]+)$') {
        throw "$Script:DevConfigDotfilesRepoVariable must be an https://, ssh://, or user@host:path git URL; got '$repo'."
    }
    return $repo
}

function Test-DevConfigDotfilesCloned {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )
    return (Test-Path -LiteralPath (Join-Path $Directory '.git'))
}

function Install-DevConfigDotfilesRepo {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Directory
    )
    if ((Test-Path -LiteralPath $Directory) -and @(Get-ChildItem -LiteralPath $Directory -Force).Count -gt 0) {
        throw "$Directory already exists and isn't empty, so it was left alone. Clone $Repo there yourself, then re-run."
    }
    Update-DevConfigSessionPath
    $git = Get-Command 'git.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) {
        throw 'git is not on PATH yet. Open a new terminal and re-run, or clone the repository yourself.'
    }
    # Clone as the signed-in user so the files belong to them, and never wait on a hidden credential prompt.
    $result = Invoke-DevConfigUnelevatedCommand -FilePath $git.Source -TimeoutSeconds 600 -Arguments @(
        '-c', 'credential.interactive=never', 'clone', '--', $Repo, $Directory
    )
    if ($result.ExitCode -ne 0) {
        throw "git clone failed ($($result.ExitCode)): $(([string]$result.Output).Trim()) For a private repository, clone it to $Directory yourself, then re-run."
    }
}

function Resolve-DevConfigDotfilesPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $HomeDirectory
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($Path) -replace '/', '\'
    if ($expanded -eq '~' -or $expanded.StartsWith('~\')) {
        $expanded = $HomeDirectory.TrimEnd('\') + $expanded.Substring(1)
    }
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $Root $expanded
    }
    return [IO.Path]::GetFullPath($expanded)
}

function Test-DevConfigDotfilesPathInside {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Root
    )
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $Path.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)
}

# Returns validated Path/Source pairs; any bad entry stops the phase before a single link changes.
function Get-DevConfigDotfilesLinks {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [string] $HomeDirectory = (Get-DevConfigDotfilesHome)
    )
    $manifestPath = Join-Path $Directory $Script:DevConfigDotfilesLinksFile
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return @()
    }
    $data = Import-PowerShellDataFile -LiteralPath $manifestPath
    if (-not $data.ContainsKey('Links') -or $data['Links'] -isnot [hashtable]) {
        throw "$Script:DevConfigDotfilesLinksFile must contain a Links hashtable of link path = repository path."
    }
    $unknown = @($data.Keys | Where-Object { $_ -ne 'Links' })
    if ($unknown.Count -gt 0) {
        throw "$Script:DevConfigDotfilesLinksFile has unknown keys: $($unknown -join ', ')."
    }

    $repoRoot = [IO.Path]::GetFullPath($Directory)
    $links = foreach ($key in @($data['Links'].Keys | Sort-Object)) {
        $value = $data['Links'][$key]
        if ($key -isnot [string] -or $value -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($value)) {
            throw "$Script:DevConfigDotfilesLinksFile entries must map a link path string to a repository path string."
        }
        $path = Resolve-DevConfigDotfilesPath -Path $key -Root $HomeDirectory -HomeDirectory $HomeDirectory
        $source = Resolve-DevConfigDotfilesPath -Path $value -Root $repoRoot -HomeDirectory $HomeDirectory
        if (-not (Test-DevConfigDotfilesPathInside -Path $path -Root $HomeDirectory)) {
            throw "Link '$key' resolves to $path, outside $HomeDirectory. Dotfile links must stay in your user profile."
        }
        if (Test-DevConfigDotfilesPathInside -Path $path -Root $repoRoot) {
            throw "Link '$key' resolves inside the dotfiles repository itself."
        }
        if (-not (Test-DevConfigDotfilesPathInside -Path $source -Root $repoRoot)) {
            throw "Source '$value' resolves to $source, outside the dotfiles repository."
        }
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Source '$value' does not exist in the dotfiles repository."
        }
        [pscustomobject]@{ Name = $key; Path = $path; Source = $source }
    }
    return @($links)
}

function Get-DevConfigDotfilesLinkTarget {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne 'SymbolicLink') {
        return $null
    }
    $target = @($item.Target)[0]
    if (-not $target) {
        return $null
    }
    if (-not [IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $Path) $target
    }
    return [IO.Path]::GetFullPath($target)
}

function Test-DevConfigDotfileLinked {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Source
    )
    $target = Get-DevConfigDotfilesLinkTarget -Path $Path
    return ($null -ne $target -and [string]::Equals($target, $Source, [StringComparison]::OrdinalIgnoreCase))
}

function Get-DevConfigDotfileBackupPath {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    $backup = $Path + $Script:DevConfigDotfilesBackupSuffix
    if (-not (Test-Path -LiteralPath $backup)) {
        return $backup
    }
    # Keep the first backup intact; later ones get a timestamp so nothing is overwritten.
    return "$backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
}

function Set-DevConfigDotfileLink {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Source
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path) {
        $backup = Get-DevConfigDotfileBackupPath -Path $Path
        Move-Item -LiteralPath $Path -Destination $backup
        Write-Host "    Moved the existing file to $backup" -ForegroundColor DarkGray
    } elseif (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) {
        # A dangling link does not pass Test-Path; replace it rather than back it up.
        Remove-Item -LiteralPath $Path -Force
    }
    New-Item -ItemType SymbolicLink -Path $Path -Target $Source | Out-Null
}

function Remove-DevConfigDotfileLink {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Source
    )
    if (-not (Test-DevConfigDotfileLinked -Path $Path -Source $Source)) {
        return
    }
    # Delete the link itself; Remove-Item on a directory link must not recurse into the repository.
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        [IO.Directory]::Delete($Path)
    } else {
        [IO.File]::Delete($Path)
    }
    $backup = $Path + $Script:DevConfigDotfilesBackupSuffix
    if (Test-Path -LiteralPath $backup) {
        Move-Item -LiteralPath $backup -Destination $Path
    }
}

function New-DevConfigDotfileLinkSteps {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Links,
        [switch] $Reset
    )
    foreach ($link in $Links) {
        if ($Reset) {
            New-DevConfigStep -Name "Unlink $($link.Name)" -Description "Remove the $($link.Name) link and restore any backup" -BestEffort `
                -Check { param($Path, $Source) -not (Test-DevConfigDotfileLinked -Path $Path -Source $Source) } `
                -Apply { param($Path, $Source) Remove-DevConfigDotfileLink -Path $Path -Source $Source } `
                -ArgumentList @($link.Path, $link.Source)
        } else {
            New-DevConfigStep -Name "Link $($link.Name)" -Description "Link $($link.Path) to $($link.Source)" -BestEffort `
                -Check { param($Path, $Source) Test-DevConfigDotfileLinked -Path $Path -Source $Source } `
                -Apply { param($Path, $Source) Set-DevConfigDotfileLink -Path $Path -Source $Source } `
                -ArgumentList @($link.Path, $link.Source)
        }
    }
}

function Write-DevConfigDotfilesSkip {
    param(
        [Parameter(Mandatory)] [string] $Message
    )
    if ($Script:DevConfigResumed) {
        return
    }
    Show-DevConfigPhaseHeader
    Write-Host "  $Message" -ForegroundColor DarkGray
}

# A bad repo URL or links file is the user's to fix; flag it instead of stopping the rest of setup.
function Invoke-DevConfigDotfilesRead {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock
    )
    try {
        return [pscustomobject]@{ Ok = $true; Value = @(& $ScriptBlock) }
    } catch {
        Show-DevConfigPhaseHeader
        Write-DevConfigStepFlag -Name $Name -Label $Name.PadRight(22) -Message "$($_.Exception.Message) (dotfiles left unchanged)"
        return [pscustomobject]@{ Ok = $false; Value = @() }
    }
}

function Invoke-DotfilesPhase {
    $directory = Get-DevConfigDotfilesDirectory

    if ($Script:DevConfigAction -eq 'Uninstall') {
        # The repository is the user's own data, so cleanup removes links but never the clone.
        if (-not (Test-Path -LiteralPath $directory)) {
            Write-DevConfigDotfilesSkip -Message "No $directory folder -- nothing to unlink."
            return
        }
        $read = Invoke-DevConfigDotfilesRead -Name 'DotfilesLinks' -ScriptBlock { @(Get-DevConfigDotfilesLinks -Directory $directory) }
        if (-not $read.Ok) { return }
        $links = @($read.Value | Where-Object { $_ })
        if ($links.Count -eq 0) {
            Write-DevConfigDotfilesSkip -Message "No $Script:DevConfigDotfilesLinksFile in $directory -- nothing to unlink."
            return
        }
        Invoke-DevConfigSteps -Steps @(New-DevConfigDotfileLinkSteps -Links $links -Reset)
        return
    }

    $read = Invoke-DevConfigDotfilesRead -Name 'DotfilesRepo' -ScriptBlock { Get-DevConfigDotfilesRepo }
    if (-not $read.Ok) { return }
    $repo = @($read.Value | Where-Object { $_ }) | Select-Object -First 1
    if (-not $repo -and -not (Test-Path -LiteralPath $directory)) {
        Write-DevConfigDotfilesSkip -Message "Skipped: set $Script:DevConfigDotfilesRepoVariable or clone your dotfiles to $directory to use this phase."
        return
    }

    if ($repo) {
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'DotfilesClone' -Description "Clone $repo to $directory" -BestEffort `
                -Check { param($Repo, $Directory) Test-DevConfigDotfilesCloned -Directory $Directory } `
                -Apply { param($Repo, $Directory) Install-DevConfigDotfilesRepo -Repo $Repo -Directory $Directory } `
                -ArgumentList @($repo, $directory)
        )
        if (-not (Test-Path -LiteralPath $directory)) {
            return
        }
    }

    $read = Invoke-DevConfigDotfilesRead -Name 'DotfilesLinks' -ScriptBlock { @(Get-DevConfigDotfilesLinks -Directory $directory) }
    if (-not $read.Ok) { return }
    $links = @($read.Value | Where-Object { $_ })
    if ($links.Count -eq 0) {
        Write-DevConfigDotfilesSkip -Message "No $Script:DevConfigDotfilesLinksFile in $directory -- nothing to link."
        return
    }
    Invoke-DevConfigSteps -Steps @(New-DevConfigDotfileLinkSteps -Links $links)
}
