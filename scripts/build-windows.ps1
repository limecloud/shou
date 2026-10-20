param([ValidateSet("Debug", "Release")][string]$Configuration = "Release")
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "Run this script in PowerShell 7 on Windows." }
$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo
try {
    $swiftConfiguration = $Configuration.ToLowerInvariant()
    swift build -c $swiftConfiguration --jobs 4 --product shou
    if ($LASTEXITCODE -ne 0) { throw "Swift CLI build failed." }
    swift build -c $swiftConfiguration --jobs 4 --product shou-windows-tests
    if ($LASTEXITCODE -ne 0) { throw "Windows native check build failed." }
    $bin = (swift build -c $swiftConfiguration --show-bin-path | Select-Object -Last 1).Trim()
    & (Join-Path $bin "shou-windows-tests.exe")
    if ($LASTEXITCODE -ne 0) { throw "Windows native checks failed." }
    Push-Location (Join-Path $repo "apps/windows")
    try {
        dotnet build "Shou.slnx" -c $Configuration --nologo
        if ($LASTEXITCODE -ne 0) { throw "WPF build failed." }
        dotnet run --project "Shou.Windows.Checks" -c $Configuration --no-build -- --engine (Join-Path $bin "shou.exe")
        if ($LASTEXITCODE -ne 0) { throw "Desktop process checks failed." }
    } finally { Pop-Location }
    python -B "scripts/verify-desktop-bridge.py" --engine (Join-Path $bin "shou.exe")
    if ($LASTEXITCODE -ne 0) { throw "Real desktop protocol integration failed." }
    Write-Output "Windows build and generated-fixture checks passed: $bin"
} finally { Pop-Location }
