using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class CleanupApplicationClosingTests
{
    private sealed class Closing : ICleanupApplicationClosing
    {
        public bool Available { get; set; } = true;
        public List<CleanupRunningApplication> Requests { get; } = [];
        public Task<CleanupApplicationUsers> InspectAsync(ImmutableArray<WindowsPath> files, CancellationToken token) =>
            Task.FromResult(new CleanupApplicationUsers([], true));
        public Task<CleanupApplicationCloseResult> RequestCloseAsync(CleanupRunningApplication application, CancellationToken token)
        { Requests.Add(application); return Task.FromResult(new CleanupApplicationCloseResult(application, "still_running")); }
    }
    private static CleanupRunningApplication App(int pid) => new(pid, 1000 + pid, WindowsPath.Parse($"C:/Generated/App{pid}.exe"), $"Fixture {pid}");

    [Fact]
    public async Task OnlySelectedObservedApplicationIsRequestedAndRefusalIsRetained()
    {
        var platform = new Closing(); var service = new CleanupApplicationClosingService(platform);
        var first = App(1); var second = App(2);
        var results = await service.CloseSelectedAsync(new([first, second], true), [second], CancellationToken.None);
        Assert.Equal([second], platform.Requests);
        Assert.Equal("still_running", Assert.Single(results).State);
    }

    [Fact]
    public async Task ForgedIdentityDuplicateSelectionCancellationAndNativeGateCannotRequestExit()
    {
        var platform = new Closing(); var service = new CleanupApplicationClosingService(platform); var app = App(1);
        var observed = new CleanupApplicationUsers([app], true);
        await Assert.ThrowsAsync<ShouException>(() => service.CloseSelectedAsync(observed, [app with { StartedUtcTicks = 999 }], CancellationToken.None));
        await Assert.ThrowsAsync<ShouException>(() => service.CloseSelectedAsync(observed, [app, app], CancellationToken.None));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.CloseSelectedAsync(observed, [app], new CancellationToken(true)));
        platform.Available = false;
        await Assert.ThrowsAsync<ShouException>(() => service.CloseSelectedAsync(observed, [app], CancellationToken.None));
        Assert.Empty(platform.Requests);
    }
}
