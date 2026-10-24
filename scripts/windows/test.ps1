param([string]$ArtifactsRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ArtifactsRoot) { $ArtifactsRoot = Join-Path $env:LOCALAPPDATA 'ShouBuild/tests' }
$ArtifactsRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArtifactsRoot)
$SourceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$WindowsRoot = Join-Path $SourceRoot 'apps/windows'
Push-Location $WindowsRoot
try {
    & (Join-Path $PSScriptRoot 'test-e2e-harness.ps1') -ArtifactsRoot (Join-Path $ArtifactsRoot 'harness')
    & python (Join-Path $SourceRoot 'scripts/generate-windows-resources.py') --check
    if ($LASTEXITCODE -ne 0) { throw "Generated resource check failed: $LASTEXITCODE" }
    & python (Join-Path $SourceRoot 'tests/design/test-design-tokens.py')
    if ($LASTEXITCODE -ne 0) { throw "Design token checks failed: $LASTEXITCODE" }
    foreach ($Project in @('Core', 'Presentation', 'Platform', 'Cli')) {
        & dotnet test "tests/Shou.Windows.$Project.Tests/Shou.Windows.$Project.Tests.csproj" -c Release -p:RestoreLockedMode=true "-p:ArtifactsPath=$ArtifactsRoot" --logger 'trx' --results-directory (Join-Path $ArtifactsRoot "results/$Project")
        if ($LASTEXITCODE -ne 0) { throw "$Project tests failed: $LASTEXITCODE" }
    }
    & dotnet build 'src/Shou.Windows.Cli/Shou.Windows.Cli.csproj' -c Release -p:RestoreLockedMode=true -p:SelfContained=false -p:UseAppHost=false "-p:ArtifactsPath=$ArtifactsRoot"
    if ($LASTEXITCODE -ne 0) { throw "CLI build failed: $LASTEXITCODE" }
    & python (Join-Path $SourceRoot 'scripts/verify-windows-cli-contract.py') --dotnet (Get-Command dotnet).Source --payload (Join-Path $ArtifactsRoot 'bin/Shou.Windows.Cli/release')
    if ($LASTEXITCODE -ne 0) { throw "CLI contract checks failed: $LASTEXITCODE" }
} finally {
    Pop-Location
    & (Join-Path $PSScriptRoot 'collect-diagnostics.ps1') -OutputRoot (Join-Path $ArtifactsRoot 'evidence') -TestResultsRoot (Join-Path $ArtifactsRoot 'results')
}
