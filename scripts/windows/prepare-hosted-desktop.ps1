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
if (-not ('HostedDesktopNative' -as [type])) {
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class HostedDesktopNative {
 [StructLayout(LayoutKind.Sequential)] struct Keyboard { public ushort Key, Scan; public uint Flags, Time; public UIntPtr Extra; }
 [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
 [StructLayout(LayoutKind.Explicit)] struct InputData { [FieldOffset(0)] public Keyboard Keyboard; [FieldOffset(0)] public Mouse Mouse; }
 [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public InputData Data; }
 [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, Input[] inputs, int size);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
 [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
 [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
 [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder value, int bytes, out int required);
 static string Name(IntPtr desktop) {
  if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
  var value = new StringBuilder(256); int required;
  if (!GetUserObjectInformationW(desktop, 2, value, 512, out required)) throw new Win32Exception(Marshal.GetLastWin32Error());
  return value.ToString();
 }
 public static string ThreadDesktopName() { return Name(GetThreadDesktop(GetCurrentThreadId())); }
 public static string InputDesktopName() {
  var desktop = OpenInputDesktop(0, false, 1);
  try { return Name(desktop); } finally { if (desktop != IntPtr.Zero) CloseDesktop(desktop); }
 }
 public static void Escape() {
  var inputs = new[] {
   new Input { Type=1, Data=new InputData { Keyboard=new Keyboard { Key=27 } } },
   new Input { Type=1, Data=new InputData { Keyboard=new Keyboard { Key=27, Flags=2 } } }
  };
  var accepted=SendInput(2, inputs, Marshal.SizeOf(typeof(Input)));
  if (accepted != 2) throw new Win32Exception(Marshal.GetLastWin32Error(), "Hosted Escape accepted " + accepted + " of 2 input events.");
 }
}
'@
}
function Invoke-HostedControl($Control) {
    $Pattern = $null
    if ($Control.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$Pattern)) { $Pattern.Invoke(); return }
    if ($Control.TryGetCurrentPattern([Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$Pattern)) { $Pattern.DoDefaultAction(); return }
    if ($Control.Current.NativeWindowHandle -ne 0) {
        [HostedDesktopNative]::SendMessageW([IntPtr]::new($Control.Current.NativeWindowHandle), 0xF5, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        return
    }
    throw 'The observed hosted setup button exposes no supported invocation.'
}
$Evidence = Join-Path $env:RUNNER_TEMP ('ShouBuild/evidence/hosted-desktop-' + [Guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path $Evidence) -Force | Out-Null
$Actions = [Collections.Generic.List[object]]::new()
$LastControls = @(); $ObservedWindows = @{}; $Failure = $null; $Desktop = $null
$Deadline = [DateTime]::UtcNow.AddSeconds(45)
$QuietSince = [DateTime]::UtcNow
try {
    $Desktop = [ordered]@{ thread=[HostedDesktopNative]::ThreadDesktopName(); input=[HostedDesktopNative]::InputDesktopName() }
    if ($Desktop.thread -ne 'Default' -or $Desktop.input -ne $Desktop.thread) {
        throw "Hosted UI requires the Default input desktop; thread=$($Desktop.thread), input=$($Desktop.input)."
    }
    do {
        $PrivacyWindow = $null
        $Candidates = [Collections.Generic.List[Windows.Automation.AutomationElement]]::new()
        $Foreground = [HostedDesktopNative]::GetForegroundWindow()
        if ($Foreground -ne [IntPtr]::Zero) { $Candidates.Add([Windows.Automation.AutomationElement]::FromHandle($Foreground)) }
        foreach ($Child in @([Windows.Automation.AutomationElement]::RootElement.FindAll(
            [Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition))) { $Candidates.Add($Child) }
        foreach ($Candidate in $Candidates) {
            if ($null -eq $Candidate) { continue }
            try { $Information = $Candidate.Current } catch [Windows.Automation.ElementNotAvailableException] { continue }
            if ($null -eq $Information -or [int]$Information.ProcessId -le 0) { continue }
            $Owner = Get-Process -Id $Information.ProcessId -ErrorAction SilentlyContinue
            if ($null -eq $Owner -or $Owner.SessionId -ne $Session -or -not $Owner.Path) { continue }
            if (-not $Owner.Path.StartsWith($HostedWindowsRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $CandidateControls = @($Candidate.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition))
            $ObservedWindows["$($Owner.Id):$($Candidate.Current.NativeWindowHandle)"] = [ordered]@{ process=$Owner.ProcessName; path=$Owner.Path; name=$Candidate.Current.Name;
                controls=@($CandidateControls | Select-Object -First 300 | ForEach-Object {
                    [ordered]@{ id=$_.Current.AutomationId; name=$_.Current.Name; offscreen=$_.Current.IsOffscreen; type=[string]$_.Current.ControlType }
                }) }
            if ([StringComparer]::OrdinalIgnoreCase.Equals($Owner.Path, (Join-Path $env:WINDIR 'SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe')) -and
                $Information.NativeWindowHandle -eq [HostedDesktopNative]::GetForegroundWindow().ToInt64()) {
                # This hidden accessibility command is the shell's explicit close
                # action, observed in the foreground Start menu's own UIA tree.
                $CloseStart = $CandidateControls | Where-Object { $_.Current.AutomationId -eq 'CloseStartAccessibleButton' -and
                    $_.Current.Name -eq 'Close Start menu' -and $_.Current.IsEnabled } | Select-Object -First 1
                if ($null -ne $CloseStart) {
                    if ([HostedDesktopNative]::InputDesktopName() -ne $Desktop.thread) { throw 'The hosted input desktop changed before closing Start.' }
                    [HostedDesktopNative]::Escape()
                    $Actions.Add([ordered]@{ action='escape_observed_start_menu'; process=$Owner.ProcessName })
                    $QuietSince = [DateTime]::UtcNow
                    break
                }
            }
            if ([StringComparer]::OrdinalIgnoreCase.Equals($Owner.Path, (Join-Path $env:WINDIR 'System32\SystemPropertiesPerformance.exe')) -and
                @($CandidateControls | Where-Object { $_.Current.Name -like 'Windows created a temporary paging file on your computer because of a problem*' }).Count -gt 0) {
                $Ok = $CandidateControls | Where-Object { $_.Current.Name -eq 'OK' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen } | Select-Object -First 1
                if ($null -eq $Ok) { throw 'The observed temporary paging-file notice has no enabled OK button.' }
                Invoke-HostedControl $Ok
                $Actions.Add([ordered]@{ action='dismiss_temporary_paging_file_notice'; process=$Owner.ProcessName })
                $QuietSince = [DateTime]::UtcNow
                break
            }
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
                [ordered]@{ id=$_.Current.AutomationId; name=$_.Current.Name; offscreen=$_.Current.IsOffscreen; type=[string]$_.Current.ControlType }
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
            Invoke-HostedControl $Button
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $Deadline)
    if (([DateTime]::UtcNow - $QuietSince).TotalSeconds -lt 10) { throw 'Hosted privacy setup did not finish before its deadline.' }
} catch { $Failure = $_.Exception.ToString(); throw }
finally {
    [ordered]@{ passed=($null -eq $Failure); failure=$Failure; actions=$Actions.ToArray(); last_controls=$LastControls;
        observed_windows=@($ObservedWindows.Values); session=$Session; desktop=$Desktop } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Evidence -Encoding utf8
    Write-Output "Hosted desktop receipt: $Evidence"
}
