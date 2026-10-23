namespace Shou.Windows.Core.Tests;

/// <summary>Expires deadline timers at a chosen operation boundary without depending on host scheduling.</summary>
internal sealed class ManualDeadlineClock : TimeProvider
{
    private readonly List<Timer> timers = [];
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new Timer(callback, state);
        timers.Add(timer);
        return timer;
    }
    public void Expire() { foreach (var timer in timers.ToArray()) timer.Fire(); }
    private sealed class Timer(TimerCallback callback, object? state) : ITimer
    {
        private bool disposed;
        public void Fire() { if (!disposed) callback(state); }
        public bool Change(TimeSpan dueTime, TimeSpan period) => !disposed;
        public void Dispose() => disposed = true;
        public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    }
}
