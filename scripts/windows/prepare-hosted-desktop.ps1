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
$Names = @('UserOOBEBroker', 'UserOOBEHost', 'CloudExperienceHostBroker', 'CloudExperienceHostApp', 'msoobe')
if ($RestartExplorer) { $Names += 'explorer' }
$Session = [Diagnostics.Process]::GetCurrentProcess().SessionId
foreach ($Process in @(Get-Process -Name $Names -ErrorAction SilentlyContinue)) {
    if ($Process.SessionId -eq $Session -and $Process.Path -and
        $Process.Path.StartsWith($env:WINDIR + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $Process | Select-Object Id, ProcessName, Path | ConvertTo-Json -Compress
        Stop-Process -InputObject $Process -Force -ErrorAction Stop
        if (-not $Process.WaitForExit(10000)) { throw 'Hosted-runner desktop setup did not stop.' }
    }
}
if ($RestartExplorer) { Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') | Out-Null }
