param([Parameter(Mandatory)][string]$PublishRoot, [Parameter(Mandatory)][string]$ArtifactsRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0 -or
    [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Monitor UI acceptance requires an interactive STA desktop.' }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MonitorUiNative {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct IconId { public uint Size; public IntPtr Window; public uint Id; public Guid Guid; }
 [DllImport("shell32.dll")] public static extern int Shell_NotifyIconGetRect(ref IconId id, out Rect rect);
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr window, int x, int y, int width, int height, bool repaint);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string className, string name);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
}
'@
$Output = Join-Path $ArtifactsRoot ('monitor-ui-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$Checks = [Collections.Generic.List[string]]::new()
$App = $null; $Window = $null; $Failure = $null; $Icon = [MonitorUiNative+IconId]::new()
function Wait-Monitor([scriptblock]$Condition, [string]$Description) {
    $Deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if ($null -ne $App -and $App.HasExited) { throw "App exited while waiting for $Description, exit=$($App.ExitCode)." }
        $Value = & $Condition
        if ($Value) { return $Value }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $Deadline)
    throw "Timed out waiting for $Description."
}
function Find-Monitor([string]$Id) {
    $Window.FindFirst([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id))
}
function Get-Monitor([string]$Id) { Wait-Monitor { Find-Monitor $Id } $Id }
function Invoke-Monitor([string]$Id) { (Get-Monitor $Id).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Toggle-Monitor { (Get-Monitor 'monitor.background').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle() }
function Get-IconResult {
    $Bounds = [MonitorUiNative+Rect]::new()
    [MonitorUiNative]::Shell_NotifyIconGetRect([ref]$Icon, [ref]$Bounds)
}
function Save-Monitor([string]$Name) {
    $Bounds = $Window.Current.BoundingRectangle
    $Bitmap = [Drawing.Bitmap]::new([int]$Bounds.Width, [int]$Bounds.Height)
    $Graphics = [Drawing.Graphics]::FromImage($Bitmap)
    try {
        $Graphics.CopyFromScreen([int]$Bounds.X, [int]$Bounds.Y, 0, 0, $Bitmap.Size)
        $Bitmap.Save((Join-Path $Output ($Name + '.png')), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $Graphics.Dispose(); $Bitmap.Dispose() }
    @($Window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
        [ordered]@{ id=$_.Current.AutomationId; name=$_.Current.Name; type=$_.Current.ControlType.ProgrammaticName; offscreen=$_.Current.IsOffscreen }
    }) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Output ($Name + '.json')) -Encoding utf8
}
try {
    $Executable = Join-Path (Resolve-Path -LiteralPath $PublishRoot).Path 'app/Shou.Windows.App.exe'
    $App = Start-Process -FilePath $Executable -ArgumentList '--page monitor' -PassThru
    $Handle = Wait-Monitor { $App.Refresh(); if ($App.MainWindowHandle -ne [IntPtr]::Zero) { $App.MainWindowHandle } } 'monitor window'
    $Window = [Windows.Automation.AutomationElement]::FromHandle($Handle)
    [MonitorUiNative]::SetForegroundWindow($Handle) | Out-Null
    $Icon.Size = [Runtime.InteropServices.Marshal]::SizeOf($Icon); $Icon.Window = $Handle; $Icon.Id = 71
    Wait-Monitor { $Status = Find-Monitor 'monitor.status'; $null -ne $Status -and $Status.Current.Name -match 'Live|\u5b9e\u65f6' } 'first observation' | Out-Null
    Start-Sleep -Seconds 3
    foreach ($Key in @('overview','cpu','gpu','memory','battery','diskRead','networkReceive','thermal')) { Get-Monitor ('monitor.metric.' + $Key) | Out-Null }
    Save-Monitor '01-live-panels'; $Checks.Add('eight live resource panels and process surface')
    $Field = (Get-Monitor 'monitor.process.search').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    $Field.SetValue('shou_monitor_no_match_' + [Guid]::NewGuid().ToString('N'))
    Wait-Monitor { (Get-Monitor 'monitor.coverage').Current.Name -match 'Showing 0 of 0|\u663e\u793a 0 \u9879\uff0c\u5171 0' } 'empty process search' | Out-Null
    $Field.SetValue(''); $Checks.Add('bounded process search and empty result')
    Invoke-Monitor 'monitor.pause'
    Wait-Monitor { (Get-Monitor 'monitor.status').Current.Name -match 'paused|\u6682\u505c' } 'paused status' | Out-Null
    $Frozen = (Get-Monitor 'monitor.status').Current.Name; Start-Sleep -Seconds 3
    if ((Get-Monitor 'monitor.status').Current.Name -ne $Frozen) { throw 'Paused monitor continued updating.' }
    Toggle-Monitor; Wait-Monitor { (Get-IconResult) -eq 0 } 'registered tray icon' | Out-Null
    [MonitorUiNative]::PostMessageW($Handle, 0x8047, [UIntPtr]::new(71), [IntPtr]::new(0x205)) | Out-Null
    $Menu = Wait-Monitor {
        # Win32 popup menus can appear under the owner rather than as UIA root children.
        $Popup = [IntPtr]::Zero
        do {
            $Popup = [MonitorUiNative]::FindWindowExW([IntPtr]::Zero, $Popup, '#32768', $null)
            if ($Popup -ne [IntPtr]::Zero) {
                $OwnerProcess = [uint32]0
                [MonitorUiNative]::GetWindowThreadProcessId($Popup, [ref]$OwnerProcess) | Out-Null
                if ($OwnerProcess -eq $App.Id) { return [Windows.Automation.AutomationElement]::FromHandle($Popup) }
            }
        } while ($Popup -ne [IntPtr]::Zero)
    } 'native tray popup'
    $Items = @($Menu.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition))
    $Labels = @($Items | ForEach-Object { $_.Current.Name })
    $Labels | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Output '02-tray-menu.json') -Encoding utf8
    if (($Labels -join ' ') -notmatch 'CPU.*GPU') { throw 'Tray menu is missing resource readings.' }
    $Resume = $Items | Where-Object { $_.Current.Name -match 'Resume Monitoring|\u7ee7\u7eed\u76d1\u63a7' } | Select-Object -First 1
    if ($null -eq $Resume) { throw 'Tray menu is missing resume.' }
    $Resume.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Monitor { (Get-Monitor 'monitor.status').Current.Name -match 'Live|\u5b9e\u65f6' } 'tray resume' | Out-Null
    $Checks.Add('native tray registration, resource menu and resume command')
    Toggle-Monitor; Wait-Monitor { (Get-IconResult) -ne 0 } 'tray icon removal' | Out-Null
    $Checks.Add('disable removes the native notification icon')
    Invoke-Monitor 'nav.settings'; Get-Monitor 'settings.theme' | Out-Null
    Invoke-Monitor 'nav.monitor'; Get-Monitor 'monitor.status' | Out-Null
    $Scale = [MonitorUiNative]::GetDpiForWindow($Handle) / 96.0
    [MonitorUiNative]::MoveWindow($Handle, 0, 0, [int](960*$Scale), [int](680*$Scale), $true) | Out-Null
    Start-Sleep -Milliseconds 700
    foreach ($Id in @('monitor.background','monitor.pause','nav.monitor')) { if ((Get-Monitor $Id).Current.IsOffscreen) { throw "Required command clipped at minimum size: $Id" } }
    Save-Monitor '03-minimum-window'; $Checks.Add('leave/return and minimum window commands')
    Toggle-Monitor; Wait-Monitor { (Get-IconResult) -eq 0 } 'tray before exit' | Out-Null
    $Window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
    if (-not $App.WaitForExit(15000) -or $App.ExitCode -ne 0) { throw 'Monitor failed normal close.' }
    if ((Get-IconResult) -eq 0) { throw 'Tray icon remained registered after app exit.' }
    $Checks.Add('normal exit releases the tray icon')
} catch { $Failure = $_.Exception.ToString(); if ($null -ne $Window) { try { Save-Monitor 'failure' } catch {} }; throw }
finally {
    if ($null -ne $App -and -not $App.HasExited) { $App.CloseMainWindow() | Out-Null }
    [ordered]@{ source=(git rev-parse HEAD); architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();
        os=[Environment]::OSVersion.VersionString; passed=($null -eq $Failure); checks=@($Checks); failure=$Failure;
        scope='Automated read-only monitor UI and native notification menu, not full desktop E2E or signed installation.' } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Output 'verification.json') -Encoding utf8
}
