param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [string]$ArtifactsRoot,
    [switch]$Launch
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ArtifactsRoot) { $ArtifactsRoot = Join-Path $env:LOCALAPPDATA "ShouBuild/$Runtime" }
$ArtifactsRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArtifactsRoot)
$SourceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$WindowsRoot = Join-Path $SourceRoot 'apps/windows'
$AppProject = Join-Path $WindowsRoot 'src/Shou.Windows.App/Shou.Windows.App.csproj'
$CliProject = Join-Path $WindowsRoot 'src/Shou.Windows.Cli/Shou.Windows.Cli.csproj'
$Architecture = if ($Runtime -eq 'win-arm64') { 'ARM64' } else { 'x64' }
$PublishRoot = Join-Path $ArtifactsRoot 'publish'

function Invoke-Dotnet {
    param([string[]]$Arguments)
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet failed with exit code $LASTEXITCODE" }
}

Push-Location $WindowsRoot
try {
    Invoke-Dotnet -Arguments @('restore', $AppProject, "-p:RuntimeIdentifier=$Runtime", '--locked-mode', "-p:ArtifactsPath=$ArtifactsRoot", "-p:Platform=$Architecture")
    Invoke-Dotnet -Arguments @('publish', $AppProject, '-c', 'Release', '-r', $Runtime, '--no-restore', "-p:ArtifactsPath=$ArtifactsRoot", "-p:Platform=$Architecture", '-o', (Join-Path $PublishRoot 'app'))
    & python (Join-Path $SourceRoot 'scripts/prepare-windows-cli-notices.py') --payload (Join-Path $PublishRoot 'app') --assets (Join-Path $ArtifactsRoot 'obj/Shou.Windows.App/project.assets.json') --name Shou.Windows.App
    if ($LASTEXITCODE -ne 0) { throw 'Application dependency notices could not be prepared.' }
    Invoke-Dotnet -Arguments @('restore', $CliProject, "-p:RuntimeIdentifier=$Runtime", '--locked-mode', "-p:ArtifactsPath=$ArtifactsRoot")
    Invoke-Dotnet -Arguments @('publish', $CliProject, '-c', 'Release', '-r', $Runtime, '--no-restore', "-p:ArtifactsPath=$ArtifactsRoot", '-o', (Join-Path $PublishRoot 'cli'))
    & python (Join-Path $SourceRoot 'scripts/prepare-windows-cli-notices.py') --payload (Join-Path $PublishRoot 'cli') --assets (Join-Path $ArtifactsRoot 'obj/Shou.Windows.Cli/project.assets.json')
    if ($LASTEXITCODE -ne 0) { throw 'CLI dependency notices could not be prepared.' }
    if ($Launch) {
        $Process = Start-Process (Join-Path $PublishRoot 'app/Shou.Windows.App.exe') -PassThru
        Write-Output "Started Shou: PID $($Process.Id)"
    }
} finally {
    Pop-Location
    $LogFile = Join-Path $env:LOCALAPPDATA 'Shou/Logs/application.jsonl'
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 }
}
