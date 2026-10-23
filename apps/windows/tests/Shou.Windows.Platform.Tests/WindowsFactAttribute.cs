namespace Shou.Windows.Platform.Tests;

public sealed class WindowsFactAttribute : FactAttribute
{
    public WindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) Skip = "Requires native Windows 11; host compilation is not native acceptance.";
        Timeout = 30_000;
    }
}
