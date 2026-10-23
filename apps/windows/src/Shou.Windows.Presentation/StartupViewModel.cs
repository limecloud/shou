using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public enum StartupPageState { Empty, Loading, Ready, Partial, Cancelled, Failed }

public sealed class StartupViewModel(StartupInventoryService service) : INotifyPropertyChanged, IDisposable
{
    private CancellationTokenSource? operation;
    private StartupSnapshot? snapshot;
    private StartupQuery query = new();
    private long generation;
    private bool disposed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public StartupPageState State { get; private set; }
    public StartupPage? Page { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool IsBusy => State == StartupPageState.Loading;
    public bool StopRequested => operation?.IsCancellationRequested == true;
    public bool ShowingPreviousResults => Page is not null && State is StartupPageState.Loading or StartupPageState.Cancelled or StartupPageState.Failed;

    public async Task RefreshAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource();
        operation = current;
        ErrorCode = null;
        State = StartupPageState.Loading;
        Notify();
        try
        {
            var result = await service.ReadAsync(cancellationToken: current.Token);
            if (disposed || currentGeneration != generation) return;
            current.Token.ThrowIfCancellationRequested();
            snapshot = result;
            query = query with { Offset = 0 };
            Page = StartupInventoryService.Page(result, query);
            State = result.State == ScanState.Complete ? StartupPageState.Ready : StartupPageState.Partial;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (disposed || currentGeneration != generation) return;
            State = StartupPageState.Cancelled;
        }
        catch (Exception error)
        {
            if (disposed || currentGeneration != generation) return;
            State = StartupPageState.Failed;
            ErrorCode = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "startup_read_failed";
        }
        finally
        {
            if (!disposed && currentGeneration == generation) { operation = null; Notify(); }
        }
    }

    public void Filter(string search, StartupSource? source)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var next = query with { Search = search, Source = source, Offset = 0 };
        next.Validate();
        query = next;
        if (snapshot is not null) Page = StartupInventoryService.Page(snapshot, query);
        Notify();
    }
    public void NextPage() { ObjectDisposedException.ThrowIf(disposed, this); if (Page?.HasNext == true) MoveTo(query.Offset + query.Limit); }
    public void PreviousPage() { ObjectDisposedException.ThrowIf(disposed, this); if (query.Offset > 0) MoveTo(Math.Max(0, query.Offset - query.Limit)); }
    private void MoveTo(int offset)
    {
        if (snapshot is null || IsBusy) return;
        query = query with { Offset = offset };
        Page = StartupInventoryService.Page(snapshot, query);
        Notify();
    }
    public void Cancel() { operation?.Cancel(); Notify(); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        generation++;
        operation?.Cancel();
        operation = null;
        GC.SuppressFinalize(this);
    }
    private void Notify()
    {
        if (disposed) return;
        foreach (var property in new[] { nameof(State), nameof(Page), nameof(ErrorCode), nameof(IsBusy), nameof(StopRequested), nameof(ShowingPreviousResults) })
            PropertyChanged?.Invoke(this, new(property));
    }
}
