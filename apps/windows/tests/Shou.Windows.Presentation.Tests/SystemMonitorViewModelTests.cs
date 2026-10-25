using System.Threading.Channels;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation.Tests;

public sealed class SystemMonitorViewModelTests
{
    private sealed class Source : ISystemMonitorSampling, IDisposable
    {
        public readonly Channel<TaskCompletionSource<SystemMonitorObservation>> Requests = Channel.CreateUnbounded<TaskCompletionSource<SystemMonitorObservation>>();
        public int Calls, Active, Maximum; public bool Disposed;
        public async Task<SystemMonitorObservation> ObserveAsync(CancellationToken token)
        {
            var call = new TaskCompletionSource<SystemMonitorObservation>();
            Interlocked.Increment(ref Calls); Maximum = Math.Max(Maximum, Interlocked.Increment(ref Active));
            Requests.Writer.TryWrite(call);
            try { return await call.Task; } finally { Interlocked.Decrement(ref Active); }
        }
        public Task<TaskCompletionSource<SystemMonitorObservation>> Next() => Requests.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
        public void Dispose() => Disposed = true;
    }
    [Fact] public async Task PauseResumeCannotOverlapAnUncancelableNativeReadOrAcceptItsLateResult()
    {
        var source = new Source(); using var model = new SystemMonitorViewModel(source, TimeSpan.FromMilliseconds(5));
        model.SetVisible(true); var old = await source.Next(); model.SetPaused(true); model.SetPaused(false);
        Assert.Equal(1, source.Calls); old.SetResult(new() { Uptime = 1 });
        var current = await source.Next(); Assert.Null(model.Sample); current.SetResult(new() { Uptime = 3 });
        var third = await source.Next(); Assert.True(model.Sample!.Baseline); Assert.Equal(1, source.Maximum);
        model.Dispose(); third.SetResult(new() { Uptime = 5 });
        await Eventually(() => source.Disposed); Assert.Equal(3, model.Sample.Observation.Uptime);
    }
    [Fact] public async Task HiddenPagesStopButAnExplicitSummaryKeepsOneSamplerAndDisposalRejectsCallbacks()
    {
        var source = new Source(); using var model = new SystemMonitorViewModel(source, TimeSpan.FromMilliseconds(5));
        model.SetVisible(true); var first = await source.Next(); first.SetResult(new() { Uptime = 1 });
        var second = await source.Next(); model.SetVisible(false); second.SetResult(new() { Uptime = 3 });
        await Eventually(() => source.Active == 0); Assert.Equal(1, model.Sample!.Observation.Uptime);
        model.SetBackgroundEnabled(true); var third = await source.Next(); third.SetResult(new() { Uptime = 5 });
        var fourth = await source.Next(); Assert.True(model.Sample.Baseline);
        var notifications = 0; model.PropertyChanged += (_, _) => notifications++;
        model.Dispose(); fourth.SetResult(new() { Uptime = 7 }); await Eventually(() => source.Disposed);
        Assert.Equal(0, notifications); Assert.Equal(5, model.Sample.Observation.Uptime); Assert.Equal(1, source.Maximum);
    }
    [Fact] public async Task AFailedReadPreservesHistoryAndResetsTheNextRateBaseline()
    {
        var source = new Source(); using var model = new SystemMonitorViewModel(source, TimeSpan.FromMilliseconds(5));
        model.SetVisible(true); (await source.Next()).SetResult(new() { Uptime = 1 });
        (await source.Next()).SetException(new IOException("private path"));
        var next = await source.Next(); Assert.True(model.Failed); Assert.Single(model.History);
        next.SetResult(new() { Uptime = 3 }); var pending = await source.Next(); Assert.True(model.Sample!.Baseline); Assert.False(model.Failed);
        model.Dispose(); pending.SetResult(new() { Uptime = 5 }); await Eventually(() => source.Disposed);
    }
    private static async Task Eventually(Func<bool> check)
    {
        for (var i = 0; i < 300; i++) { if (check()) return; await Task.Delay(2); }
        Assert.Fail("Monitor state transition timed out.");
    }
}
