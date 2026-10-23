namespace Shou.Windows.Platform;

/// <summary>A blocked kernel read retains its slot; cancellation cannot accumulate unbounded workers.</summary>
internal static class NativeOperationScheduler
{
    internal static readonly SemaphoreSlim Slots = new(2, 2);

    internal static async ValueTask<T> RunAsync<T>(Func<T> read, CancellationToken cancellationToken)
    {
        await Slots.WaitAsync(cancellationToken).ConfigureAwait(false);
        var task = Task.Run(() =>
        {
            try { return read(); }
            finally { Slots.Release(); }
        }, CancellationToken.None);
        Observe(task);
        return await task.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    internal static async Task<T> RunToCompletionAsync<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        await Slots.WaitAsync(cancellationToken).ConfigureAwait(false);
        return await Task.Run(() =>
        {
            try { return operation(); }
            finally { Slots.Release(); }
        }, CancellationToken.None).ConfigureAwait(false);
    }

    internal static void Observe(Task task) => _ = task.ContinueWith(completed => { _ = completed.Exception; },
        CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
}
