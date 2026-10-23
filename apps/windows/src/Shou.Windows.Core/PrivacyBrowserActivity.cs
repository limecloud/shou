namespace Shou.Windows.Core;

/// <summary>Conservative known executable-name observation; it does not terminate a browser or prove exclusive database use.</summary>
public sealed class PrivacyBrowserActivity(IProcessInventory processes) : IPrivacyBrowserActivity
{
    public async Task<ActivityObservation> InspectAsync(PrivacyBrowser browser, CancellationToken cancellationToken)
    {
        var name = browser switch
        {
            PrivacyBrowser.Chrome or PrivacyBrowser.Chromium => "chrome.exe", PrivacyBrowser.Edge => "msedge.exe",
            PrivacyBrowser.Brave => "brave.exe", PrivacyBrowser.Firefox => "firefox.exe", _ => throw new ShouException("invalid_argument", "Choose a known browser.")
        };
        try
        {
            var result = await processes.InspectAsync([name], cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            if (result is null || result.Processes.IsDefault || result.Processes.Length > CleanupActivityService.MaximumProcesses ||
                result.Processes.Any(process => process is null || process.ExecutableName is not { Length: > 0 and <= 260 } executable ||
                    executable.Any(character => char.IsControl(character) || character is '/' or '\\' or ':')) ||
                result.Processes.Select(process => process.ProcessId).Distinct().Count() != result.Processes.Length) return Unknown();
            if (result.Processes.Any(process => !process.Exited && string.Equals(process.ExecutableName, name, StringComparison.OrdinalIgnoreCase)))
                return new(ActivityState.Active, "privacy_browser_running");
            return result.Complete ? new(ActivityState.Idle) : Unknown();
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException) { return Unknown(); }
    }
    private static ActivityObservation Unknown() => new(ActivityState.Unknown, "privacy_activity_unavailable");
}
