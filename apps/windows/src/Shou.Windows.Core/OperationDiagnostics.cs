using System.Diagnostics;

namespace Shou.Windows.Core;

/// <summary>Operational evidence only; never substitutes for the durable mutation journal.</summary>
public static class OperationDiagnostics
{
    public static DiagnosticListener Source { get; } = new("Shou.Windows.Operations");
    private static readonly AsyncLocal<OperationScope?> Current = new();

    public static OperationScope Start(string operation) => new(operation);

    public sealed class OperationScope : IDisposable
    {
        private readonly OperationScope? parent;
        private readonly long started = Stopwatch.GetTimestamp();
        private readonly string operation;
        private bool finished, disposed;
        public string Id { get; } = Guid.NewGuid().ToString("N");

        internal OperationScope(string operation)
        {
            this.operation = operation;
            parent = Current.Value;
            Current.Value = this;
            Emit("started");
        }

        public void Issue(string code, string stage, WindowsPath? path = null, string? ownerKind = null) =>
            Emit("issue", code: code, stage: stage, path: path, ownerKind: ownerKind);

        public void Step(string stage, WindowsPath? path = null, string? ownerKind = null) =>
            Emit("stage", stage: stage, path: path, ownerKind: ownerKind);

        public void Fail(Exception error, string? stage = null)
        {
            if (finished) return;
            finished = true;
            Emit(error is OperationCanceledException ? "cancelled" : "failed", error: error, stage: stage);
        }

        public void Complete(string state = "complete", long? count = null, long? issueCount = null)
        {
            if (finished) return;
            finished = true;
            Emit("completed", state: state, count: count, issueCount: issueCount);
        }

        private void Emit(string kind, string? state = null, string? code = null, string? stage = null,
            WindowsPath? path = null, string? ownerKind = null, Exception? error = null, long? count = null, long? issueCount = null)
        {
            // Diagnostics must not make an otherwise valid read fail or authorize a mutation.
            try
            {
                if (Source.IsEnabled()) Source.Write(kind, new OperationDiagnostic(Id, parent?.Id, operation, kind,
                    Stopwatch.GetElapsedTime(started).TotalMilliseconds, state, code, stage, path, ownerKind, error, count, issueCount));
            }
            catch (Exception) { }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (!finished) Emit("interrupted");
            if (ReferenceEquals(Current.Value, this)) Current.Value = parent;
        }
    }
}

public sealed record OperationDiagnostic(string OperationId, string? ParentId, string Operation, string Event,
    double DurationMs, string? State = null, string? Code = null, string? Stage = null, WindowsPath? Path = null,
    string? OwnerKind = null, Exception? Error = null, long? Count = null, long? IssueCount = null);
