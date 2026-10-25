param(
    [Parameter(Mandatory)][string]$PublishRoot,
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = ('win-' + [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()),
    [string]$ReportPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Architecture = $Runtime.Substring(4)
$HostArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$ProcessArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $HostArchitecture -ne $Architecture -or $ProcessArchitecture -ne $Architecture) {
    throw 'Published runtime verification requires matching native Windows and PowerShell architectures.'
}
$Cli = Join-Path $PublishRoot 'cli/shou.exe'
$App = Join-Path $PublishRoot 'app/Shou.Windows.App.exe'
# Check both apphosts and their bundled runtimes before starting either process.
$ExpectedMachine = if ($Runtime -eq 'win-arm64') { 0xAA64 } else { 0x8664 }
foreach ($Relative in @('cli/shou.exe', 'cli/coreclr.dll', 'app/Shou.Windows.App.exe', 'app/coreclr.dll', 'app/Microsoft.UI.Xaml.dll')) {
    $Reader = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $PublishRoot $Relative)))
    try {
        if ($Reader.BaseStream.Length -lt 64 -or $Reader.ReadUInt16() -ne 0x5A4D) { throw "Invalid PE image: $Relative" }
        $Reader.BaseStream.Position = 60
        $Offset = $Reader.ReadUInt32()
        if ($Offset -lt 64 -or $Offset -gt $Reader.BaseStream.Length - 6) { throw "Invalid PE header: $Relative" }
        $Reader.BaseStream.Position = $Offset
        if ($Reader.ReadUInt32() -ne 0x00004550 -or $Reader.ReadUInt16() -ne $ExpectedMachine) { throw "Published runtime architecture differs: $Relative" }
    } finally { $Reader.Dispose() }
}
$VersionResult = & $Cli --version --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $VersionResult.data.version.Split('+')[0] -ne $Version) { throw 'Published CLI version differs.' }
$Capabilities = & $Cli capabilities --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $Capabilities.data.host_supported -or $Capabilities.data.mutation_available -ne $false -or $Capabilities.data.application_uninstall_available -ne $false -or $Capabilities.data.startup_control_available -ne $false) {
    throw 'Published preview must recognize the native Windows host and keep public mutation gates closed.'
}
$Diagnostics = & $Cli diagnostics --json | ConvertFrom-Json
if ($LASTEXITCODE -notin @(0, 6) -or $Diagnostics.data.architecture -ne $Architecture) { throw 'Published CLI did not report its expected native process architecture.' }
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
    if ($ReportPath) {
        $null = New-Item -ItemType Directory -Path (Split-Path $ReportPath -Parent) -Force
        [ordered]@{
            format_version = 1; source_commit = $env:GITHUB_SHA; version = $Version; runtime = $Runtime;
            os = [Environment]::OSVersion.VersionString; os_architecture = $HostArchitecture;
            powershell_architecture = $ProcessArchitecture; cli_architecture = $Diagnostics.data.architecture;
            cli_sha256 = (Get-FileHash -LiteralPath $Cli -Algorithm SHA256).Hash;
            app_sha256 = (Get-FileHash -LiteralPath $App -Algorithm SHA256).Hash;
            window_started = $true; normal_close = $true; public_mutations_enabled = $false;
            full_ui_accepted = $false; captured_utc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding UTF8
    }
    Write-Output "Published $Architecture CLI version/capabilities/diagnostics and WinUI window startup/normal close verified."
} finally {
    if (-not $Process.HasExited) { $Process.Kill($true); $Process.WaitForExit() }
    $Process.Dispose()
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $LogFile = Join-Path $env:LOCALAPPDATA 'Shou/Diagnostics/application.jsonl'
        if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 }
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $Started } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -like '*Shou.Windows.App*' } |
            Select-Object -First 5 TimeCreated, ProviderName, Id, Message | Format-List
    }
}
