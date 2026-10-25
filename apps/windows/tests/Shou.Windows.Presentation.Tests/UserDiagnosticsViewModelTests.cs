using Shou.Windows.Core;

namespace Shou.Windows.Presentation.Tests;

public sealed class UserDiagnosticsViewModelTests
{
    private sealed class Source : IUserDiagnostics
    {
        public readonly Queue<TaskCompletionSource<DiagnosticReport>> Calls = new();
        public readonly List<CancellationToken> Tokens = [];
        public Task<DiagnosticReport> CollectAsync(CancellationToken token)
        {
            Tokens.Add(token); var call = new TaskCompletionSource<DiagnosticReport>(); Calls.Enqueue(call); return call.Task;
        }
    }
    private static DiagnosticReport Report() => DiagnosticReport.Create("0.14.0", "x64", "10.0.26100", 8, 100, null, null, DiagnosticRecordState.Missing);

    [Fact]
    public async Task LateRefreshCannotReplaceTheCurrentReport()
    {
        var source = new Source(); using var model = new UserDiagnosticsViewModel(source);
        var first = model.RefreshAsync(); var old = source.Calls.Dequeue();
        var second = model.RefreshAsync(); var latest = Report(); source.Calls.Dequeue().SetResult(latest); await second;
        old.SetResult(Report()); await first;
        Assert.Same(latest, model.Report); Assert.True(source.Tokens[0].IsCancellationRequested); Assert.False(model.IsBusy);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CancelAndDisposeSuppressLateResults(bool dispose)
    {
        var source = new Source(); using var model = new UserDiagnosticsViewModel(source);
        var pending = model.RefreshAsync(); var changes = 0; model.PropertyChanged += (_, _) => changes++;
        if (dispose) model.Dispose(); else model.Cancel();
        var before = changes; source.Calls.Dequeue().SetResult(Report()); await pending;
        Assert.Equal(before, changes); Assert.Null(model.Report); Assert.True(source.Tokens[0].IsCancellationRequested);
    }

    [Fact]
    public async Task ErrorsPublishOnlyBoundedCodesAndRetryClearsThem()
    {
        var source = new Source(); using var model = new UserDiagnosticsViewModel(source);
        var first = model.RefreshAsync(); source.Calls.Dequeue().SetException(new IOException("private user path")); await first;
        Assert.Equal("diagnostics_unavailable", model.ErrorCode);
        var next = model.RefreshAsync(); Assert.Null(model.ErrorCode);
        source.Calls.Dequeue().SetResult(Report()); await next; Assert.NotNull(model.Report);
    }
}
