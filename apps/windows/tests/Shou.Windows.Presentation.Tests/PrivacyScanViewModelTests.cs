using Shou.Windows.Core;

namespace Shou.Windows.Presentation.Tests;

public sealed class PrivacyScanViewModelTests
{
    private sealed class Operations : IPrivacyScanOperations
    {
        public PrivacyTimeRange Range;
        public CancellationToken Token;
        public TaskCompletionSource<PrivacyScan> Result = new();
        public Task<PrivacyScan> ScanAsync(PrivacyTimeRange range, CancellationToken cancellationToken)
        { Range = range; Token = cancellationToken; return Result.Task; }
    }
    private static PrivacyScan Scan(PrivacyTimeRange range = PrivacyTimeRange.LastHour, bool complete = true)
    {
        var now = DateTimeOffset.UtcNow;
        return new(1, RecordKey.New("privacy_scan"), now, now.AddMinutes(15), PrivacyWindow.Create(range, now), "sha256:" + new string('a', 64), [], [], complete, "sha256:" + new string('b', 64));
    }
    private static PrivacySourceObservation Source(string id, PrivacyDataKind kind = PrivacyDataKind.History,
        PrivacySourceState state = PrivacySourceState.Ready, long? count = 3) => new(
            new(id, PrivacyBrowser.Chromium, "Default", kind, kind == PrivacyDataKind.History ? PrivacyDatabaseLocation.History : PrivacyDatabaseLocation.NetworkCookies,
                WindowsPath.Parse(kind == PrivacyDataKind.History ? "C:/Users/Test/History" : "C:/Users/Test/Network/Cookies")), state, count, null, null, []);
    private static async Task Load(PrivacyScanViewModel model, Operations operations, params PrivacySourceObservation[] sources)
    {
        operations.Result = new(); var task = model.ScanAsync();
        operations.Result.SetResult(Scan(model.Range) with { Sources = [.. sources] }); await task;
    }
    [Fact]
    public async Task SelectionStartsEmptyAndCountsOnlyExplicitReadySources()
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        await Load(model, operations, Source("history-a"), Source("history-b", count: 5));
        Assert.Empty(model.SelectedSources); Assert.Equal(0, model.SelectedRecordCount);
        model.SetSelected("history-a", true); model.SetSelected("history-a", true);
        Assert.Equal(1, model.SelectedSourceCount); Assert.Equal(3, model.SelectedRecordCount);
        model.SetSelected("history-b", true); Assert.Equal(8, model.SelectedRecordCount);
        model.SetSelected("history-a", false); Assert.Equal("history-b", Assert.Single(model.SelectedSources).Source.Id);
        model.ClearSelection(); Assert.Equal(0, model.SelectedSourceCount); Assert.Equal(0, model.SelectedRecordCount);
    }
    [Fact]
    public async Task CookieReviewGatesSelectionAndRevocationPreservesHistory()
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        await Load(model, operations, Source("history"), Source("cookies", PrivacyDataKind.Cookies));
        Assert.False(model.AllowCookieReview); Assert.False(model.CanSelect("cookies"));
        model.SetSelected("cookies", true); Assert.Empty(model.SelectedSources);
        model.SetSelected("history", true); model.SetCookieReview(true);
        Assert.True(model.CanSelect("cookies")); Assert.False(model.IsSelected("cookies"));
        model.SetSelected("cookies", true); Assert.Equal(2, model.SelectedSourceCount);
        model.SetCookieReview(false); Assert.Equal("history", Assert.Single(model.SelectedSources).Source.Id);
        Assert.False(model.CanSelect("cookies"));
        model.SetCookieReview(true); Assert.False(model.IsSelected("cookies"));
    }
    [Theory]
    [InlineData(PrivacySourceState.Empty)]
    [InlineData(PrivacySourceState.BrowserRunning)]
    [InlineData(PrivacySourceState.ActivityUnknown)]
    [InlineData(PrivacySourceState.PermissionRequired)]
    [InlineData(PrivacySourceState.SchemaUnsupported)]
    [InlineData(PrivacySourceState.Unavailable)]
    [InlineData(PrivacySourceState.Excluded)]
    public async Task IneligibleSourcesCannotEnterSelection(PrivacySourceState state)
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        await Load(model, operations, Source("blocked", state: state));
        Assert.False(model.CanSelect("blocked")); model.SetSelected("blocked", true); Assert.Empty(model.SelectedSources);
        model.SetSelected("missing", true); Assert.Empty(model.SelectedSources);
    }
    [Theory]
    [InlineData(null)]
    [InlineData(0L)]
    [InlineData(-1L)]
    public async Task MissingOrZeroCountCannotBeSelected(long? count)
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        await Load(model, operations, Source("empty", count: count));
        Assert.False(model.CanSelect("empty")); model.SetSelected("empty", true); Assert.Equal(0, model.SelectedSourceCount);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RangeAndConfigurationChangesDropSelections(bool changeRange)
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        await Load(model, operations, Source("history")); model.SetSelected("history", true);
        if (changeRange) model.SetRange(PrivacyTimeRange.LastDay); else model.Invalidate();
        Assert.Empty(model.SelectedSources); Assert.Equal(0, model.SelectedSourceCount); Assert.False(model.CanSelect("history"));
    }
    [Fact]
    public async Task RefreshClearsSelectionBeforeWaitingAndDoesNotRestoreIt()
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        await Load(model, operations, Source("history")); model.SetSelected("history", true);
        operations.Result = new(); var task = model.ScanAsync();
        Assert.Equal(0, model.SelectedSourceCount); Assert.False(model.CanSelect("history"));
        model.SetSelected("history", true); model.SetCookieReview(true);
        Assert.Empty(model.SelectedSources); Assert.False(model.AllowCookieReview);
        operations.Result.SetResult(Scan() with { Sources = [Source("history")] }); await task;
        Assert.True(model.CanSelect("history")); Assert.False(model.IsSelected("history"));
    }
    [Fact]
    public async Task SelectionChangesNotifyTheFooterWithoutReplacingTheScan()
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        await Load(model, operations, Source("history")); var scan = model.Scan; var names = new List<string?>();
        model.PropertyChanged += (_, args) => names.Add(args.PropertyName);
        model.SetSelected("history", true);
        Assert.Contains(nameof(PrivacyScanViewModel.SelectedSourceCount), names);
        Assert.Contains(nameof(PrivacyScanViewModel.SelectedRecordCount), names);
        Assert.DoesNotContain(nameof(PrivacyScanViewModel.Scan), names); Assert.Same(scan, model.Scan);
    }
    [Theory]
    [InlineData(true, PrivacyScanPageState.Ready)]
    [InlineData(false, PrivacyScanPageState.Partial)]
    public async Task ExplicitScanForwardsRangeAndPublishesCoverage(bool complete, PrivacyScanPageState state)
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        Assert.Equal(PrivacyScanPageState.Empty, model.State); Assert.Null(model.Scan);
        model.SetRange(PrivacyTimeRange.AllTime); var task = model.ScanAsync();
        Assert.True(model.IsBusy); Assert.Equal(PrivacyTimeRange.AllTime, operations.Range); Assert.Null(model.Scan);
        var scan = Scan(PrivacyTimeRange.AllTime, complete); operations.Result.SetResult(scan); await task;
        Assert.Same(scan, model.Scan); Assert.Equal(state, model.State); Assert.False(model.IsBusy);
        model.SetRange(PrivacyTimeRange.AllTime); Assert.Same(scan, model.Scan);
        model.SetRange(PrivacyTimeRange.LastDay); Assert.Null(model.Scan); Assert.Equal(PrivacyScanPageState.Empty, model.State);
    }
    [Fact]
    public async Task StopDiscardsAResultReturnedByAnUncooperativeReader()
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        var task = model.ScanAsync(); model.Cancel(); Assert.True(model.StopRequested); Assert.True(operations.Token.IsCancellationRequested);
        operations.Result.SetResult(Scan()); await task;
        Assert.Equal(PrivacyScanPageState.Cancelled, model.State); Assert.Null(model.Scan); Assert.False(model.IsBusy);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConfigurationOrRangeChangesInvalidatePendingEvidence(bool range)
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations); var task = model.ScanAsync();
        if (range) model.SetRange(PrivacyTimeRange.LastDay); else model.Invalidate();
        Assert.True(operations.Token.IsCancellationRequested); operations.Result.SetResult(Scan()); await task;
        Assert.Null(model.Scan); Assert.Equal(PrivacyScanPageState.Empty, model.State);
    }
    [Fact]
    public async Task NewScanCannotBeOverwrittenByAnOlderCompletion()
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations);
        var oldCompletion = operations.Result; var old = model.ScanAsync(); operations.Result = new();
        var current = model.ScanAsync(); var scan = Scan(complete: false); operations.Result.SetResult(scan); await current;
        oldCompletion.SetResult(Scan()); await old; Assert.Same(scan, model.Scan); Assert.Equal(PrivacyScanPageState.Partial, model.State);
    }
    [Fact]
    public async Task FailedReadDoesNotPreserveOldEvidenceOrExceptionValues()
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations); var first = model.ScanAsync();
        operations.Result.SetResult(Scan()); await first; operations.Result = new(); var failed = model.ScanAsync();
        operations.Result.SetException(new IOException("private browser record")); await failed;
        Assert.Null(model.Scan); Assert.Equal(PrivacyScanPageState.Failed, model.State); Assert.Equal("privacy_scan_failed", model.ErrorCode);
    }
    [Fact]
    public async Task ResultMustMatchTheCurrentRequestedRange()
    {
        var operations = new Operations(); using var model = new PrivacyScanViewModel(operations); var task = model.ScanAsync();
        operations.Result.SetResult(Scan(PrivacyTimeRange.LastDay)); await task;
        Assert.Null(model.Scan); Assert.Equal("privacy_scan_invalid", model.ErrorCode);
    }
    [Fact]
    public async Task DisposalCancelsAndSuppressesLateNotifications()
    {
        var operations = new Operations(); var model = new PrivacyScanViewModel(operations); var notifications = 0;
        model.PropertyChanged += (_, _) => notifications++; var task = model.ScanAsync(); var count = notifications; model.Dispose();
        Assert.True(operations.Token.IsCancellationRequested); operations.Result.SetResult(Scan()); await task;
        Assert.Null(model.Scan); Assert.Equal(count, notifications); await Assert.ThrowsAsync<ObjectDisposedException>(() => model.ScanAsync());
    }
}
