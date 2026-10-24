using System.Collections.Concurrent;

namespace Shou.Windows.Core.Tests;

[Collection("Operation diagnostics")]
public sealed class OperationDiagnosticsTests
{
    [Fact]
    public async Task AsyncNestedFailuresRetainTheirParentAndNeverBecomeSuccess()
    {
        var events = new ConcurrentQueue<OperationDiagnostic>();
        using var subscription = OperationDiagnostics.Source.Subscribe(new Capture(events.Enqueue));
        using var outer = OperationDiagnostics.Start("test.outer");
        await Task.Run(async () =>
        {
            await Task.Yield();
            using var inner = OperationDiagnostics.Start("test.inner");
            inner.Fail(new ShouException("permission_denied", "private details"), "configuration_register");
            inner.Complete();
        });
        outer.Complete("partial", count: 7, issueCount: 1);
        var failures = events.Where(value => value.ParentId == outer.Id && value.Event == "failed").ToArray();
        var failed = Assert.Single(failures);
        Assert.Equal("configuration_register", failed.Stage);
        Assert.DoesNotContain(events, value => value.OperationId == failed.OperationId && value.Event == "completed");
        Assert.Contains(events, value => value.OperationId == outer.Id && value.State == "partial" && value.Count == 7 && value.IssueCount == 1);
    }

    [Fact]
    public void MissingCompletionIsInterruptedAndListenerFailureCannotChangeTheOperation()
    {
        var events = new ConcurrentQueue<OperationDiagnostic>();
        using (OperationDiagnostics.Source.Subscribe(new Capture(events.Enqueue)))
        {
            string id;
            using (var unfinished = OperationDiagnostics.Start("test.unfinished")) id = unfinished.Id;
            Assert.Contains(events, value => value.OperationId == id && value.Event == "interrupted");
            Assert.DoesNotContain(events, value => value.OperationId == id && value.Event == "completed");
        }
        using var broken = OperationDiagnostics.Source.Subscribe(new Capture(_ => throw new IOException("full")));
        using var valid = OperationDiagnostics.Start("test.valid");
        valid.Complete();
    }

    private sealed class Capture(Action<OperationDiagnostic> publish) : IObserver<KeyValuePair<string, object?>>
    {
        public void OnNext(KeyValuePair<string, object?> value) { if (value.Value is OperationDiagnostic item) publish(item); }
        public void OnCompleted() { }
        public void OnError(Exception error) { }
    }
}

[CollectionDefinition("Operation diagnostics", DisableParallelization = true)]
public sealed class OperationDiagnosticsCollection;
