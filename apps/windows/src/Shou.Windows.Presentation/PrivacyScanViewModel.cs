using System.Collections.Immutable;
using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public interface IPrivacyScanOperations
{
    Task<PrivacyScan> ScanAsync(PrivacyTimeRange range, CancellationToken cancellationToken);
}
public enum PrivacyScanPageState { Empty, Scanning, Ready, Partial, Cancelled, Failed }

/// <summary>A scan is read-only evidence. Changing scope clears it, and cancelled/late results cannot restore it.</summary>
public sealed class PrivacyScanViewModel(IPrivacyScanOperations operations) : INotifyPropertyChanged, IDisposable
{
    private CancellationTokenSource? operation;
    private long generation;
    private bool disposed;
    private readonly HashSet<string> selected = new(StringComparer.Ordinal);
    public event PropertyChangedEventHandler? PropertyChanged;
    public PrivacyTimeRange Range { get; private set; } = PrivacyTimeRange.LastHour;
    public PrivacyScanPageState State { get; private set; }
    public PrivacyScan? Scan { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool IsBusy => State == PrivacyScanPageState.Scanning;
    public bool StopRequested => operation?.IsCancellationRequested == true;
    public bool AllowCookieReview { get; private set; }
    public ImmutableArray<PrivacySourceObservation> SelectedSources => Scan?.Sources.Where(source => selected.Contains(source.Source.Id)).ToImmutableArray() ?? [];
    public int SelectedSourceCount => selected.Count;
    public long SelectedRecordCount => SelectedSources.Sum(source => source.RecordCount ?? 0);

    public bool IsSelected(string sourceId) => selected.Contains(sourceId);
    public bool CanSelect(string sourceId) => !disposed && !IsBusy && Scan?.Sources.Any(source =>
        source.Source.Id == sourceId && source.State == PrivacySourceState.Ready && source.RecordCount > 0 &&
        (source.Source.Kind != PrivacyDataKind.Cookies || AllowCookieReview)) == true;
    public void SetSelected(string sourceId, bool value)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (value && !CanSelect(sourceId)) return;
        if (value ? selected.Add(sourceId) : selected.Remove(sourceId)) NotifySelection();
    }
    public void ClearSelection()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (selected.Count == 0) return;
        selected.Clear(); NotifySelection();
    }
    public void SetCookieReview(bool allowed)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy || allowed == AllowCookieReview) return;
        AllowCookieReview = allowed;
        if (!allowed && Scan is { } scan)
            selected.ExceptWith(scan.Sources.Where(source => source.Source.Kind == PrivacyDataKind.Cookies).Select(source => source.Source.Id));
        NotifySelection();
    }

    public void SetRange(PrivacyTimeRange range)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!Enum.IsDefined(range)) throw new ShouException("invalid_argument", "Choose a supported privacy range.");
        if (range == Range) return;
        generation++; operation?.Cancel(); operation = null;
        Range = range; Scan = null; selected.Clear(); ErrorCode = null; State = PrivacyScanPageState.Empty; Notify();
    }
    public async Task ScanAsync()
    {
        using var diagnostic = OperationDiagnostics.Start("ui.privacy.scan");
        ObjectDisposedException.ThrowIf(disposed, this);
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource(); operation = current;
        var range = Range; Scan = null; selected.Clear(); ErrorCode = null; State = PrivacyScanPageState.Scanning; Notify();
        try
        {
            var result = await operations.ScanAsync(range, current.Token);
            if (disposed || currentGeneration != generation) return;
            current.Token.ThrowIfCancellationRequested();
            if (result is null || result.Window is null || result.Window.Range != range || result.Sources.IsDefault || result.Issues.IsDefault ||
                !RecordKey.IsId(result.Id, "privacy_scan")) throw new ShouException("privacy_scan_invalid", "The privacy scan does not match the requested scope.");
            Scan = result; State = result.Complete ? PrivacyScanPageState.Ready : PrivacyScanPageState.Partial;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        { if (!disposed && currentGeneration == generation) State = PrivacyScanPageState.Cancelled; }
        catch (Exception error)
        {
            diagnostic.Fail(error);
            if (!disposed && currentGeneration == generation)
            { State = PrivacyScanPageState.Failed; ErrorCode = error is ShouException known ? known.Code : "privacy_scan_failed"; }
        }
        finally { diagnostic.Complete(disposed || currentGeneration != generation ? "superseded" : State.ToString().ToLowerInvariant()); if (!disposed && currentGeneration == generation) { operation = null; Notify(); } }
    }
    public void Invalidate()
    {
        if (disposed) return;
        generation++; operation?.Cancel(); operation = null; Scan = null; selected.Clear(); ErrorCode = null; State = PrivacyScanPageState.Empty; Notify();
    }
    public void Cancel() { if (disposed) return; operation?.Cancel(); Notify(); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; generation++; operation?.Cancel(); operation = null; Scan = null; selected.Clear(); GC.SuppressFinalize(this);
    }
    private void Notify()
    {
        if (disposed) return;
        foreach (var name in new[] { nameof(State), nameof(Range), nameof(Scan), nameof(ErrorCode), nameof(IsBusy), nameof(StopRequested) })
            PropertyChanged?.Invoke(this, new(name));
        NotifySelection();
    }
    private void NotifySelection()
    {
        foreach (var name in new[] { nameof(AllowCookieReview), nameof(SelectedSources), nameof(SelectedSourceCount), nameof(SelectedRecordCount) })
            PropertyChanged?.Invoke(this, new(name));
    }
}
