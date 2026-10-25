using System.ComponentModel;
using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

/// <summary>UI-context state; cancellation never overlaps a replacement read or accepts a late result.</summary>
public sealed class SystemMonitorViewModel(ISystemMonitorSampling source, TimeSpan? interval = null) : INotifyPropertyChanged, IDisposable
{
    private readonly SystemMonitorCalculator calculator = new();
    private CancellationTokenSource? operation;
    private bool visible, disposed, sourceDisposed;
    private long generation;
    public event PropertyChangedEventHandler? PropertyChanged;
    public SystemMonitorSample? Sample { get; private set; }
    public ImmutableArray<SystemMonitorSample> History => calculator.History;
    public bool Paused { get; private set; }
    public bool BackgroundEnabled { get; private set; }
    public bool Failed { get; private set; }
    public bool IsSampling { get; private set; }
    private bool Desired => !disposed && !Paused && (visible || BackgroundEnabled);
    public void SetVisible(bool value) { if (visible == value) return; visible = value; Reconcile(); }
    public void SetBackgroundEnabled(bool value) { BackgroundEnabled = value; Reconcile(); Notify(); }
    public void SetPaused(bool value) { Paused = value; Reconcile(); Notify(); }
    private void Reconcile()
    {
        if (!Desired) { generation++; calculator.ResetBaseline(); operation?.Cancel(); IsSampling = false; }
        else if (operation is null)
        {
            operation = new(); IsSampling = true;
            _ = RunAsync(operation, generation);
        }
    }
    private async Task RunAsync(CancellationTokenSource current, long currentGeneration)
    {
        try
        {
            while (!current.IsCancellationRequested && Desired && currentGeneration == generation)
            {
                try
                {
                    var observation = await source.ObserveAsync(current.Token);
                    if (current.IsCancellationRequested || !Desired || currentGeneration != generation) break;
                    Sample = calculator.Append(observation); Failed = false; Notify();
                }
                catch (OperationCanceledException) when (current.IsCancellationRequested) { break; }
                catch (Exception) { if (current.IsCancellationRequested || !Desired || currentGeneration != generation) break; Failed = true; calculator.ResetBaseline(); Notify(); }
                await Task.Delay(interval ?? TimeSpan.FromSeconds(2), current.Token);
            }
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested) { }
        finally
        {
            current.Dispose(); operation = null; IsSampling = false;
            if (disposed) DisposeSource(); else Reconcile();
        }
    }
    private void Notify() { if (!disposed) PropertyChanged?.Invoke(this, new(null)); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; Reconcile();
        if (operation is null) DisposeSource();
    }
    private void DisposeSource() { if (sourceDisposed) return; sourceDisposed = true; (source as IDisposable)?.Dispose(); }
}
