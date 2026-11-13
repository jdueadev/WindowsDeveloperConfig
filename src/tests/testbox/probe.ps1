[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($tool in @(
        @{ Name = 'pwsh'; Arguments = @('-NoProfile', '-Command', '$PSVersionTable.PSVersion') }
        @{ Name = 'git'; Arguments = @('--version') }
        @{ Name = 'gh'; Arguments = @('--version') }
        @{ Name = 'uv'; Arguments = @('--version') }
    )) {
    $null = Get-Command $tool.Name -ErrorAction Stop
    $null = & $tool.Name @($tool.Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "$($tool.Name) $($tool.Arguments -join ' ') exited with code $LASTEXITCODE"
    }
}

$developerMode = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
    -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
if (-not $developerMode -or $developerMode.AllowDevelopmentWithoutDevLicense -ne 1) {
    throw 'Developer Mode is not enabled.'
}

$longPaths = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
    -Name 'LongPathsEnabled' -ErrorAction SilentlyContinue
if (-not $longPaths -or $longPaths.LongPathsEnabled -ne 1) {
    throw 'Long paths are not enabled.'
}

# wsl.exe writes UTF-16LE; strip NULs before matching the distro name.
$distros = @((& wsl.exe --list --quiet) | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
if ($LASTEXITCODE -ne 0) {
    throw "wsl --list --quiet exited with code $LASTEXITCODE"
}
# Same rule as the WSL phase: any Ubuntu registration, including versioned ones such as Ubuntu-24.04.
if (@($distros | Where-Object { $_ -like 'Ubuntu*' }).Count -eq 0) {
    throw 'WSL does not list an Ubuntu distro.'
}

Write-Output 'OK'
