param([switch]$RestartExplorer)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Desktop preparation is restricted to disposable GitHub-hosted runners.'
}
$PrivacyPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
$PrivacyState = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'
New-Item -Path $PrivacyPolicy -Force | Out-Null
New-ItemProperty -Path $PrivacyPolicy -Name DisablePrivacyExperience -Value 1 -PropertyType DWord -Force | Out-Null
New-Item -Path $PrivacyState -Force | Out-Null
New-ItemProperty -Path $PrivacyState -Name PrivacyConsentStatus -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $PrivacyState -Name TailoredExperiencesWithDiagnosticDataEnabled -Value 0 -PropertyType DWord -Force | Out-Null
# The broker and the actual privacy window are separate executables. Inspect the
# fixed OOBE directories so an unlisted host cannot remain above the test window.
$OobeRoots = @(
    (Join-Path $env:WINDIR 'System32\oobe\'),
    (Join-Path $env:WINDIR 'SysWOW64\oobe\'),
    (Join-Path $env:WINDIR 'SystemApps\Microsoft.Windows.CloudExperienceHost_cw5n1h2txyewy\')
)
$ExplorerPath = Join-Path $env:WINDIR 'explorer.exe'
$Session = [Diagnostics.Process]::GetCurrentProcess().SessionId
foreach ($Process in @(Get-Process)) {
    if ($Process.SessionId -ne $Session -or -not $Process.Path) { continue }
    $IsOobe = @($OobeRoots | Where-Object { $Process.Path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    $IsExplorer = $RestartExplorer -and [StringComparer]::OrdinalIgnoreCase.Equals($Process.Path, $ExplorerPath)
    if ($IsOobe -or $IsExplorer) {
        $Process | Select-Object Id, ProcessName, Path, MainWindowTitle | ConvertTo-Json -Compress
        if (-not $Process.HasExited) {
            Stop-Process -InputObject $Process -Force -ErrorAction Stop
            if (-not $Process.WaitForExit(10000)) { throw 'Hosted-runner desktop setup did not stop.' }
        }
    }
}
if ($RestartExplorer) { Start-Process -FilePath $ExplorerPath | Out-Null }
