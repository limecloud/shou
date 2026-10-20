param(
    [ValidateSet("Debug", "Release")][string]$Configuration = "Release",
    [ValidateSet("All", "Build", "Check")][string]$Stage = "All"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "Run this script in PowerShell 7 on Windows." }
$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo
try {
    $swiftConfiguration = $Configuration.ToLowerInvariant()
    if ($Stage -in @("All", "Build")) {
        swift build -c $swiftConfiguration --jobs 4 --product shou
        if ($LASTEXITCODE -ne 0) { throw "Swift CLI build failed." }
        # Swift 6.2.3's Windows optimizer can assert in SIL partitioning for
        # this test executable. Keep the production CLI optimized while
        # compiling the validation binary without optimization.
        swift build -c $swiftConfiguration --jobs 4 --product shou-windows-tests -Xswiftc -Onone
        if ($LASTEXITCODE -ne 0) { throw "Windows native check build failed." }
        Push-Location (Join-Path $repo "apps/windows")
        try {
            dotnet build "Shou.slnx" -c $Configuration --nologo
            if ($LASTEXITCODE -ne 0) { throw "WPF build failed." }
        } finally { Pop-Location }
    }
    $bin = (swift build -c $swiftConfiguration --show-bin-path | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $bin) { throw "Swift build directory discovery failed." }
    if ($Stage -in @("All", "Check")) {
        # AppData is intentionally protected. Keep generated test workspaces
        # outside it without changing the application's root safety checks.
        $fixtureRoot = Join-Path $repo (".build/windows-fixtures-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        $originalTemp = @{}
        foreach ($name in @("TEMP", "TMP", "TMPDIR")) {
            $originalTemp[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, $fixtureRoot, "Process")
        }
        try {
            & (Join-Path $bin "shou-windows-tests.exe") --recycle
            if ($LASTEXITCODE -ne 0) { throw "Windows native checks failed." }
            Push-Location (Join-Path $repo "apps/windows")
            try {
                dotnet run --project "Shou.Windows.Checks" -c $Configuration --no-build -- --engine (Join-Path $bin "shou.exe")
                if ($LASTEXITCODE -ne 0) { throw "Desktop process checks failed." }
            } finally { Pop-Location }
            python -B "scripts/verify-desktop-bridge.py" --engine (Join-Path $bin "shou.exe") --native-trash --native-permanent
            if ($LASTEXITCODE -ne 0) { throw "Real desktop protocol integration failed." }
        } finally {
            foreach ($name in $originalTemp.Keys) {
                [Environment]::SetEnvironmentVariable($name, $originalTemp[$name], "Process")
            }
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
    }
    Write-Output "Windows $Stage stage passed: $bin"
} finally { Pop-Location }
