using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;

namespace Shou.Windows;

/// <summary>A native child surface; preview providers run in the owned worker.</summary>
internal sealed class SystemPreviewSurface : HwndHost
{
    private readonly TaskCompletionSource<ulong> created = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<ulong> Created => created.Task;
    public event EventHandler? CloseRequested;
    protected override HandleRef BuildWindowCore(HandleRef parent)
    {
        var window = CreateWindowEx(0, "STATIC", "", 0x56010000, 0, 0, 1, 1, parent.Handle, nint.Zero, nint.Zero, nint.Zero);
        if (window == nint.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        created.TrySetResult(unchecked((ulong)window)); return new HandleRef(this, window);
    }
    protected override void DestroyWindowCore(HandleRef window) => DestroyWindow(window.Handle);
    protected override bool TabIntoCore(TraversalRequest request)
    {
        var child = FindWindowEx(Handle, nint.Zero, "ShouSystemPreviewSurface", null);
        if (child == nint.Zero) return false;
        PostMessage(child, 0x8000 + 73, nint.Zero, nint.Zero); return true;
    }
    protected override nint WndProc(nint window, int message, nint wparam, nint lparam, ref bool handled)
    {
        if (message == 0x8000 + 71) {
            handled = true;
            Dispatcher.BeginInvoke(() => MoveFocus(new TraversalRequest(wparam != nint.Zero ? FocusNavigationDirection.Previous : FocusNavigationDirection.Next)));
            return nint.Zero;
        }
        else if (message == 0x8000 + 72) { handled = true; Dispatcher.BeginInvoke(() => CloseRequested?.Invoke(this, EventArgs.Empty)); return nint.Zero; }
        return base.WndProc(window, message, wparam, lparam, ref handled);
    }
    [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowEx(uint extended, string type, string name, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyWindow(nint window);
    [DllImport("user32.dll", EntryPoint = "FindWindowExW", CharSet = CharSet.Unicode)] private static extern nint FindWindowEx(nint parent, nint after, string type, string? title);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessage(nint window, int message, nint wparam, nint lparam);
}
