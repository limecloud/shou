using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class ApplicationsViewModelTests
{
    private sealed class Reader : IApplicationInventory
    {
        public Queue<TaskCompletionSource<ApplicationInventory>> Calls { get; } = new();
        public List<CancellationToken> Tokens { get; } = [];
        public Task<ApplicationInventory> ReadAsync(ApplicationDiscoveryBudget budget, CancellationToken cancellationToken)
        {
            Tokens.Add(cancellationToken);
            var call = new TaskCompletionSource<ApplicationInventory>(TaskCreationOptions.RunContinuationsAsynchronously);
            Calls.Enqueue(call);
            return call.Task;
        }
    }
    private static ApplicationInventory Result(int count = 1, bool partial = false) => new(Enumerable.Range(0, count)
        .Select(index => new ApplicationRegistration(ApplicationSource.CurrentUserRegistry, "fixture_" + index, $"Example {index:D3}")).ToImmutableArray(),
        Enum.GetValues<ApplicationSource>().Select(source => new ApplicationSourceCoverage(source,
            partial && source == ApplicationSource.CurrentUserMsix ? ApplicationSourceState.Unavailable : ApplicationSourceState.Complete,
            source == ApplicationSource.CurrentUserRegistry ? count : 0, partial && source == ApplicationSource.CurrentUserMsix ? ["permission_denied"] : [])).ToImmutableArray());

    [Theory]
    [InlineData(false, ApplicationsPageState.Ready)]
    [InlineData(true, ApplicationsPageState.Partial)]
    public async Task PresentsRealSourceCoverage(bool partial, ApplicationsPageState expected)
    {
        var reader = new Reader();
        using var model = new ApplicationsViewModel(new(reader));
        var task = model.RefreshAsync();
        Assert.True(model.IsBusy);
        reader.Calls.Dequeue().SetResult(Result(partial: partial));
        await task;
        Assert.Equal(expected, model.State);
        Assert.Single(model.Page!.Items);
    }

    [Fact]
    public async Task FilteringAndPagingDoNotStartAnotherNativeEnumeration()
    {
        var reader = new Reader();
        using var model = new ApplicationsViewModel(new(reader));
        var task = model.RefreshAsync();
        reader.Calls.Dequeue().SetResult(Result(205));
        await task;
        var id = model.Page!.SnapshotId;
        model.NextPage();
        Assert.Equal(100, model.Page.Offset);
        model.NextPage();
        Assert.Equal(5, model.Page.Items.Length);
        model.PreviousPage();
        Assert.Equal(100, model.Page.Offset);
        model.Filter("Example 204", ApplicationSort.Name);
        Assert.Single(model.Page.Items);
        Assert.Equal(0, model.Page.Offset);
        Assert.Equal(id, model.Page.SnapshotId);
        Assert.Single(reader.Tokens);
    }

    [Fact]
    public async Task OlderResultCannotReplaceANewerRefresh()
    {
        var reader = new Reader();
        using var model = new ApplicationsViewModel(new(reader));
        var first = model.RefreshAsync();
        var old = reader.Calls.Dequeue();
        var second = model.RefreshAsync();
        reader.Calls.Dequeue().SetResult(Result(2));
        await second;
        Assert.True(reader.Tokens[0].IsCancellationRequested);
        old.SetResult(Result(partial: true));
        await first;
        Assert.Equal(ApplicationsPageState.Ready, model.State);
        Assert.Equal(2, model.Page!.Total);
    }

    [Fact]
    public async Task CancelledResultCannotBecomeReadyEvenIfAdapterFinishes()
    {
        var reader = new Reader();
        using var model = new ApplicationsViewModel(new(reader));
        var task = model.RefreshAsync();
        model.Cancel();
        Assert.True(model.StopRequested);
        reader.Calls.Dequeue().SetResult(Result());
        await task;
        Assert.Equal(ApplicationsPageState.Cancelled, model.State);
        Assert.Null(model.Page);
        Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task FailuresExposeOnlyStructuredCodes()
    {
        var reader = new Reader();
        using var model = new ApplicationsViewModel(new(reader));
        var task = model.RefreshAsync();
        reader.Calls.Dequeue().SetException(new ShouException("permission_denied", "Private system diagnostic"));
        await task;
        Assert.Equal(ApplicationsPageState.Failed, model.State);
        Assert.Equal("permission_denied", model.ErrorCode);
        Assert.Null(model.Page);
    }

    [Fact]
    public async Task ClosingCancelsAndSuppressesLateNotifications()
    {
        var reader = new Reader();
        var model = new ApplicationsViewModel(new(reader));
        var changes = 0;
        model.PropertyChanged += (_, _) => changes++;
        var task = model.RefreshAsync();
        model.Dispose();
        var before = changes;
        reader.Calls.Dequeue().SetResult(Result());
        await task;
        Assert.True(reader.Tokens[0].IsCancellationRequested);
        Assert.Equal(before, changes);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => model.RefreshAsync());
    }
}
