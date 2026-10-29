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
$Session = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($Session -eq 0) { throw 'Hosted UI requires the authenticated interactive session.' }
foreach ($Policy in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE', 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\OOBE')) {
    New-Item -Path $Policy -Force | Out-Null
    New-ItemProperty -Path $Policy -Name DisablePrivacyExperience -Value 1 -PropertyType DWord -Force | Out-Null
}
$PrivacyState = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'
New-Item -Path $PrivacyState -Force | Out-Null
New-ItemProperty -Path $PrivacyState -Name PrivacyConsentStatus -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $PrivacyState -Name TailoredExperiencesWithDiagnosticDataEnabled -Value 0 -PropertyType DWord -Force | Out-Null
if (-not ('HostedDesktopSession' -as [type])) {
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class HostedDesktopSession {
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
 [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
 [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
 [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
 [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder value, int bytes, out int required);
 [DllImport("wtsapi32.dll", SetLastError=true)] static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int field, out IntPtr buffer, out int bytes);
 [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
 static string Name(IntPtr desktop) {
  if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
  var value = new StringBuilder(256); int required;
  if (!GetUserObjectInformationW(desktop, 2, value, 512, out required)) throw new Win32Exception(Marshal.GetLastWin32Error());
  return value.ToString();
 }
 public static string ThreadDesktopName() { return Name(GetThreadDesktop(GetCurrentThreadId())); }
 public static string InputDesktopName() {
  var desktop=OpenInputDesktop(0, false, 1);
  try { return Name(desktop); } finally { if (desktop != IntPtr.Zero) CloseDesktop(desktop); }
 }
 public static int Information(int session, int field) {
  IntPtr buffer; int bytes;
  if (!WTSQuerySessionInformationW(IntPtr.Zero, session, field, out buffer, out bytes)) throw new Win32Exception(Marshal.GetLastWin32Error());
  try {
   if (field == 16 && bytes >= 2) return Marshal.ReadInt16(buffer);
   if (field == 8 && bytes >= 4) return Marshal.ReadInt32(buffer);
   throw new InvalidOperationException("Unexpected hosted session metadata size.");
  } finally { WTSFreeMemory(buffer); }
 }
}
'@
}
function Get-HostedConnection {
    [ordered]@{ session=$Session; state=[HostedDesktopSession]::Information($Session,8);
        protocol=[HostedDesktopSession]::Information($Session,16); console=[HostedDesktopSession]::WTSGetActiveConsoleSessionId() }
}
$Evidence = Join-Path $env:RUNNER_TEMP ('ShouBuild/evidence/hosted-desktop-' + [Guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path $Evidence) -Force | Out-Null
$Before = $null; $After = $null; $Desktop = $null; $Failure = $null; $Transferred = $false
try {
    $Before = Get-HostedConnection
    # Reconnect only this disposable runner's own authenticated RDP/disconnected
    # session. Do not change credentials, UAC, other sessions or security desktops.
    if ($Before.state -eq 4 -or $Before.protocol -eq 2) {
        & (Join-Path $env:WINDIR 'System32\tscon.exe') "$Session" /dest:console
        if ($LASTEXITCODE -ne 0) { throw 'The hosted session could not reconnect to its console.' }
        $Transferred = $true
    }
    $After = Get-HostedConnection
    if ($After.state -ne 0) { throw "The hosted session is not active: $($After.state)." }
    $Desktop = [ordered]@{ thread=[HostedDesktopSession]::ThreadDesktopName(); input=[HostedDesktopSession]::InputDesktopName() }
    if ($Desktop.thread -ne 'Default' -or $Desktop.input -ne $Desktop.thread) {
        throw "Hosted UI requires the Default input desktop; thread=$($Desktop.thread), input=$($Desktop.input)."
    }
    if ($RestartExplorer) {
        $ExplorerPath = Join-Path $env:WINDIR 'explorer.exe'
        foreach ($Process in @(Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            if ($Process.SessionId -eq $Session -and [StringComparer]::OrdinalIgnoreCase.Equals($Process.Path, $ExplorerPath)) {
                Stop-Process -InputObject $Process -Force -ErrorAction Stop
                if (-not $Process.WaitForExit(10000)) { throw 'Hosted-runner Explorer did not stop.' }
            }
        }
        Start-Process -FilePath $ExplorerPath | Out-Null
    }
} catch { $Failure = $_.Exception.ToString(); throw }
finally {
    [ordered]@{ passed=($null -eq $Failure); failure=$Failure; before=$Before; after=$After; desktop=$Desktop; transferred=$Transferred } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Evidence -Encoding utf8
    Write-Output "Hosted desktop receipt: $Evidence"
}
