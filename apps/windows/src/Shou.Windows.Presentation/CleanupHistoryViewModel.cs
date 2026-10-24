using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public interface ICleanupHistoryOperations
{
    Task<CleanupHistoryPage> ListAsync(int limit, string? cursor, CancellationToken cancellationToken);
    Task<CleanupHistoryDetail> ShowAsync(string executionId, CancellationToken cancellationToken);
    Task<CleanupHistoryInspection> InspectAsync(string executionId, ScanBudget budget, CancellationToken cancellationToken);
}

public enum CleanupHistoryState { Empty, Loading, Ready, Partial, Inspecting, Cancelled, Failed }

/// <summary>Recorded outcomes and later observations remain separate; there are no recovery or retry commands.</summary>
public sealed class CleanupHistoryViewModel(ICleanupHistoryOperations operations) : INotifyPropertyChanged, IDisposable
{
    private CancellationTokenSource? operation;
    private long generation;
    private bool disposed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public CleanupHistoryState State { get; private set; }
    public CleanupHistoryPage? Page { get; private set; }
    public CleanupHistoryDetail? Detail { get; private set; }
    public CleanupHistoryInspection? Inspection { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool IsBusy => State is CleanupHistoryState.Loading or CleanupHistoryState.Inspecting;
    public bool StopRequested => operation?.IsCancellationRequested == true;
    public bool HasNext => Page?.NextCursor is not null;
    public bool CanInspect => !IsBusy && Detail is not null;

    public Task RefreshAsync() => LoadAsync(null);
    public Task NextPageAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        return Page?.NextCursor is { } cursor ? LoadAsync(cursor) : Task.CompletedTask;
    }
    private Task LoadAsync(string? cursor) => RunAsync(CleanupHistoryState.Loading, async token =>
    {
        var page = await operations.ListAsync(50, cursor, token);
        return () => { Page = page; State = page.State == "complete" ? CleanupHistoryState.Ready : CleanupHistoryState.Partial; };
    }, () => { Page = null; Detail = null; Inspection = null; });

    public Task ShowAsync(string executionId)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!RecordKey.IsId(executionId, "execution")) throw new ShouException("invalid_argument", "Choose a valid execution identifier.");
        return RunAsync(CleanupHistoryState.Loading, async token =>
        {
            var detail = await operations.ShowAsync(executionId, token);
            return () => { Detail = detail; State = detail.Unfinished || detail.NeedsVerification ? CleanupHistoryState.Partial : CleanupHistoryState.Ready; };
        }, () => { Detail = null; Inspection = null; });
    }

    public Task InspectAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!CanInspect || Detail is not { } detail) throw new ShouException("invalid_argument", "Open an execution before inspecting its recorded locations.");
        return RunAsync(CleanupHistoryState.Inspecting, async token =>
        {
            var inspection = await operations.InspectAsync(detail.Execution.Id, new(MaxDepth: 64), token);
            return () => { Inspection = inspection; State = inspection.State == "complete" ? CleanupHistoryState.Ready : CleanupHistoryState.Partial; };
        }, () => Inspection = null);
    }

    public void Cancel()
    {
        if (operation is null) return;
        operation.Cancel();
        NotifyAll();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        generation++;
        operation?.Cancel();
        operation = null;
        GC.SuppressFinalize(this);
    }

    private async Task RunAsync(CleanupHistoryState busy, Func<CancellationToken, Task<Action>> run, Action start)
    {
        using var diagnostic = OperationDiagnostics.Start("ui.history");
        ObjectDisposedException.ThrowIf(disposed, this);
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource();
        operation = current;
        start();
        State = busy;
        ErrorCode = null;
        NotifyAll();
        try
        {
            var apply = await run(current.Token);
            current.Token.ThrowIfCancellationRequested();
            if (!disposed && currentGeneration == generation) apply();
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (disposed || currentGeneration != generation) return;
            State = CleanupHistoryState.Cancelled;
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        {
            diagnostic.Fail(error);
            if (disposed || currentGeneration != generation) return;
            State = CleanupHistoryState.Failed;
            ErrorCode = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "read_failed";
        }
        finally
        {
            diagnostic.Complete(disposed || currentGeneration != generation ? "superseded" : State.ToString().ToLowerInvariant());
            if (!disposed && currentGeneration == generation) { operation = null; NotifyAll(); }
        }
    }

    private void NotifyAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
}
