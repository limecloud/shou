#requires -Version 7.4
param(
    [switch]$RunGeneratedMsiFixtures,
    [string]$ArtifactsRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $RunGeneratedMsiFixtures) {
    throw 'Pass -RunGeneratedMsiFixtures to install and uninstall newly generated per-user MSI fixtures. Existing software is never a test target.'
}
if (-not $IsWindows -or -not [OperatingSystem]::IsWindowsVersionAtLeast(10, 0, 22000)) {
    throw 'Generated MSI fixtures require native Windows 11.'
}
$ShouProcessArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
$ShouOsArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if (-not [Environment]::Is64BitProcess -or $ShouProcessArch -ne $ShouOsArch -or $ShouProcessArch.ToString() -notin @('X64', 'Arm64')) {
    throw 'Run native x64 PowerShell on x64 Windows, or native ARM64 PowerShell on ARM64 Windows. Emulated runs are not native acceptance.'
}
if (-not $ArtifactsRoot) { $ArtifactsRoot = Join-Path $env:LOCALAPPDATA 'ShouBuild/generated-uninstall-tests' }
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
$ShouPreviousOptIn = [Environment]::GetEnvironmentVariable('SHOU_TEST_GENERATED_MSI', 'Process')
$ShouPreviousEvidence = [Environment]::GetEnvironmentVariable('SHOU_TEST_GENERATED_MSI_EVIDENCE', 'Process')
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
    [Environment]::SetEnvironmentVariable('SHOU_TEST_GENERATED_MSI', '1', 'Process')
    [Environment]::SetEnvironmentVariable('SHOU_TEST_GENERATED_MSI_EVIDENCE', (Join-Path $ShouRunRoot 'fixtures'), 'Process')
    & dotnet test 'tests/Shou.Windows.Platform.Tests/Shou.Windows.Platform.Tests.csproj' -c Release -p:RestoreLockedMode=true `
        "-p:ArtifactsPath=$ArtifactsRoot/build" --filter 'FullyQualifiedName~GeneratedMsiUninstallTests' `
        --logger 'trx;LogFileName=generated-msi.trx' --results-directory $ShouResultsRoot
    $ShouTestExit = $LASTEXITCODE
    if ($ShouTestExit -ne 0) { throw "Generated MSI checks failed: $ShouTestExit. Evidence: $ShouRunRoot" }
    [xml]$ShouTrx = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($ShouResultsRoot, 'generated-msi.trx'))
    $ShouCases = @($ShouTrx.SelectNodes("//*[local-name()='UnitTestResult']"))
    $ShouAllPassed = $ShouCases.Count -gt 0
    foreach ($ShouCase in $ShouCases) {
        if ($ShouCase.outcome -ne 'Passed') { $ShouAllPassed = $false }
    }
    if (-not $ShouAllPassed) {
        throw "Every generated MSI case must execute and pass; skipped cases are not acceptance. Evidence: $ShouRunRoot"
    }
    [ordered]@{
        schema_version = 1
        at_utc = [DateTimeOffset]::UtcNow.ToString('O')
        process_arch = $ShouProcessArch.ToString()
        os_arch = $ShouOsArch.ToString()
        os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        generated_msi_cases_passed = $ShouCases.Count
        fixture_only = $true
        public_execution_enabled = $false
        msix_tested = $false
        winui_tested = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ShouRunRoot 'verification.json') -Encoding utf8
    Write-Host "Generated MSI evidence: $ShouRunRoot"
} finally {
    [Environment]::SetEnvironmentVariable('SHOU_TEST_GENERATED_MSI', $ShouPreviousOptIn, 'Process')
    [Environment]::SetEnvironmentVariable('SHOU_TEST_GENERATED_MSI_EVIDENCE', $ShouPreviousEvidence, 'Process')
    Pop-Location
}
