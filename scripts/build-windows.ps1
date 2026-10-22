param(
    [ValidateSet("Debug", "Release")][string]$Configuration = "Release",
    [ValidateSet("All", "Build", "Check")][string]$Stage = "All",
    [switch]$NativeClosingFixtures,
    [switch]$NativeToolFixtures,
    [switch]$NativeUninstallFixtures,
    [switch]$NativeUsageFixtures
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
        $launcherBin = (swift build -c $swiftConfiguration --show-bin-path | Select-Object -Last 1).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $launcherBin) { throw "Native launcher build directory discovery failed." }
        # SwiftPM injects swiftrt.obj into Windows C++ executable links. Build
        # the standalone user command directly so it retains Kernel32-only imports.
        $nativeCompiler = (Get-Command clang -ErrorAction Stop).Source
        $nativeOptimization = if ($Configuration -eq "Release") { "-O2" } else { "-O0" }
        foreach ($program in @(
            @{ Source = "packages/windows-cli-launcher/launcher.cpp"; Name = "shou-cli-launcher"; Entry = "shou_cli_entry"; Libraries = @("kernel32.lib") },
            @{ Source = "tests/windows-cli-launcher/probe.cpp"; Name = "shou-cli-launcher-probe"; Entry = "shou_cli_probe_entry"; Libraries = @("kernel32.lib", "shell32.lib") }
        )) {
            $nativeLibraries = $program.Libraries
            & $nativeCompiler -x c++ -std=c++17 $nativeOptimization -fno-builtin -fno-stack-protector -fno-exceptions -fno-rtti -fuse-ld=lld $program.Source -o (Join-Path $launcherBin ($program.Name + ".exe")) -Xlinker /NODEFAULTLIB -Xlinker ("/ENTRY:" + $program.Entry) -Xlinker /SUBSYSTEM:CONSOLE @nativeLibraries
            if ($LASTEXITCODE -ne 0) { throw "Native $($program.Name) build failed." }
        }
        swift build -c $swiftConfiguration --jobs 4 --product shou-windows-closing-checks
        if ($LASTEXITCODE -ne 0) { throw "Independent normal-close fixture build failed." }
        swift build -c $swiftConfiguration --jobs 4 --product shou-windows-tools-checks
        if ($LASTEXITCODE -ne 0) { throw "Independent tool process fixture build failed." }
        swift build -c $swiftConfiguration --jobs 4 --product shou-windows-uninstall-checks
        if ($LASTEXITCODE -ne 0) { throw "Independent generated installer fixture build failed." }
        swift build -c $swiftConfiguration --jobs 4 --product shou-windows-preview-checks
        if ($LASTEXITCODE -ne 0) { throw "Independent generated preview stream fixture build failed." }
        swift build -c $swiftConfiguration --jobs 4 --product shou-windows-package-data-checks
        if ($LASTEXITCODE -ne 0) { throw "Independent MSIX input fixture build failed." }
        swift build -c $swiftConfiguration --jobs 4 --product shou-windows-application-usage-checks
        if ($LASTEXITCODE -ne 0) { throw "Independent application usage fixture build failed." }
        # The Swift 6.2.3 Windows compiler currently crashes in SIL partitioning
        # while compiling shou-windows-tests. The production engine still
        # compiles here; fixture coverage remains available in that target for
        # a toolchain update and the checks below exercise the shipped engine.
        Push-Location (Join-Path $repo "apps/windows")
        try {
            dotnet build "Shou.slnx" -c $Configuration --nologo
            if ($LASTEXITCODE -ne 0) { throw "WPF build failed." }
        } finally { Pop-Location }
        $desktopCli = Join-Path $repo "apps/windows/Shou.Windows/bin/$Configuration/net10.0-windows/CLI"
        New-Item -ItemType Directory -Path $desktopCli -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $launcherBin "shou-cli-launcher.exe") -Destination $desktopCli -Force
    }
    $bin = (swift build -c $swiftConfiguration --show-bin-path | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $bin) { throw "Swift build directory discovery failed." }
    if ($Stage -in @("All", "Check")) {
        python -B "scripts/verify-windows-localization.py"
        if ($LASTEXITCODE -ne 0) { throw "Windows UI catalog coverage and format verification failed." }
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
            Push-Location (Join-Path $repo "apps/windows")
            try {
                dotnet run --project "Shou.Windows.Checks" -c $Configuration --no-build -- --engine (Join-Path $bin "shou.exe")
                if ($LASTEXITCODE -ne 0) { throw "Desktop process checks failed." }
            } finally { Pop-Location }
            python -B "scripts/verify-windows-preview.py" --engine (Join-Path $bin "shou.exe") --native-harness (Join-Path $bin "shou-windows-preview-checks.exe")
            if ($LASTEXITCODE -ne 0) { throw "System preview input boundaries and generated native read-only stream checks failed." }
            $checks = Join-Path $repo "apps/windows/Shou.Windows.Checks/bin/$Configuration/net10.0/Shou.Windows.Checks.dll"
            python -B "scripts/verify-windows-cli-install.py" --engine (Join-Path $bin "shou.exe") --launcher (Join-Path $bin "shou-cli-launcher.exe") --installer $checks --dotnet (Get-Command dotnet -ErrorAction Stop).Source --probe (Join-Path $bin "shou-cli-launcher-probe.exe")
            if ($LASTEXITCODE -ne 0) { throw "Native user CLI installation and argument/stream forwarding checks failed." }
            python -B "scripts/verify-ai-investigation.py" (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "AI provider, lifecycle and privacy contracts failed." }
            python -B "scripts/verify-agent-setup.py" --engine (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "External agent setup, reviewed Skill installation and portable ZIP checks failed." }
            python -B "scripts/verify-windows-startup.py" (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "Windows startup read-only source and confirmation checks failed." }
            python -B "scripts/verify-windows-applications.py" (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "Windows application registration inventory checks failed." }
            python -B "scripts/verify-windows-uninstall.py" --engine (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "Windows installer input and discovery checks failed." }
            python -B "scripts/verify-windows-app-data.py" --engine (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "Windows application-data input, consent and discovery checks failed." }
            python -B "scripts/verify-windows-package-data.py" --engine (Join-Path $bin "shou.exe") --native-harness (Join-Path $bin "shou-windows-package-data-checks.exe")
            if ($LASTEXITCODE -ne 0) { throw "MSIX data input, consent, discovery and native pre-cancellation checks failed." }
            $usageArguments = @("-B", "scripts/verify-windows-application-usage.py", "--engine", (Join-Path $bin "shou.exe"), "--native-harness", (Join-Path $bin "shou-windows-application-usage-checks.exe"))
            if ($NativeUsageFixtures) { $usageArguments += "--native-fixtures" }
            python @usageArguments
            if ($LASTEXITCODE -ne 0) { throw "Application usage read-only boundaries or generated fixtures failed." }
            if ($NativeUninstallFixtures) {
                python -B "scripts/verify-windows-uninstall.py" --engine (Join-Path $bin "shou.exe") --native-harness (Join-Path $bin "shou-windows-uninstall-checks.exe")
                if ($LASTEXITCODE -ne 0) { throw "Generated installer fixture acceptance did not pass; use a standard-user Windows session." }
            }
            python -B "scripts/verify-privacy-bridge.py" --engine (Join-Path $bin "shou.exe") --native-fixtures
            if ($LASTEXITCODE -ne 0) { throw "Browser privacy scope, confirmation and isolated transaction checks failed." }
            python -B "scripts/verify-windows-closing.py" --engine (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "Normal-close scope and command discovery checks failed." }
            if ($NativeClosingFixtures) {
                python -B "scripts/verify-windows-closing.py" --engine (Join-Path $bin "shou.exe") --native-harness (Join-Path $bin "shou-windows-closing-checks.exe")
                if ($LASTEXITCODE -ne 0) { throw "Generated normal-close native fixture acceptance did not pass; use a standard-user interactive Windows session." }
            }
            python -B "scripts/verify-tool-cleanup.py" --engine (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "Tool cleanup input and discovery checks failed." }
            if ($NativeToolFixtures) {
                python -B "scripts/verify-tool-cleanup.py" --engine (Join-Path $bin "shou.exe") --native-harness (Join-Path $bin "shou-windows-tools-checks.exe")
                if ($LASTEXITCODE -ne 0) { throw "Generated tool process fixture acceptance did not pass; use a standard-user Windows session." }
            }
            python -B "scripts/verify-rule-authoring.py" (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "Personal rule authoring, preview and immutable revision checks failed." }
            python -B "scripts/verify-scan-locations.py" --engine (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "Scan location inventory and confirmed configuration removal checks failed." }
            python -B "scripts/verify-storage-browsing.py" --engine (Join-Path $bin "shou.exe")
            if ($LASTEXITCODE -ne 0) { throw "Storage browsing, protection and shared selection checks failed." }
            python -B "scripts/verify-desktop-bridge.py" --engine (Join-Path $bin "shou.exe") --native-permanent
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
