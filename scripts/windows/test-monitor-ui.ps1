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
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct IconData {
  public uint Size; public IntPtr Window; public uint Id, Flags, CallbackMessage; public IntPtr Icon;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Tip;
  public uint State, StateMask;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Info;
  public uint Version;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string InfoTitle;
  public uint InfoFlags; public Guid Guid; public IntPtr BalloonIcon;
 }
 [DllImport("shell32.dll")] public static extern int Shell_NotifyIconGetRect(ref IconId id, out Rect rect);
 [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool Shell_NotifyIconW(uint command, ref IconData data);
 [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateWindowExW(uint extended, string className, string name, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
 [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr window);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr LoadIconW(IntPtr instance, IntPtr id);
 [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr LoadImageW(IntPtr instance, string path, uint type, int width, int height, uint flags);
 [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr window, int x, int y, int width, int height, bool repaint);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
 [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect bounds);
 [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window, uint flags);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr window, System.Text.StringBuilder name, int capacity);
 [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window, uint attribute, out int value, int size);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll", SetLastError=true)] static extern bool AttachThreadInput(uint from, uint to, bool attach);
 [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }
 [StructLayout(LayoutKind.Sequential)] struct Message { public IntPtr Window; public uint Id; public UIntPtr Wparam; public IntPtr Lparam; public uint Time; public Point Point; public uint Private; }
 [DllImport("user32.dll")] static extern bool PeekMessageW(out Message message, IntPtr window, uint min, uint max, uint remove);
 public sealed class Activation {
  public uint CurrentThread, ForegroundThread, TargetThread;
  public bool AttachedForeground, AttachedTarget, Activated;
  public int ForegroundError, TargetError;
 }
 public static Activation Activate(IntPtr window) {
  Message message;
  PeekMessageW(out message, IntPtr.Zero, 0, 0, 0); // Ensure this automation thread has an input queue.
  uint ignored;
  var current=GetCurrentThreadId();
  var foreground=GetWindowThreadProcessId(GetForegroundWindow(), out ignored);
  var target=GetWindowThreadProcessId(window, out ignored);
  var result=new Activation { CurrentThread=current, ForegroundThread=foreground, TargetThread=target };
  var attachForeground=foreground != 0 && foreground != current && AttachThreadInput(current, foreground, true);
  result.AttachedForeground=attachForeground;
  if (foreground != 0 && foreground != current && !attachForeground) result.ForegroundError=Marshal.GetLastWin32Error();
  var attachTarget=target != 0 && target != current && target != foreground && AttachThreadInput(current, target, true);
  result.AttachedTarget=attachTarget;
  if (target != 0 && target != current && target != foreground && !attachTarget) result.TargetError=Marshal.GetLastWin32Error();
  try { result.Activated=SetForegroundWindow(window); return result; }
  finally {
   if (attachTarget) AttachThreadInput(current, target, false);
   if (attachForeground) AttachThreadInput(current, foreground, false);
  }
 }
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string className, string name);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
 [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
 [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint item, System.Text.StringBuilder text, int capacity, uint flags);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr window, System.Text.StringBuilder text, int capacity);
 [DllImport("user32.dll")] public static extern bool GetMenuItemRect(IntPtr window, IntPtr menu, uint item, out Rect rect);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
}
'@
$Output = Join-Path $ArtifactsRoot ('monitor-ui-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$Checks = [Collections.Generic.List[string]]::new()
$App = $null; $Window = $null; $Failure = $null; $ForegroundEvidence = $null; $Icon = [MonitorUiNative+IconId]::new()
$ShellBefore = [IntPtr]::Zero; $ShellAfter = [IntPtr]::Zero; $ShellStarted = $false
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
function Save-NotificationProbe {
    $Fixture = [MonitorUiNative]::CreateWindowExW(0, 'STATIC', 'Shou notification fixture', 0, 0, 0, 0, 0, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    $SystemIcon = [MonitorUiNative]::LoadIconW([IntPtr]::Zero, [IntPtr]::new(32512))
    $FileIcon = [MonitorUiNative]::LoadImageW([IntPtr]::Zero, (Join-Path $PublishRoot 'app/Shou.ico'), 1, 32, 32, 0x10)
    $Results = @()
    try {
        foreach ($Owner in @([ordered]@{ name='fixture'; handle=$Fixture }, [ordered]@{ name='app'; handle=$Icon.Window })) {
            foreach ($Image in @([ordered]@{ name='system'; handle=$SystemIcon }, [ordered]@{ name='app'; handle=$FileIcon })) {
                foreach ($Size in @([Runtime.InteropServices.Marshal]::SizeOf([MonitorUiNative+IconData]::new()), 952)) {
                    $Data = [MonitorUiNative+IconData]::new()
                    $Data.Size=$Size; $Data.Window=$Owner.handle; $Data.Id=72; $Data.Flags=7; $Data.CallbackMessage=0x8048; $Data.Icon=$Image.handle
                    $Data.Tip='Shou notification fixture'; $Data.Info=''; $Data.InfoTitle=''
                    $Added = [MonitorUiNative]::Shell_NotifyIconW(0, [ref]$Data)
                    $NativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    $Results += [ordered]@{ owner=$Owner.name; icon=$Image.name; size=$Size; owner_valid=($Owner.handle -ne [IntPtr]::Zero); icon_valid=($Image.handle -ne [IntPtr]::Zero); added=$Added; error=$NativeError }
                    [MonitorUiNative]::Shell_NotifyIconW(2, [ref]$Data) | Out-Null
                }
            }
        }
    } finally {
        if ($FileIcon -ne [IntPtr]::Zero) { [MonitorUiNative]::DestroyIcon($FileIcon) | Out-Null }
        if ($Fixture -ne [IntPtr]::Zero) { [MonitorUiNative]::DestroyWindow($Fixture) | Out-Null }
        $Results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Output 'notification-probe.json') -Encoding utf8
    }
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
function Save-WindowState([string]$Name, $Activation = $null) {
    $Foreground = [MonitorUiNative]::GetForegroundWindow()
    $OwnerId = [uint32]0
    [MonitorUiNative]::GetWindowThreadProcessId($Foreground, [ref]$OwnerId) | Out-Null
    $Owner = if ($OwnerId -gt 0) { Get-Process -Id $OwnerId -ErrorAction SilentlyContinue }
    $Class = [Text.StringBuilder]::new(256)
    [MonitorUiNative]::GetClassNameW($Handle, $Class, $Class.Capacity) | Out-Null
    $Bounds = [MonitorUiNative+Rect]::new()
    [MonitorUiNative]::GetWindowRect($Handle, [ref]$Bounds) | Out-Null
    $Cloaked = 0
    $CloakResult = [MonitorUiNative]::DwmGetWindowAttribute($Handle, 14, [ref]$Cloaked, 4)
    [ordered]@{ activation=$Activation; window=$Handle.ToInt64(); app_process=$App.Id; class=$Class.ToString();
        visible=[MonitorUiNative]::IsWindowVisible($Handle); minimized=[MonitorUiNative]::IsIconic($Handle);
        hung=[MonitorUiNative]::IsHungAppWindow($Handle); cloak_result=$CloakResult; cloaked=$Cloaked;
        style=[MonitorUiNative]::GetWindowLongPtrW($Handle,-16).ToInt64(); extended_style=[MonitorUiNative]::GetWindowLongPtrW($Handle,-20).ToInt64();
        root_owner=[MonitorUiNative]::GetAncestor($Handle,3).ToInt64(); bounds=$Bounds;
        foreground=$Foreground.ToInt64(); foreground_process=$OwnerId; foreground_name=$(if ($null -ne $Owner) { $Owner.ProcessName }) } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Output ($Name + '-native.json')) -Encoding utf8
}
try {
    $ShellBefore = [MonitorUiNative]::FindWindowExW([IntPtr]::Zero, [IntPtr]::Zero, 'Shell_TrayWnd', $null)
    # A fresh hosted image can have an interactive desktop without Explorer's notification area.
    # Initialize only that disposable test desktop; ordinary developer/user sessions are unchanged.
    if ($ShellBefore -eq [IntPtr]::Zero -and $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted') {
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') | Out-Null
        $ShellStarted = $true
    }
    $ShellAfter = Wait-Monitor {
        $Handle = [MonitorUiNative]::FindWindowExW([IntPtr]::Zero, [IntPtr]::Zero, 'Shell_TrayWnd', $null)
        if ($Handle -ne [IntPtr]::Zero) { $Handle }
    } 'Explorer notification area on the test desktop'
    $Executable = Join-Path (Resolve-Path -LiteralPath $PublishRoot).Path 'app/Shou.Windows.App.exe'
    $App = Start-Process -FilePath $Executable -ArgumentList '--page monitor' -PassThru
    $Handle = Wait-Monitor { $App.Refresh(); if ($App.MainWindowHandle -ne [IntPtr]::Zero) { $App.MainWindowHandle } } 'monitor window'
    $Window = [Windows.Automation.AutomationElement]::FromHandle($Handle)
    $Activated = [MonitorUiNative]::Activate($Handle)
    Save-WindowState '00-activation' $Activated
    if ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted') {
        # The first visible application can trigger deferred Windows privacy setup.
        & (Join-Path $PSScriptRoot 'prepare-hosted-desktop.ps1')
    }
    $Activated = [MonitorUiNative]::Activate($Handle)
    Save-WindowState '00-prepared-activation' $Activated
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
    Save-WindowState '02-before-popup'
    [MonitorUiNative]::PostMessageW($Handle, 0x8047, [UIntPtr]::new(71), [IntPtr]::new(0x205)) | Out-Null
    $Popup = Wait-Monitor {
        # Win32 popup menus can appear under the owner rather than as UIA root children.
        $Popup = [IntPtr]::Zero
        do {
            $Popup = [MonitorUiNative]::FindWindowExW([IntPtr]::Zero, $Popup, '#32768', $null)
            if ($Popup -ne [IntPtr]::Zero) {
                $OwnerProcess = [uint32]0
                [MonitorUiNative]::GetWindowThreadProcessId($Popup, [ref]$OwnerProcess) | Out-Null
                if ($OwnerProcess -eq $App.Id) { return $Popup }
            }
        } while ($Popup -ne [IntPtr]::Zero)
    } 'native tray popup'
    $NativeMenu = Wait-Monitor {
        $MenuHandle = [MonitorUiNative]::SendMessageW($Popup, 0x01E1, [UIntPtr]::Zero, [IntPtr]::Zero)
        if ($MenuHandle -ne [IntPtr]::Zero -and [MonitorUiNative]::GetMenuItemCount($MenuHandle) -gt 0) { return $MenuHandle }
    } 'populated native menu'
    $Labels = @(for ($Index=0; $Index -lt [MonitorUiNative]::GetMenuItemCount($NativeMenu); $Index++) {
        $Label = [Text.StringBuilder]::new(1024)
        [MonitorUiNative]::GetMenuStringW($NativeMenu, [uint32]$Index, $Label, $Label.Capacity, 0x400) | Out-Null
        $Label.ToString()
    })
    $Labels | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Output '02-tray-menu.json') -Encoding utf8
    if (($Labels -join ' ') -notmatch 'CPU.*GPU') { throw 'Tray menu is missing resource readings.' }
    $ResumeIndex = -1
    for ($Index=0; $Index -lt $Labels.Count; $Index++) {
        if ($Labels[$Index] -match 'Resume Monitoring|\u7ee7\u7eed\u76d1\u63a7') { $ResumeIndex=$Index; break }
    }
    if ($ResumeIndex -lt 0) { throw 'Tray menu is missing resume.' }
    Save-Monitor '02-tray-popup'
    # Click the observed command rectangle only while this fixture owns the foreground popup.
    $ForegroundWindow = [MonitorUiNative]::GetForegroundWindow()
    $ForegroundProcess = [uint32]0
    [MonitorUiNative]::GetWindowThreadProcessId($ForegroundWindow, [ref]$ForegroundProcess) | Out-Null
    $ForegroundTitle = [Text.StringBuilder]::new(1024)
    [MonitorUiNative]::GetWindowTextW($ForegroundWindow, $ForegroundTitle, $ForegroundTitle.Capacity) | Out-Null
    $ForegroundOwner = Get-Process -Id $ForegroundProcess -ErrorAction SilentlyContinue
    $ForegroundEvidence = [ordered]@{ id=$ForegroundProcess; name=$(if ($null -ne $ForegroundOwner) { $ForegroundOwner.ProcessName });
        path=$(if ($null -ne $ForegroundOwner) { $ForegroundOwner.Path }); title=$ForegroundTitle.ToString() }
    $ForegroundEvidence | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Output '02-foreground.json') -Encoding utf8
    if ($ForegroundProcess -ne $App.Id) { throw 'The fixture lost foreground ownership before menu navigation.' }
    $CommandBounds = [MonitorUiNative+Rect]::new()
    if (-not [MonitorUiNative]::GetMenuItemRect([IntPtr]::Zero, $NativeMenu, [uint32]$ResumeIndex, [ref]$CommandBounds) -or
        $CommandBounds.Right -le $CommandBounds.Left -or $CommandBounds.Bottom -le $CommandBounds.Top) { throw 'Resume command has no usable native bounds.' }
    if (-not [MonitorUiNative]::SetCursorPos([int](($CommandBounds.Left+$CommandBounds.Right)/2), [int](($CommandBounds.Top+$CommandBounds.Bottom)/2))) { throw 'Could not target the observed resume command.' }
    [MonitorUiNative]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [MonitorUiNative]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
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
} catch {
    $Failure = $_.Exception.ToString()
    if ($null -ne $Window) { try { Save-WindowState 'failure' } catch {} }
    if ($null -ne $Window) { try { Save-Monitor 'failure' } catch {}; try { Save-NotificationProbe } catch { $_ | Out-String | Set-Content -LiteralPath (Join-Path $Output 'notification-probe-error.txt') } }
    throw
}
finally {
    if ($null -ne $App -and -not $App.HasExited) { $App.CloseMainWindow() | Out-Null }
    [ordered]@{ source=(git rev-parse HEAD); architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();
        os=[Environment]::OSVersion.VersionString; passed=($null -eq $Failure); checks=@($Checks); failure=$Failure; foreground=$ForegroundEvidence;
        shell_present_before=($ShellBefore -ne [IntPtr]::Zero); hosted_shell_started=$ShellStarted; shell_present_after=($ShellAfter -ne [IntPtr]::Zero);
        scope='Automated read-only monitor UI and native notification menu, not full desktop E2E or signed installation.' } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Output 'verification.json') -Encoding utf8
}
