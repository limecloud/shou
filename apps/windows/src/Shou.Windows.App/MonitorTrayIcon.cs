using System.Runtime.InteropServices;

namespace Shou.Windows.App;

/// <summary>One opt-in notification icon owned by this window; closing the app always removes it.</summary>
internal sealed class MonitorTrayIcon : IDisposable
{
    private const uint Callback = 0x8000 + 71;
    private readonly nint window;
    private readonly SubclassProc callback;
    private readonly int attachError;
    private readonly Action open, pause, disable, quit;
    private readonly uint taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
    private nint icon;
    private bool attached, visible, enabled, disposed;
    private string summary = "Shou", openLabel = "", pauseLabel = "", disableLabel = "";
    private string quitLabel = "";
    private string[] details = [];
    public MonitorTrayIcon(nint window, Action open, Action pause, Action disable, Action quit)
    {
        this.window = window; this.open = open; this.pause = pause; this.disable = disable; this.quit = quit;
        callback = Handle; attached = SetWindowSubclass(window, callback, 71, 0);
        if (!attached) attachError = Marshal.GetLastWin32Error();
    }
    public bool Update(bool enabled, string summary, string openLabel, string pauseLabel, string disableLabel, string quitLabel, string[] details)
    {
        if (disposed) return !enabled;
        this.enabled = enabled; this.summary = summary; this.openLabel = openLabel; this.pauseLabel = pauseLabel; this.disableLabel = disableLabel;
        this.quitLabel = quitLabel; this.details = details;
        if (!enabled) { Remove(); return true; }
        if (!attached) { NativeFailure("monitor.tray.attach", attachError); return false; }
        if (icon == 0) icon = LoadImageW(0, System.IO.Path.Combine(AppContext.BaseDirectory, "Shou.ico"), 1, 32, 32, 0x10);
        if (icon == 0) { NativeFailure("monitor.tray.icon"); return false; }
        var data = Data(); var result = Shell_NotifyIconW(visible ? 1u : 0u, ref data);
        if (!result) NativeFailure("monitor.tray.register");
        visible = result; return result;
    }
    private static void NativeFailure(string stage, int? error = null) => Shou.Windows.Platform.NativeDiagnostics.Write(new System.ComponentModel.Win32Exception(error ?? Marshal.GetLastWin32Error()), stage);
    private NotifyData Data() => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyData>(), Window = window, Id = 71, Flags = 1 | 2 | 4, CallbackMessage = Callback, Icon = icon,
        Tip = summary.Length > 127 ? summary[..127] : summary, Info = "", InfoTitle = ""
    };
    private nint Handle(nint hwnd, uint message, nuint wparam, nint lparam, nuint id, nuint data)
    {
        if (!disposed && message == taskbarCreated && enabled) { visible = false; _ = Update(true, summary, openLabel, pauseLabel, disableLabel, quitLabel, details); }
        if (!disposed && message == Callback)
        {
            try
            {
                if ((uint)lparam == 0x203) open();
                else if ((uint)lparam is 0x202 or 0x205) ShowMenu();
            }
            catch (Exception error) { Shou.Windows.Platform.NativeDiagnostics.Write(error); }
            return 0;
        }
        return DefSubclassProc(hwnd, message, wparam, lparam);
    }
    private void ShowMenu()
    {
        var menu = CreatePopupMenu(); if (menu == 0) return;
        try
        {
            AppendMenuW(menu, 2, 0, summary); AppendMenuW(menu, 0x800, 0, "");
            foreach (var line in details) AppendMenuW(menu, 2, 0, line.Replace("&", "&&", StringComparison.Ordinal));
            AppendMenuW(menu, 0x800, 0, "");
            AppendMenuW(menu, 0, 1, openLabel); AppendMenuW(menu, 0, 2, pauseLabel); AppendMenuW(menu, 0, 3, disableLabel);
            AppendMenuW(menu, 0, 4, quitLabel);
            if (!GetCursorPos(out var point)) return;
            SetForegroundWindow(window);
            var command = TrackPopupMenu(menu, 0x100 | 2, point.X, point.Y, 0, window, 0);
            if (command == 1) open(); else if (command == 2) pause(); else if (command == 3) disable(); else if (command == 4) quit();
        }
        finally { DestroyMenu(menu); }
    }
    private void Remove() { if (!visible) return; var data = Data(); _ = Shell_NotifyIconW(2, ref data); visible = false; }
    public void Dispose()
    {
        if (disposed) return; disposed = true; Remove();
        if (attached) { _ = RemoveWindowSubclass(window, callback, 71); attached = false; }
        if (icon != 0) { DestroyIcon(icon); icon = 0; }
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate nint SubclassProc(nint hwnd, uint message, nuint wparam, nint lparam, nuint id, nuint data);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct NotifyData
    {
        public uint Size; public nint Window; public uint Id, Flags, CallbackMessage; public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Guid; public nint BalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [DllImport("comctl32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wparam, nint lparam);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Shell_NotifyIconW(uint message, ref NotifyData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint LoadImageW(nint instance, string path, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessageW(string message);
    [DllImport("user32.dll")] private static extern nint CreatePopupMenu();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AppendMenuW(nint menu, uint flags, nuint id, string label);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint window);
}
