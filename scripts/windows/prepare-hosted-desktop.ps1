param([switch]$RestartExplorer)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Desktop preparation is restricted to disposable GitHub-hosted runners.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA' -or $PSVersionTable.PSEdition -ne 'Desktop') {
    $Arguments = @('-NoProfile', '-STA', '-File', $PSCommandPath)
    if ($RestartExplorer) { $Arguments += '-RestartExplorer' }
    & powershell.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Hosted desktop preparation failed.' }
    return
}
$PrivacyPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
$UserPrivacyPolicy = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
$PrivacyState = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'
foreach ($Policy in @($PrivacyPolicy, $UserPrivacyPolicy)) {
    New-Item -Path $Policy -Force | Out-Null
    New-ItemProperty -Path $Policy -Name DisablePrivacyExperience -Value 1 -PropertyType DWord -Force | Out-Null
}
New-Item -Path $PrivacyState -Force | Out-Null
New-ItemProperty -Path $PrivacyState -Name PrivacyConsentStatus -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $PrivacyState -Name TailoredExperiencesWithDiagnosticDataEnabled -Value 0 -PropertyType DWord -Force | Out-Null
# OOBE can be hosted inside StartMenuExperienceHost and reopen after its broker
# exits. Complete only the observed privacy page instead of terminating its host.
$HostedWindowsRoot = $env:WINDIR.TrimEnd('\') + '\'
$ExplorerPath = Join-Path $env:WINDIR 'explorer.exe'
$Session = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($RestartExplorer) {
    foreach ($Process in @(Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        if ($Process.SessionId -eq $Session -and [StringComparer]::OrdinalIgnoreCase.Equals($Process.Path, $ExplorerPath)) {
            Stop-Process -InputObject $Process -Force -ErrorAction Stop
            if (-not $Process.WaitForExit(10000)) { throw 'Hosted-runner Explorer did not stop.' }
        }
    }
    Start-Process -FilePath $ExplorerPath | Out-Null
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$Evidence = Join-Path $env:RUNNER_TEMP ('ShouBuild/evidence/hosted-desktop-' + [Guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path $Evidence) -Force | Out-Null
$Actions = [Collections.Generic.List[object]]::new()
$LastControls = @(); $ObservedWindows = @{}; $Failure = $null
$Deadline = [DateTime]::UtcNow.AddSeconds(45)
$QuietSince = [DateTime]::UtcNow
try {
    do {
        $PrivacyWindow = $null
        foreach ($Candidate in @([Windows.Automation.AutomationElement]::RootElement.FindAll(
            [Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition))) {
            $Owner = Get-Process -Id $Candidate.Current.ProcessId -ErrorAction SilentlyContinue
            if ($null -eq $Owner -or $Owner.SessionId -ne $Session -or -not $Owner.Path) { continue }
            if (-not $Owner.Path.StartsWith($HostedWindowsRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $CandidateControls = @($Candidate.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition))
            $ObservedWindows[$Owner.Id] = [ordered]@{ process=$Owner.ProcessName; path=$Owner.Path; name=$Candidate.Current.Name;
                controls=@($CandidateControls | Select-Object -First 300 | ForEach-Object {
                    [ordered]@{ id=$_.Current.AutomationId; name=$_.Current.Name; offscreen=$_.Current.IsOffscreen; type=$_.Current.ControlType.ProgrammaticName }
                }) }
            $Title = $CandidateControls | Where-Object { -not $_.Current.IsOffscreen -and
                ($_.Current.Name -replace '\s+', ' ') -eq 'Choose privacy settings for your device' } | Select-Object -First 1
            if ($null -ne $Title) { $PrivacyWindow = $Candidate; break }
        }
        if ($null -eq $PrivacyWindow) {
            if (([DateTime]::UtcNow - $QuietSince).TotalSeconds -ge 10) { break }
        } else {
            $QuietSince = [DateTime]::UtcNow
            $Controls = @($PrivacyWindow.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition))
            $LastControls = @($Controls | Select-Object -First 300 | ForEach-Object {
                [ordered]@{ id=$_.Current.AutomationId; name=$_.Current.Name; offscreen=$_.Current.IsOffscreen; type=$_.Current.ControlType.ProgrammaticName }
            })
            foreach ($Control in $Controls) {
                if ($Control.Current.IsOffscreen -or -not $Control.Current.IsEnabled) { continue }
                $Toggle = $null
                if ($Control.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$Toggle) -and
                    $Toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) {
                    $Actions.Add([ordered]@{ action='disable_optional_setting'; name=$Control.Current.Name })
                    $Toggle.Toggle()
                }
            }
            $Button = $Controls | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and
                $_.Current.Name -in @('Next','Accept') -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen } | Select-Object -First 1
            if ($null -eq $Button) { throw 'The observed hosted privacy page has no enabled Next or Accept button.' }
            $Actions.Add([ordered]@{ action='advance_privacy_page'; button=$Button.Current.Name; process=$Owner.ProcessName; path=$Owner.Path })
            $Button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $Deadline)
    if (([DateTime]::UtcNow - $QuietSince).TotalSeconds -lt 10) { throw 'Hosted privacy setup did not finish before its deadline.' }
} catch { $Failure = $_.Exception.ToString(); throw }
finally {
    [ordered]@{ passed=($null -eq $Failure); failure=$Failure; actions=$Actions.ToArray(); last_controls=$LastControls;
        observed_windows=@($ObservedWindows.Values); session=$Session } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Evidence -Encoding utf8
    Write-Output "Hosted desktop receipt: $Evidence"
}
