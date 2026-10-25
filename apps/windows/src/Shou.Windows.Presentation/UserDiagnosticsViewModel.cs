using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public sealed class UserDiagnosticsViewModel(IUserDiagnostics source) : INotifyPropertyChanged, IDisposable
{
    private CancellationTokenSource? operation;
    private long generation;
    private bool disposed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public DiagnosticReport? Report { get; private set; }
    public bool IsBusy { get; private set; }
    public string? ErrorCode { get; private set; }

    public async Task RefreshAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource();
        operation = current; IsBusy = true; Report = null; ErrorCode = null; Notify();
        try
        {
            var report = await source.CollectAsync(current.Token);
            current.Token.ThrowIfCancellationRequested();
            if (!disposed && currentGeneration == generation) Report = report;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!disposed && currentGeneration == generation) ErrorCode = error is ShouException known ? known.Code : "diagnostics_unavailable";
        }
        finally
        {
            if (!disposed && currentGeneration == generation) { operation = null; IsBusy = false; Notify(); }
        }
    }

    public void Cancel() { ++generation; operation?.Cancel(); operation = null; IsBusy = false; Notify(); }
    public void Dispose() { if (disposed) return; disposed = true; ++generation; operation?.Cancel(); operation = null; }
    private void Notify()
    {
        if (disposed) return;
        foreach (var property in new[] { nameof(Report), nameof(IsBusy), nameof(ErrorCode) }) PropertyChanged?.Invoke(this, new(property));
    }
}
