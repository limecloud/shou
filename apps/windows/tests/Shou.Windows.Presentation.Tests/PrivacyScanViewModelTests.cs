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
