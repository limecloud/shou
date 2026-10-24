param([Parameter(Mandatory)][string]$PublishRoot, [Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Cli = Join-Path $PublishRoot 'cli/shou.exe'
$App = Join-Path $PublishRoot 'app/Shou.Windows.App.exe'
$VersionResult = & $Cli --version --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $VersionResult.data.version.Split('+')[0] -ne $Version) { throw 'Published CLI version differs.' }
$Capabilities = & $Cli capabilities --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $Capabilities.data.mutation_available -or $Capabilities.data.application_uninstall_available -or $Capabilities.data.startup_control_available) {
    throw 'Unaccepted native mutation capabilities must remain unavailable.'
}
$Started = Get-Date
$Process = Start-Process $App -PassThru
try {
    if (-not $Process.WaitForInputIdle(20000)) { throw 'WinUI did not initialize within its startup budget.' }
    $Deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $Process.Refresh()
        if ($Process.HasExited) { throw "WinUI exited during startup: $($Process.ExitCode)" }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $Deadline)
    if ($Process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'WinUI did not create its main window.' }
    if (-not $Process.CloseMainWindow() -or -not $Process.WaitForExit(10000) -or $Process.ExitCode -ne 0) {
        throw 'WinUI did not close normally.'
    }
    Write-Output 'Published x64 CLI version/capabilities and WinUI window startup/normal close verified.'
} finally {
    if (-not $Process.HasExited) { $Process.Kill($true); $Process.WaitForExit() }
    $Process.Dispose()
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $LogFile = Join-Path $env:LOCALAPPDATA 'Shou/Logs/application.jsonl'
        if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 }
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $Started } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -like '*Shou.Windows.App*' } |
            Select-Object -First 5 TimeCreated, ProviderName, Id, Message | Format-List
    }
}
