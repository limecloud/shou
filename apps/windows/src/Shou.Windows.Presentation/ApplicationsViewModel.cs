using System.Collections.Immutable;
using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public enum ApplicationsPageState { Empty, Loading, Ready, Partial, Cancelled, Failed }
public enum ApplicationPresentationFilter { All, SystemPackage, HasRegisteredSize, CurrentUser }

public sealed class ApplicationsViewModel(ApplicationCatalog catalog) : INotifyPropertyChanged, IDisposable
{
    private CancellationTokenSource? operation;
    private ApplicationCatalogSnapshot? snapshot;
    private ApplicationQuery query = new(Sort: ApplicationSort.RegisteredSize, Limit: 100);
    private ApplicationPresentationFilter presentation = ApplicationPresentationFilter.All;
    private long generation;
    private bool disposed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public ApplicationsPageState State { get; private set; }
    public ApplicationCatalogPage? Page { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool IsBusy => State == ApplicationsPageState.Loading;
    public bool StopRequested => operation?.IsCancellationRequested == true;
    public int CatalogCount => snapshot?.Applications.Length ?? 0;
    public long RegisteredEstimatedBytes => snapshot?.Applications.Aggregate(0L, (total, item) =>
        item.RegisteredEstimatedBytes is not { } size || size > long.MaxValue - total ? total : total + size) ?? 0;
    public int SystemPackageCount => snapshot?.Applications.Count(item => item.IsSystemPackage) ?? 0;
    public int SizedCount => snapshot?.Applications.Count(item => item.RegisteredEstimatedBytes is not null) ?? 0;
    public int CurrentUserCount => snapshot?.Applications.Count(item => item.Source is ApplicationSource.CurrentUserRegistry or ApplicationSource.CurrentUserMsix) ?? 0;

    public async Task RefreshAsync()
    {
        using var diagnostic = OperationDiagnostics.Start("ui.applications.refresh");
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
            Publish();
            State = result.State == ScanState.Complete ? ApplicationsPageState.Ready : ApplicationsPageState.Partial;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (disposed || currentGeneration != generation) return;
            State = ApplicationsPageState.Cancelled;
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        {
            diagnostic.Fail(error);
            if (disposed || currentGeneration != generation) return;
            State = ApplicationsPageState.Failed;
            ErrorCode = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "read_failed";
        }
        finally
        {
            diagnostic.Complete(disposed || currentGeneration != generation ? "superseded" : State.ToString().ToLowerInvariant());
            if (!disposed && currentGeneration == generation) { operation = null; Notify(); }
        }
    }

    public void Filter(string search, ApplicationSort sort)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var next = query with { Search = search, Sort = sort, Offset = 0 };
        next.Validate();
        query = next;
        Publish();
        Notify();
    }

    public void SetPresentationFilter(ApplicationPresentationFilter filter)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!Enum.IsDefined(filter) || presentation == filter) return;
        presentation = filter;
        query = query with { Offset = 0 };
        Publish();
        Notify();
    }

    public void NextPage() { if (Page?.HasNext == true) MoveTo(query.Offset + query.Limit); }
    public void PreviousPage() { if (query.Offset > 0) MoveTo(Math.Max(0, query.Offset - query.Limit)); }
    private void MoveTo(int offset)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (snapshot is null || IsBusy) return;
        query = query with { Offset = offset };
        Publish();
        Notify();
    }
    private void Publish()
    {
        if (snapshot is null) return;
        var applications = presentation == ApplicationPresentationFilter.All ? snapshot.Applications : snapshot.Applications.Where(Matches).ToImmutableArray();
        Page = ApplicationCatalog.Page(snapshot with { Applications = applications }, query);
    }
    private bool Matches(InstalledApplication item) => presentation switch
    {
        ApplicationPresentationFilter.SystemPackage => item.IsSystemPackage,
        ApplicationPresentationFilter.HasRegisteredSize => item.RegisteredEstimatedBytes is not null,
        ApplicationPresentationFilter.CurrentUser => item.Source is ApplicationSource.CurrentUserRegistry or ApplicationSource.CurrentUserMsix,
        _ => true
    };
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
