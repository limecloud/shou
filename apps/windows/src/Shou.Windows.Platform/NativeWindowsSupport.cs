using System.Runtime.InteropServices;

namespace Shou.Windows.Platform;

public static class NativeWindowsSupport
{
    public static bool IsSupported =>
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) &&
        Environment.Is64BitProcess &&
        Environment.Is64BitOperatingSystem &&
        RuntimeInformation.ProcessArchitecture == RuntimeInformation.OSArchitecture &&
        RuntimeInformation.ProcessArchitecture is Architecture.X64 or Architecture.Arm64;
}
