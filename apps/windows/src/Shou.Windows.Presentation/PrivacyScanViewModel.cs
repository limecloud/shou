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
    public event PropertyChangedEventHandler? PropertyChanged;
    public PrivacyTimeRange Range { get; private set; } = PrivacyTimeRange.LastHour;
    public PrivacyScanPageState State { get; private set; }
    public PrivacyScan? Scan { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool IsBusy => State == PrivacyScanPageState.Scanning;
    public bool StopRequested => operation?.IsCancellationRequested == true;

    public void SetRange(PrivacyTimeRange range)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!Enum.IsDefined(range)) throw new ShouException("invalid_argument", "Choose a supported privacy range.");
        if (range == Range) return;
        generation++; operation?.Cancel(); operation = null;
        Range = range; Scan = null; ErrorCode = null; State = PrivacyScanPageState.Empty; Notify();
    }
    public async Task ScanAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource(); operation = current;
        var range = Range; Scan = null; ErrorCode = null; State = PrivacyScanPageState.Scanning; Notify();
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
            if (!disposed && currentGeneration == generation)
            { State = PrivacyScanPageState.Failed; ErrorCode = error is ShouException known ? known.Code : "privacy_scan_failed"; }
        }
        finally { if (!disposed && currentGeneration == generation) { operation = null; Notify(); } }
    }
    public void Invalidate()
    {
        if (disposed) return;
        generation++; operation?.Cancel(); operation = null; Scan = null; ErrorCode = null; State = PrivacyScanPageState.Empty; Notify();
    }
    public void Cancel() { if (disposed) return; operation?.Cancel(); Notify(); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; generation++; operation?.Cancel(); operation = null; Scan = null; GC.SuppressFinalize(this);
    }
    private void Notify()
    {
        if (disposed) return;
        foreach (var name in new[] { nameof(State), nameof(Range), nameof(Scan), nameof(ErrorCode), nameof(IsBusy), nameof(StopRequested) })
            PropertyChanged?.Invoke(this, new(name));
    }
}
