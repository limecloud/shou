#requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$RunGeneratedStartupFixtures,
    [string]$ArtifactsRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $RunGeneratedStartupFixtures) {
    throw 'Pass -RunGeneratedStartupFixtures to register, switch and remove newly generated inert current-user tasks. Existing task identifiers are never accepted.'
}
if (-not $IsWindows -or -not [OperatingSystem]::IsWindowsVersionAtLeast(10, 0, 22000)) {
    throw 'Generated startup fixtures require native Windows 11.'
}
$ShouProcessArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
$ShouOsArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if (-not [Environment]::Is64BitProcess -or $ShouProcessArch -ne $ShouOsArch -or $ShouProcessArch.ToString() -notin @('X64', 'Arm64')) {
    throw 'Run native x64 PowerShell on x64 Windows, or native ARM64 PowerShell on ARM64 Windows. Emulated runs are not native acceptance.'
}
if (-not $ArtifactsRoot) { $ArtifactsRoot = Join-Path $env:LOCALAPPDATA 'ShouBuild/generated-startup-tests' }
$ArtifactsRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArtifactsRoot)
if ([System.IO.Path]::GetPathRoot($ArtifactsRoot) -notmatch '^[A-Za-z]:\\$' -or
    [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($ArtifactsRoot)).DriveType -ne [System.IO.DriveType]::Fixed) {
    throw 'Use a fixed local Windows drive for fixture outputs; shared, mapped-network and UNC locations are not supported.'
}
$ShouSourceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ShouWindowsRoot = Join-Path $ShouSourceRoot 'apps/windows'
$ShouRunRoot = Join-Path $ArtifactsRoot ('run-' + [Guid]::NewGuid().ToString('N'))
$ShouResultsRoot = Join-Path $ShouRunRoot 'results'
New-Item -ItemType Directory -Path $ShouResultsRoot -Force | Out-Null
$ShouPreviousOptIn = [Environment]::GetEnvironmentVariable('SHOU_TEST_GENERATED_STARTUP', 'Process')
$ShouPreviousEvidence = [Environment]::GetEnvironmentVariable('SHOU_TEST_GENERATED_STARTUP_EVIDENCE', 'Process')
$ShouProvenance = @'
import importlib.util, json, sys
from pathlib import Path
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("shou_package", root / "scripts/package-npm.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
Path(sys.argv[2]).write_text(json.dumps(module.source_state("HEAD", True), indent=2) + "\n", encoding="utf-8")
'@
Push-Location $ShouWindowsRoot
try {
    & python (Join-Path $ShouSourceRoot 'scripts/generate-windows-resources.py') --check
    if ($LASTEXITCODE -ne 0) { throw "Generated resources failed: $LASTEXITCODE" }
    & python -c $ShouProvenance $ShouSourceRoot (Join-Path $ShouRunRoot 'source.json')
    if ($LASTEXITCODE -ne 0) { throw "Source evidence failed: $LASTEXITCODE" }
    & dotnet --info | Out-File (Join-Path $ShouRunRoot 'dotnet-info.txt') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "Cannot read the pinned .NET toolchain: $LASTEXITCODE" }
    [Environment]::SetEnvironmentVariable('SHOU_TEST_GENERATED_STARTUP', '1', 'Process')
    [Environment]::SetEnvironmentVariable('SHOU_TEST_GENERATED_STARTUP_EVIDENCE', (Join-Path $ShouRunRoot 'fixtures'), 'Process')
    & dotnet test 'tests/Shou.Windows.Platform.Tests/Shou.Windows.Platform.Tests.csproj' -c Release -p:RestoreLockedMode=true `
        "-p:ArtifactsPath=$ArtifactsRoot/build" --filter 'FullyQualifiedName~GeneratedStartupControlTests' `
        --logger 'trx;LogFileName=generated-startup.trx' --results-directory $ShouResultsRoot
    $ShouTestExit = $LASTEXITCODE
    if ($ShouTestExit -ne 0) { throw "Generated startup checks failed: $ShouTestExit. Evidence: $ShouRunRoot" }
    [xml]$ShouTrx = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($ShouResultsRoot, 'generated-startup.trx'))
    $ShouCases = @($ShouTrx.SelectNodes("//*[local-name()='UnitTestResult']"))
    $ShouAllPassed = $ShouCases.Count -eq 6
    foreach ($ShouCase in $ShouCases) {
        if ($ShouCase.outcome -ne 'Passed') { $ShouAllPassed = $false }
    }
    if (-not $ShouAllPassed) {
        throw "Every generated startup case must execute and pass; skipped cases are not acceptance. Evidence: $ShouRunRoot"
    }
    & python -c $ShouProvenance $ShouSourceRoot (Join-Path $ShouRunRoot 'source-after.json')
    if ($LASTEXITCODE -ne 0) { throw "Final source evidence failed: $LASTEXITCODE" }
    $ShouBefore = Get-Content -Raw -LiteralPath (Join-Path $ShouRunRoot 'source.json') | ConvertFrom-Json
    $ShouAfter = Get-Content -Raw -LiteralPath (Join-Path $ShouRunRoot 'source-after.json') | ConvertFrom-Json
    foreach ($ShouField in @('source_commit', 'source_tree', 'worktree_sha256')) {
        if ($ShouBefore.$ShouField -ne $ShouAfter.$ShouField) {
            throw "Source changed during native tests; this run cannot accept the new source. Evidence: $ShouRunRoot"
        }
    }
    $ShouFixtureDirectories = @(Get-ChildItem -LiteralPath (Join-Path $ShouRunRoot 'fixtures') -Directory)
    if ($ShouFixtureDirectories.Count -ne 6) { throw 'Expected one newly generated fixture per native case.' }
    foreach ($ShouFixtureDirectory in $ShouFixtureDirectories) {
        $ShouInitialFile = Get-ChildItem -LiteralPath $ShouFixtureDirectory.FullName -Filter '*-registered_disabled.json' -File
        if (@($ShouInitialFile).Count -ne 1) { throw "Missing generated task registration receipt: $($ShouFixtureDirectory.FullName)" }
        $ShouInitial = Get-Content -Raw -LiteralPath $ShouInitialFile.FullName | ConvertFrom-Json -Depth 64
        if ($ShouInitial.generated_task_only -ne $true -or $ShouInitial.native_runtime_checked -ne $true -or
            $ShouInitial.public_execution_enabled -ne $false -or $ShouInitial.details.task_present -ne $true -or
            $ShouInitial.details.generated_trigger_disabled -ne $true -or $ShouInitial.details.demand_start_disabled -ne $true -or
            $ShouInitial.details.facts.enabled -ne $false) {
            throw "Generated task was not recorded as initially disabled and inert: $($ShouFixtureDirectory.FullName)"
        }
        $ShouReceiptFile = Get-ChildItem -LiteralPath $ShouFixtureDirectory.FullName -Filter '*-fixture_removed.json' -File
        if (@($ShouReceiptFile).Count -ne 1) { throw "Missing exact fixture teardown receipt: $($ShouFixtureDirectory.FullName)" }
        $ShouReceipt = Get-Content -Raw -LiteralPath $ShouReceiptFile.FullName | ConvertFrom-Json -Depth 64
        if ($ShouReceipt.generated_task_only -ne $true -or $ShouReceipt.native_runtime_checked -ne $true -or
            $ShouReceipt.public_execution_enabled -ne $false -or $ShouReceipt.details.task_present -ne $false -or
            $ShouReceipt.details.generated_folder_absent -ne $true -or
            $ShouReceipt.details.marker_file_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $ShouReceipt.details.marker_file_sha256 -cne $ShouInitial.details.marker_file_sha256) {
            throw "Fixture teardown or public-gate evidence is incomplete: $($ShouFixtureDirectory.FullName)"
        }
    }
    $ShouHashes = [ordered]@{}
    foreach ($ShouFile in (Get-ChildItem -LiteralPath $ShouRunRoot -Recurse -File | Sort-Object FullName)) {
        $ShouRelative = [System.IO.Path]::GetRelativePath($ShouRunRoot, $ShouFile.FullName).Replace('\', '/')
        $ShouHashes[$ShouRelative] = (Get-FileHash -LiteralPath $ShouFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [ordered]@{
        schema_version = 1
        at_utc = [DateTimeOffset]::UtcNow.ToString('O')
        process_arch = $ShouProcessArch.ToString()
        os_arch = $ShouOsArch.ToString()
        os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        generated_startup_cases_passed = $ShouCases.Count
        fixture_only = $true
        fixture_teardown_verified = $true
        source_stable = $true
        terminal_confirmation_tested = $false
        file_hashes = $ShouHashes
        public_execution_enabled = $false
        fixture_triggers_disabled = $true
        fixture_demand_start_disabled = $true
        winui_tested = $false
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ShouRunRoot 'verification.json') -Encoding utf8
    Write-Host "Generated startup evidence: $ShouRunRoot"
} finally {
    [Environment]::SetEnvironmentVariable('SHOU_TEST_GENERATED_STARTUP', $ShouPreviousOptIn, 'Process')
    [Environment]::SetEnvironmentVariable('SHOU_TEST_GENERATED_STARTUP_EVIDENCE', $ShouPreviousEvidence, 'Process')
    Pop-Location
}
