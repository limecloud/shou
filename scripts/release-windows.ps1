param([string]$Tag)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "Run release packaging in PowerShell 7 on Windows x64." }
$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo
try {
    $version = ([xml](Get-Content -LiteralPath "apps/windows/Directory.Build.props" -Raw)).Project.PropertyGroup.Version
    if ($version -notmatch '^\d+\.\d+\.\d+$' -or ($Tag -and $Tag -ne "v$version")) { throw "Release tag and Windows application version must match." }
    $bin = (swift build -c release --show-bin-path | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $bin) { throw "Swift build directory discovery failed." }
    $swiftBin = Split-Path -Parent (Get-Command swiftc -ErrorAction Stop).Source
    $target = swiftc -print-target-info | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Swift runtime discovery failed." }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw "Visual C++ redistributable discovery failed." }
    $crt = Get-ChildItem -Path (Join-Path $visualStudio "VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT") -Directory | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $crt) { throw "Official Visual C++ x64 redistributables are unavailable." }
    $runtimeRoots = @($swiftBin) + @($target.paths.runtimeLibraryPaths) + @($crt.FullName)
    # Swift's Windows installer places the redistributable runtime on PATH.
    # Limit discovery to its installed library tree, never arbitrary PATH DLLs.
    $swiftInstallation = Get-Item -LiteralPath $swiftBin
    while ($swiftInstallation.Parent -and $swiftInstallation.Name -ne "Swift") { $swiftInstallation = $swiftInstallation.Parent }
    if ($swiftInstallation.Name -eq "Swift") {
        $runtimeRoots += @(Get-ChildItem -LiteralPath $swiftInstallation.FullName -Filter swiftCore.dll -Recurse -File | ForEach-Object DirectoryName)
    }
    $runtimeRoots = @($runtimeRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)
    $env:PATH = $swiftBin + ";" + $env:PATH
    $output = Join-Path $repo "dist/release-windows-$version"
    New-Item -ItemType Directory -Path $output | Out-Null
    $licenses = Join-Path $output "runtime-licenses"
    New-Item -ItemType Directory -Path $licenses | Out-Null
    $licenseSources = [ordered]@{
        "Swift-LICENSE.txt" = "https://raw.githubusercontent.com/swiftlang/swift/swift-6.2.3-RELEASE/LICENSE.txt"
        "Foundation-LICENSE.txt" = "https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/swift-6.2.3-RELEASE/LICENSE"
        "Dispatch-LICENSE.txt" = "https://raw.githubusercontent.com/swiftlang/swift-corelibs-libdispatch/swift-6.2.3-RELEASE/LICENSE"
        "ICU-LICENSE.txt" = "https://raw.githubusercontent.com/unicode-org/icu/release-76-1/LICENSE"
    }
    foreach ($entry in $licenseSources.GetEnumerator()) {
        Invoke-WebRequest -Uri $entry.Value -OutFile (Join-Path $licenses $entry.Key)
    }
    $dotnetRoot = Split-Path -Parent (Get-Command dotnet -ErrorAction Stop).Source
    foreach ($name in @("LICENSE.txt", "ThirdPartyNotices.txt")) {
        Copy-Item -LiteralPath (Join-Path $dotnetRoot $name) -Destination (Join-Path $licenses "DotNet-$name")
    }
    @"
Microsoft Visual C++ runtime libraries are redistributed from the installed Visual Studio x64 CRT redistributable directory.
Visual Studio license and redistributable terms: https://visualstudio.microsoft.com/license-terms/
Runtime package details: https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist
.NET and WPF notices are included in this directory. Swift and Foundation use Apache 2.0 with Runtime Library Exception; Dispatch and ICU notices are included separately.
"@ | Set-Content -LiteralPath (Join-Path $licenses "THIRD-PARTY-NOTICES.txt") -Encoding utf8
    $package = Join-Path $output "Shou-$version-windows-x64"
    ./scripts/package-windows.ps1 -EngineExecutable (Join-Path $bin "shou.exe") -SwiftRuntimeDirectory $runtimeRoots -OutputDirectory $package -RuntimeLicenseDirectory $licenses
    $archive = Join-Path $output "Shou-$version-windows-x64.zip"
    Compress-Archive -LiteralPath $package -DestinationPath $archive -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath (Join-Path $output "SHA256SUMS-windows") -Encoding ascii
    python -B "scripts/verify-windows-release.py" "v$version" $archive
    if ($LASTEXITCODE -ne 0) { throw "Extracted Windows release verification failed." }
    Write-Output "Verified Windows release archive: $archive"
} finally { Pop-Location }
