using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public enum ApplicationsPageState { Empty, Loading, Ready, Partial, Cancelled, Failed }

public sealed class ApplicationsViewModel(ApplicationCatalog catalog) : INotifyPropertyChanged, IDisposable
{
    private CancellationTokenSource? operation;
    private ApplicationCatalogSnapshot? snapshot;
    private ApplicationQuery query = new(Limit: 100);
    private long generation;
    private bool disposed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public ApplicationsPageState State { get; private set; }
    public ApplicationCatalogPage? Page { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool IsBusy => State == ApplicationsPageState.Loading;
    public bool StopRequested => operation?.IsCancellationRequested == true;

    public async Task RefreshAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource();
        operation = current;
        snapshot = null;
        Page = null;
        ErrorCode = null;
        State = ApplicationsPageState.Loading;
        Notify();
        try
        {
            var result = await catalog.ReadAsync(cancellationToken: current.Token);
            if (disposed || currentGeneration != generation) return;
            current.Token.ThrowIfCancellationRequested();
            snapshot = result;
            query = query with { Offset = 0 };
            Page = ApplicationCatalog.Page(result, query);
            State = result.State == ScanState.Complete ? ApplicationsPageState.Ready : ApplicationsPageState.Partial;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (disposed || currentGeneration != generation) return;
            State = ApplicationsPageState.Cancelled;
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        {
            if (disposed || currentGeneration != generation) return;
            State = ApplicationsPageState.Failed;
            ErrorCode = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "read_failed";
        }
        finally
        {
            if (!disposed && currentGeneration == generation) { operation = null; Notify(); }
        }
    }

    public void Filter(string search, ApplicationSort sort)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var next = query with { Search = search, Sort = sort, Offset = 0 };
        next.Validate();
        query = next;
        if (snapshot is not null) Page = ApplicationCatalog.Page(snapshot, query);
        Notify();
    }

    public void NextPage() { if (Page?.HasNext == true) MoveTo(query.Offset + query.Limit); }
    public void PreviousPage() { if (query.Offset > 0) MoveTo(Math.Max(0, query.Offset - query.Limit)); }
    private void MoveTo(int offset)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (snapshot is null || IsBusy) return;
        query = query with { Offset = offset };
        Page = ApplicationCatalog.Page(snapshot, query);
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
        foreach (var property in new[] { nameof(State), nameof(Page), nameof(ErrorCode), nameof(IsBusy), nameof(StopRequested) })
            PropertyChanged?.Invoke(this, new(property));
    }
}
