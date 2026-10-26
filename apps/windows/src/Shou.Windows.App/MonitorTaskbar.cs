using System.Runtime.InteropServices;
using System.Text;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

/// <summary>Native user tasks also work in the unpackaged portable app.</summary>
internal static class MonitorTaskbar
{
    private const string AppId = "LimeCloud.Shou.Desktop";
    public static void InitializeIdentity()
    {
        try { Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(AppId)); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }

    public static void Prepare()
    {
        using var diagnostic = Shou.Windows.Core.OperationDiagnostics.Start("monitor.taskbar.prepare");
        object? destination = null, collection = null, task = null, removed = null;
        var begun = false;
        try
        {
            var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Desktop executable unavailable.");
            destination = Create("77f10cf0-3db5-4966-b520-b7c54fd35ed6");
            var list = (IDestinationList)destination;
            list.SetAppID(AppId);
            var arrayId = typeof(IObjectArray).GUID;
            list.BeginList(out _, ref arrayId, out removed); begun = true;
            task = Create("00021401-0000-0000-c000-000000000046");
            var link = (IShellLink)task;
            link.SetPath(executable); link.SetArguments("--page monitor");
            link.SetWorkingDirectory(AppContext.BaseDirectory);
            link.SetIconLocation(System.IO.Path.Combine(AppContext.BaseDirectory, "Shou.ico"), 0);
            var title = new TextCatalog().Get("Open System Monitor"); link.SetDescription(title);
            var store = (IPropertyStore)task;
            var key = new PropertyKey { Format = new("f29f85e0-4ff9-1068-ab91-08002b27b3d9"), Id = 2 };
            var value = new PropertyValue { Type = 31, Text = Marshal.StringToCoTaskMemUni(title) };
            try { store.SetValue(ref key, ref value); store.Commit(); }
            finally { Marshal.FreeCoTaskMem(value.Text); }
            collection = Create("2d3468c1-36a7-43b6-ac24-d3f02fd9607a");
            ((IObjectCollection)collection).AddObject(task);
            list.AddUserTasks((IObjectArray)collection); list.CommitList(); begun = false;
            diagnostic.Complete("registered");
        }
        catch (Exception error)
        {
            if (begun && destination is IDestinationList list) { try { list.AbortList(); } catch { } }
            diagnostic.Fail(error); NativeDiagnostics.Write(error);
        }
        finally
        {
            foreach (var value in new[] { removed, collection, task, destination })
                if (value is not null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
        }
    }

    private static object Create(string clsid) => Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid(clsid), throwOnError: true)!)!;
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    [StructLayout(LayoutKind.Sequential)] private struct PropertyKey { public Guid Format; public uint Id; }
    // PROPVARIANT is 24 bytes on both supported 64-bit architectures; VT_LPWSTR owns one pointer.
    [StructLayout(LayoutKind.Explicit, Size = 24)] private struct PropertyValue
    { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public nint Text; }

    [ComImport, Guid("6332debf-87b5-4670-90c0-5e57b408a49e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDestinationList
    {
        void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string id);
        void BeginList(out uint slots, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object removed);
        void AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string category, IObjectArray items);
        void AppendKnownCategory(int category);
        void AddUserTasks(IObjectArray items);
        void CommitList();
        void GetRemovedDestinations(ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object removed);
        void DeleteList([MarshalAs(UnmanagedType.LPWStr)] string id);
        void AbortList();
    }
    [ComImport, Guid("92ca9dcd-5622-4bba-a805-5e9f541bd8c9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IObjectArray
    {
        void GetCount(out uint count);
        void GetAt(uint index, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object value);
    }
    [ComImport, Guid("5632b1a4-e38a-400a-928a-d4cd63230295"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IObjectCollection
    {
        void GetCount(out uint count);
        void GetAt(uint index, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object value);
        void AddObject([MarshalAs(UnmanagedType.IUnknown)] object value);
        void AddFromArray(IObjectArray items);
        void RemoveObjectAt(uint index);
        void Clear();
    }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropertyValue value);
        void SetValue(ref PropertyKey key, ref PropertyValue value);
        void Commit();
    }
    [ComImport, Guid("000214f9-0000-0000-c000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLink
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, nint findData, uint flags);
        void GetIDList(out nint value);
        void SetIDList(nint value);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetHotkey(out ushort value);
        void SetHotkey(ushort value);
        void GetShowCmd(out int value);
        void SetShowCmd(int value);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string value, uint reserved);
        void Resolve(nint window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string value);
    }
}
