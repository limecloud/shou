using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public interface IStartupControlOperations
{
    bool ExecutionAvailable { get; }
    Task<StartupControlReview> InspectAsync(string taskPath, StartupControlAction action, CancellationToken token);
    Task<StartupControlExecution> ExecuteAsync(StartupControlReview review, IStartupControlConfirmation confirmation, CancellationToken token);
    Task<StartupControlExecution> ReadAsync(string operationId, CancellationToken token);
}
public enum StartupControlPageState { Empty, Reviewing, Reviewed, Changing, Reading, Completed, Cancelled, Failed }

public sealed class StartupControlViewModel(IStartupControlOperations operations) : INotifyPropertyChanged, IDisposable
{
    private CancellationTokenSource? operation;
    private long generation;
    private bool disposed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public StartupControlPageState State { get; private set; }
    public string? TaskPath { get; private set; }
    public StartupControlReview? Review { get; private set; }
    public StartupControlExecution? Execution { get; private set; }
    public string? OperationId { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool ExecutionAvailable => operations.ExecutionAvailable;
    public bool IsExecuting => State == StartupControlPageState.Changing;
    public bool IsBusy => State is StartupControlPageState.Reviewing or StartupControlPageState.Changing or StartupControlPageState.Reading;
    public bool StopRequested => operation?.IsCancellationRequested == true;

    public void Bind(StartupItem? item)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var path = item?.Source == StartupSource.ScheduledTasks ? item.RegistrationKey : null;
        if (path == TaskPath) return;
        if (IsExecuting) throw new ShouException("store_busy", "Wait for the current startup operation result before changing selection.");
        generation++; operation?.Cancel(); operation = null;
        TaskPath = path; Review = null; Execution = null; OperationId = null; ErrorCode = null;
        State = StartupControlPageState.Empty; Notify();
    }

    public async Task InspectAsync(StartupControlAction action)
    {
        using var diagnostic = OperationDiagnostics.Start("ui.startup.inspect");
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsExecuting || TaskPath is not { } path) return;
        var current = ++generation;
        operation?.Cancel();
        using var token = new CancellationTokenSource(); operation = token;
        Review = null; Execution = null; OperationId = null; ErrorCode = null;
        State = StartupControlPageState.Reviewing; Notify();
        try
        {
            var review = await operations.InspectAsync(path, action, token.Token);
            token.Token.ThrowIfCancellationRequested();
            if (disposed || current != generation) return;
            if (review is null || !string.Equals(review.Task?.TaskPath, path, StringComparison.OrdinalIgnoreCase) || review.Action != action)
                throw new ShouException("startup_inspection_invalid", "The review did not match the selected task and action.");
            Review = review; State = StartupControlPageState.Reviewed;
        }
        catch (Exception error) { diagnostic.Fail(error); Fail(error, current, token); }
        finally { diagnostic.Complete(disposed || current != generation ? "superseded" : State.ToString().ToLowerInvariant()); Finish(current); }
    }

    public async Task ExecuteAsync(IStartupControlConfirmation confirmation)
    {
        using var diagnostic = OperationDiagnostics.Start("ui.startup.execute");
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy || Review is not { CanChange: true } review) return;
        if (!ExecutionAvailable) { ErrorCode = "unsupported_capability"; Notify(); return; }
        var current = ++generation;
        using var token = new CancellationTokenSource(); operation = token;
        Review = null; Execution = null; ErrorCode = null; OperationId = review.Id;
        State = StartupControlPageState.Changing; Notify();
        try
        {
            // Do not abandon a dispatched operation when Stop is requested; retain its actual terminal record.
            var execution = await operations.ExecuteAsync(review, confirmation, token.Token);
            if (disposed || current != generation) return;
            if (!Matches(execution, review.Id) || execution.Review.Digest != review.Digest)
                throw new ShouException("startup_result_invalid", "The startup result did not match the confirmed operation.");
            Execution = execution; State = StartupControlPageState.Completed;
        }
        catch (Exception error) { diagnostic.Fail(error); Fail(error, current, token); }
        finally { diagnostic.Complete(disposed || current != generation ? "superseded" : State.ToString().ToLowerInvariant()); Finish(current); }
    }

    public async Task ReadAsync()
    {
        using var diagnostic = OperationDiagnostics.Start("ui.startup.read");
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy || OperationId is not { } id) return;
        var current = ++generation;
        using var token = new CancellationTokenSource(); operation = token;
        ErrorCode = null; State = StartupControlPageState.Reading; Notify();
        try
        {
            var execution = await operations.ReadAsync(id, token.Token);
            token.Token.ThrowIfCancellationRequested();
            if (disposed || current != generation) return;
            if (!Matches(execution, id)) throw new ShouException("startup_result_invalid", "The startup record did not match the selected task.");
            Execution = execution; State = StartupControlPageState.Completed;
        }
        catch (Exception error) { diagnostic.Fail(error); Fail(error, current, token); }
        finally { diagnostic.Complete(disposed || current != generation ? "superseded" : State.ToString().ToLowerInvariant()); Finish(current); }
    }
    private bool Matches(StartupControlExecution? value, string id) => value is not null && value.Id == id && value.Review?.Id == id &&
        string.Equals(value.Review.Task?.TaskPath, TaskPath, StringComparison.OrdinalIgnoreCase);
    private void Fail(Exception error, long current, CancellationTokenSource token)
    {
        if (disposed || current != generation) return;
        State = error is OperationCanceledException && token.IsCancellationRequested ? StartupControlPageState.Cancelled : StartupControlPageState.Failed;
        ErrorCode = State == StartupControlPageState.Cancelled ? null : error is ShouException known ? known.Code : "startup_control_failed";
    }
    private void Finish(long current) { if (!disposed && generation == current) { operation = null; Notify(); } }
    public void Cancel() { operation?.Cancel(); Notify(); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; generation++; operation?.Cancel(); operation = null;
        GC.SuppressFinalize(this);
    }
    private void Notify() { if (!disposed) PropertyChanged?.Invoke(this, new(nameof(State))); }
}
