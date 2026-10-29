using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

internal sealed record WindowsAuthorizationPeer(int Pid, long Started, string Executable, string Sid, string Home, bool Elevated)
{
    internal static WindowsAuthorizationPeer Read(int pid)
    {
        using var process = Process.GetProcessById(pid);
        using var handle = OpenProcess(0x1000, false, pid);
        var path = new StringBuilder(32768); var length = path.Capacity;
        if (handle.IsInvalid || !QueryFullProcessImageName(handle, 0, path, ref length) || !OpenProcessToken(handle, 8, out var token)) throw Failure();
        using (token)
        using (var identity = new WindowsIdentity(token.DangerousGetHandle()))
        {
            var home = new StringBuilder(32768); var homeLength = home.Capacity;
            if (!GetUserProfileDirectory(token, home, ref homeLength) || !GetTokenInformation(token, 20, out var elevated, 4, out _) || identity.User is null) throw Failure();
            return new(pid, process.StartTime.ToUniversalTime().Ticks, path.ToString(), identity.User.Value, home.ToString(), elevated != 0);
        }
    }
    internal bool IsCurrent
    {
        get { try { return this == Read(Pid); } catch (Exception error) when (error is Win32Exception or InvalidOperationException or ArgumentException or ShouException) { return false; } }
    }
    internal static uint PipePeer(SafePipeHandle pipe, bool client)
    {
        var success = client ? GetNamedPipeClientProcessId(pipe, out var pid) : GetNamedPipeServerProcessId(pipe, out pid);
        return success ? pid : throw Failure();
    }
    private static ShouException Failure() => new("authorization_unavailable", "The administrator process identity could not be verified.");
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, StringBuilder path, ref int size);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int kind, out int value, int length, out int returned);
    [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool GetUserProfileDirectory(SafeAccessTokenHandle token, StringBuilder path, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
}
