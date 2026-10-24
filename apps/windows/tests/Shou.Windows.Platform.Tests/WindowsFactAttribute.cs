namespace Shou.Windows.Platform.Tests;

public sealed class WindowsFactAttribute : FactAttribute
{
    public WindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) Skip = "Requires native Windows 11; host compilation is not native acceptance.";
        // xUnit 2 only supports Fact.Timeout on async methods. Native operations
        // retain their own budgets; the workflow also bounds the complete job.
    }
}
