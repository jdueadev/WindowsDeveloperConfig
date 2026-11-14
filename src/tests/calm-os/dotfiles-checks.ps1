[CmdletBinding()]
param(
    # Scratch space for the fake home folder; removed afterwards.
    [string] $Root = [IO.Path]::GetTempPath()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stepsDir = Join-Path $PSScriptRoot '..\..\windows-dev-config\steps'
foreach ($helper in @('_console', '_step-runner', '_environment', '_elevation', 'dotfiles')) {
    . (Join-Path $stepsDir "$helper.ps1")
}
$checks = 0

function Assert-Dotfiles {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Assert-DotfilesThrows {
    param([scriptblock] $ScriptBlock, [string] $Like, [string] $Message)
    try {
        & $ScriptBlock
    } catch {
        Assert-Dotfiles ($_.Exception.Message -like $Like) "$Message (got: $($_.Exception.Message))"
        return
    }
    throw "$Message (no error was raised)"
}

function Write-LinksFile {
    param([string] $Directory, [string] $Body)
    Set-Content -LiteralPath (Join-Path $Directory 'devconfig.links.psd1') -Value $Body -Encoding UTF8
}

$sandbox = Join-Path $Root "devconfig-dotfiles-$([guid]::NewGuid().ToString('N'))"
$fakeHome = Join-Path $sandbox 'home'
$repo = Join-Path $fakeHome '.dotfiles'
$savedRepoVariable = [Environment]::GetEnvironmentVariable('DEVCONFIG_DOTFILES_REPO', 'Process')
New-Item -ItemType Directory -Path (Join-Path $repo 'git'), (Join-Path $repo 'nvim') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $repo 'git\.gitconfig') -Value '[user]' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $repo 'nvim\init.lua') -Value '-- init' -Encoding UTF8

# The phase reads the real profile folder; point it at the sandbox for this process only.
function Get-DevConfigDotfilesHome { return $fakeHome }

try {
    # Repository URLs: remote forms only, never something git could read as an option or local path.
    [Environment]::SetEnvironmentVariable('DEVCONFIG_DOTFILES_REPO', 'https://github.com/example/dotfiles.git', 'Process')
    Assert-Dotfiles ((Get-DevConfigDotfilesRepo) -eq 'https://github.com/example/dotfiles.git') 'https URLs should be accepted.'
    [Environment]::SetEnvironmentVariable('DEVCONFIG_DOTFILES_REPO', 'git@github.com:example/dotfiles.git', 'Process')
    Assert-Dotfiles ((Get-DevConfigDotfilesRepo) -eq 'git@github.com:example/dotfiles.git') 'scp-style SSH URLs should be accepted.'
    foreach ($bad in @('--upload-pack=calc.exe', 'C:\src\dotfiles', '\\server\share\dotfiles', 'file:///C:/dotfiles', 'http://example.com/d.git')) {
        [Environment]::SetEnvironmentVariable('DEVCONFIG_DOTFILES_REPO', $bad, 'Process')
        Assert-DotfilesThrows { Get-DevConfigDotfilesRepo } '*must be an https://*' "'$bad' should be rejected as a dotfiles repository."
    }
    [Environment]::SetEnvironmentVariable('DEVCONFIG_DOTFILES_REPO', $null, 'Process')

    # Links file validation: every entry is checked before anything changes.
    Assert-Dotfiles (@(Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome).Count -eq 0) 'A repository without a links file should have no links.'
    Write-LinksFile $repo "@{ Links = @{ '~\..\outside.txt' = 'git\.gitconfig' } }"
    Assert-DotfilesThrows { Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome } '*outside*user profile*' 'Links must not escape the user profile.'
    Write-LinksFile $repo "@{ Links = @{ 'C:\Windows\System32\evil.dll' = 'git\.gitconfig' } }"
    Assert-DotfilesThrows { Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome } '*outside*user profile*' 'Absolute links outside the profile must be rejected.'
    Write-LinksFile $repo "@{ Links = @{ '~\.gitconfig' = '..\..\secret.txt' } }"
    Assert-DotfilesThrows { Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome } '*outside the dotfiles repository*' 'Sources must stay inside the repository.'
    Write-LinksFile $repo "@{ Links = @{ '~\.gitconfig' = 'git\missing' } }"
    Assert-DotfilesThrows { Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome } '*does not exist*' 'Missing sources must be rejected.'
    Write-LinksFile $repo "@{ Links = @{ '~\.dotfiles\loop' = 'git\.gitconfig' } }"
    Assert-DotfilesThrows { Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome } '*inside the dotfiles repository itself*' 'Links must not point back into the repository.'
    # A link inside another link's path would be created through the outer link, inside the repository.
    Write-LinksFile $repo "@{ Links = @{ '~\a' = 'nvim'; '~\a\x' = 'git\.gitconfig' } }"
    Assert-DotfilesThrows { Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome } '*lies inside link*' 'Links nested under another link must be rejected.'
    Write-LinksFile $repo "@{ Links = @{ '~\.gitconfig' = 'git\.gitconfig'; '~/.gitconfig' = 'nvim\init.lua' } }"
    Assert-DotfilesThrows { Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome } '*same path*' 'Two keys resolving to one link path must be rejected.'
    Write-LinksFile $repo "@{ Links = @{ '~\a' = 'nvim'; '~\ab' = 'git\.gitconfig' } }"
    Assert-Dotfiles (@(Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome).Count -eq 2) 'A sibling sharing a name prefix is not nested.'
    Write-LinksFile $repo "@{ Links = @{}; Run = 'calc.exe' }"
    Assert-DotfilesThrows { Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome } '*unknown keys*' 'Unknown keys must be rejected.'
    Write-LinksFile $repo "@{ Links = @{ '~\.gitconfig' = (Get-Process) } }"
    Assert-DotfilesThrows { Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome } '*' 'Links files must be data only.'

    Write-LinksFile $repo "@{ Links = @{ '~\.gitconfig' = 'git\.gitconfig'; '~/AppData/Local/nvim' = 'nvim' } }"
    $links = @(Get-DevConfigDotfilesLinks -Directory $repo -HomeDirectory $fakeHome)
    Assert-Dotfiles ($links.Count -eq 2) 'Both declared links should be returned.'
    $fileLink = $links | Where-Object { $_.Name -eq '~\.gitconfig' }
    $dirLink = $links | Where-Object { $_.Name -eq '~/AppData/Local/nvim' }
    Assert-Dotfiles ($fileLink.Path -eq (Join-Path $fakeHome '.gitconfig')) "~ should resolve to the home folder (got $($fileLink.Path))."
    Assert-Dotfiles ($dirLink.Path -eq (Join-Path $fakeHome 'AppData\Local\nvim')) "Forward slashes should be accepted (got $($dirLink.Path))."

    # Symbolic links need Developer Mode or elevation; skip the link checks rather than fail without them.
    $probe = Join-Path $sandbox 'probe-link'
    $canLink = $true
    try { New-Item -ItemType SymbolicLink -Path $probe -Target (Join-Path $repo 'git\.gitconfig') -ErrorAction Stop | Out-Null } catch { $canLink = $false }
    if (-not $canLink) {
        Write-Output 'DOTFILES_LINK_CHECKS_SKIPPED: this session cannot create symbolic links (enable Developer Mode or run elevated).'
    } else {
        Set-Content -LiteralPath $fileLink.Path -Value 'original' -Encoding UTF8
        Assert-Dotfiles (-not (Test-DevConfigDotfileLinked -Path $fileLink.Path -Source $fileLink.Source)) 'A plain file is not a link.'
        Set-DevConfigDotfileLink -Path $fileLink.Path -Source $fileLink.Source
        Assert-Dotfiles (Test-DevConfigDotfileLinked -Path $fileLink.Path -Source $fileLink.Source) 'The file link should verify.'
        Assert-Dotfiles ((Get-Content -LiteralPath "$($fileLink.Path).devconfig-backup" -Raw).Trim() -eq 'original') 'The original file should be backed up.'

        Set-DevConfigDotfileLink -Path $dirLink.Path -Source $dirLink.Source
        Assert-Dotfiles (Test-DevConfigDotfileLinked -Path $dirLink.Path -Source $dirLink.Source) 'Missing parent folders should be created and the folder link should verify.'

        # Cleanup removes only the links, restores the backup, and never touches the repository.
        Remove-DevConfigDotfileLink -Path $fileLink.Path -Source $fileLink.Source
        Remove-DevConfigDotfileLink -Path $dirLink.Path -Source $dirLink.Source
        Assert-Dotfiles ((Get-Content -LiteralPath $fileLink.Path -Raw).Trim() -eq 'original') 'Cleanup should restore the backed-up file.'
        Assert-Dotfiles (-not (Test-Path -LiteralPath "$($fileLink.Path).devconfig-backup")) 'Cleanup should consume the backup.'
        Assert-Dotfiles (-not (Test-Path -LiteralPath $dirLink.Path)) 'Cleanup should remove the folder link.'
        Assert-Dotfiles (Test-Path -LiteralPath (Join-Path $repo 'nvim\init.lua')) 'Cleanup must not delete repository files through a folder link.'

        # A link the user pointed somewhere else is theirs; cleanup leaves it alone.
        $other = Join-Path $sandbox 'other.txt'
        Set-Content -LiteralPath $other -Value 'other' -Encoding UTF8
        Remove-Item -LiteralPath $fileLink.Path
        New-Item -ItemType SymbolicLink -Path $fileLink.Path -Target $other | Out-Null
        Remove-DevConfigDotfileLink -Path $fileLink.Path -Source $fileLink.Source
        Assert-Dotfiles ($null -ne (Get-DevConfigDotfilesLinkTarget -Path $fileLink.Path)) 'Cleanup must leave links to other targets alone.'
        Remove-Item -LiteralPath $fileLink.Path

        # End to end through the step runner: apply, then a second run finds everything already OK.
        $Script:DevConfigAction = 'Full'
        $Script:DevConfigPhaseTitle = 'Dotfiles'
        $Script:DevConfigPhaseHeaderShown = $true
        $null = Invoke-DotfilesPhase *>&1
        Assert-Dotfiles (Test-DevConfigDotfileLinked -Path $fileLink.Path -Source $fileLink.Source) 'The phase should link the file.'
        Assert-Dotfiles (Test-DevConfigDotfileLinked -Path $dirLink.Path -Source $dirLink.Source) 'The phase should link the folder.'
        $doneBefore = $Script:DevConfigTally.Done
        $null = Invoke-DotfilesPhase *>&1
        Assert-Dotfiles ($Script:DevConfigTally.Done -eq $doneBefore) 'A second run should change nothing.'
        $Script:DevConfigAction = 'Uninstall'
        $null = Invoke-DotfilesPhase *>&1
        Assert-Dotfiles (-not (Test-Path -LiteralPath $fileLink.Path) -and -not (Test-Path -LiteralPath $dirLink.Path)) 'Cleanup through the phase should remove both links.'
        Assert-Dotfiles (Test-Path -LiteralPath (Join-Path $repo 'git\.gitconfig')) 'Cleanup through the phase must keep the repository.'
    }

    # A bad links file flags the phase instead of stopping the rest of setup.
    $Script:DevConfigAction = 'Full'
    Write-LinksFile $repo "@{ Links = 'nope' }"
    $null = Invoke-DotfilesPhase *>&1
    Assert-Dotfiles ($Script:DevConfigWarnedSteps -contains 'DotfilesLinks') 'A bad links file should be flagged, not thrown.'

    # Without a repository or a variable, the phase is a no-op.
    Remove-Item -LiteralPath $repo -Recurse -Force
    $warned = $Script:DevConfigTally.Warned
    $output = Invoke-DotfilesPhase *>&1 | Out-String
    Assert-Dotfiles ($output -match 'Skipped: set DEVCONFIG_DOTFILES_REPO') 'The phase should explain how to opt in.'
    Assert-Dotfiles ($Script:DevConfigTally.Warned -eq $warned) 'Skipping should not flag anything.'
} finally {
    [Environment]::SetEnvironmentVariable('DEVCONFIG_DOTFILES_REPO', $savedRepoVariable, 'Process')
    if (Test-Path -LiteralPath $sandbox) {
        # Remove links first so recursive cleanup never follows one out of the sandbox.
        Get-ChildItem -LiteralPath $sandbox -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
            ForEach-Object { if ($_.PSIsContainer) { [IO.Directory]::Delete($_.FullName) } else { [IO.File]::Delete($_.FullName) } }
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}

Write-Output "$checks dotfiles checks passed."
