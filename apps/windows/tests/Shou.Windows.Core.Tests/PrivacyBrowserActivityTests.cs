using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class PrivacyBrowserActivityTests
{
    private sealed class Processes(ProcessInventory result, Exception? error = null) : IProcessInventory
    {
        public ImmutableArray<string> Names;
        public Task<ProcessInventory> InspectAsync(ImmutableArray<string> executableNames, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); Names = executableNames; if (error is not null) throw error; return Task.FromResult(result); }
    }
    [Theory]
    [InlineData(PrivacyBrowser.Chrome, "chrome.exe")]
    [InlineData(PrivacyBrowser.Chromium, "chrome.exe")]
    [InlineData(PrivacyBrowser.Edge, "msedge.exe")]
    [InlineData(PrivacyBrowser.Brave, "brave.exe")]
    [InlineData(PrivacyBrowser.Firefox, "firefox.exe")]
    public async Task KnownExecutableNamesAreConservativeAndCaseInsensitive(PrivacyBrowser browser, string name)
    {
        var processes = new Processes(new(false, [new(1, name.ToUpperInvariant())]));
        Assert.Equal(ActivityState.Active, (await new PrivacyBrowserActivity(processes).InspectAsync(browser, default)).State);
        Assert.Equal(name, Assert.Single(processes.Names));
        Assert.Equal(ActivityState.Idle, (await new PrivacyBrowserActivity(new Processes(new(true, [new(1, name, Exited: true)]))).InspectAsync(browser, default)).State);
    }
    [Theory]
    [InlineData("incomplete")]
    [InlineData("default")]
    [InlineData("duplicate")]
    [InlineData("invalid_name")]
    [InlineData("null_process")]
    [InlineData("read_error")]
    public async Task UnknownOrInvalidProcessObservationsNeverImplyIdle(string kind)
    {
        var result = kind switch
        {
            "default" => new ProcessInventory(true, default), "duplicate" => new(true, [new(1, "other.exe"), new(1, "other.exe")]),
            "invalid_name" => new(true, [new(1, "C:/chrome.exe")]), "null_process" => new(true, [null!]), _ => new(false, [])
        };
        var activity = new PrivacyBrowserActivity(new Processes(result, kind == "read_error" ? new IOException("private") : null));
        Assert.Equal(ActivityState.Unknown, (await activity.InspectAsync(PrivacyBrowser.Chrome, default)).State);
    }
}
