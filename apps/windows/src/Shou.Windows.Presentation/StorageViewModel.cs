using System.ComponentModel;
using System.Runtime.CompilerServices;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public enum StoragePageState { Empty, Scanning, Ready, Partial, Cancelled, Failed }

/// <summary>UI-independent state. The caller resumes updates on its own presentation context.</summary>
public sealed class StorageViewModel(IStorageScanner scanner) : INotifyPropertyChanged, IDisposable
{
    private CancellationTokenSource? operation;
    private long generation;
    private bool disposed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public StoragePageState State { get; private set; }
    public ScanSnapshot? Snapshot { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool IsBusy => State == StoragePageState.Scanning;

    public async Task ScanAsync(WindowsPath root, ScanBudget? budget = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource();
        operation = current;
        State = StoragePageState.Scanning;
        Snapshot = null;
        ErrorCode = null;
        NotifyAll();
        try
        {
            var snapshot = await scanner.ScanAsync(root, budget ?? new(), null, current.Token);
            if (disposed || currentGeneration != generation) return;
            Snapshot = snapshot;
            State = snapshot.State switch
            {
                ScanState.Complete => StoragePageState.Ready,
                ScanState.Cancelled => StoragePageState.Cancelled,
                _ => StoragePageState.Partial
            };
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (disposed || currentGeneration != generation) return;
            State = StoragePageState.Cancelled;
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        {
            if (disposed || currentGeneration != generation) return;
            State = StoragePageState.Failed;
            ErrorCode = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "read_failed";
        }
        finally
        {
            if (!disposed && currentGeneration == generation)
            {
                operation = null;
                NotifyAll();
            }
        }
    }

    public void Cancel() => operation?.Cancel();

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        generation++;
        operation?.Cancel();
        operation = null;
        GC.SuppressFinalize(this);
    }

    private void NotifyAll()
    {
        Notify(nameof(State));
        Notify(nameof(Snapshot));
        Notify(nameof(ErrorCode));
        Notify(nameof(IsBusy));
    }

    private void Notify([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
}
