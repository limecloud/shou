using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public interface ICleanupExecutionOperations
{
    bool ExecutionAvailable { get; }
    Task<CleanupExecution> ExecuteAsync(string planId, ICleanupConfirmation confirmation, CancellationToken cancellationToken);
    Task<CleanupExecution?> ReadExecutionAsync(string planId, CancellationToken cancellationToken);
}

public enum CleanupExecutionPageState { Empty, Planned, Executing, Reading, Result, Cancelled, Failed }

/// <summary>Owns one current confirmation attempt and its recorded outcome; stopping never erases a returned mutation result.</summary>
public sealed class CleanupExecutionViewModel(ICleanupExecutionOperations operations, TimeProvider? timeProvider = null) : INotifyPropertyChanged, IDisposable
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private CancellationTokenSource? operation;
    private long generation;
    private bool disposed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public CleanupExecutionPageState State { get; private set; }
    public CleanupPlan? Plan { get; private set; }
    public CleanupPlan? AttemptedPlan { get; private set; }
    public CleanupExecution? Execution { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool StopRequested { get; private set; }
    public bool ExecutionAvailable => operations.ExecutionAvailable;
    public bool IsExecuting => State == CleanupExecutionPageState.Executing;
    public bool IsBusy => IsExecuting || State == CleanupExecutionPageState.Reading;
    public bool CanExecute => !IsBusy && ExecutionAvailable && Plan is { Action: CleanupAction.Permanent } plan &&
        plan.Id != AttemptedPlan?.Id && plan.CreatedAt <= clock.GetUtcNow() && clock.GetUtcNow() < plan.ExpiresAt;
    public bool CanReadExecution => !IsBusy && AttemptedPlan is not null;

    public void BindPlan(CleanupPlan? plan)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsExecuting) return;
        generation++;
        operation?.Cancel();
        operation = null;
        Plan = plan?.Id == AttemptedPlan?.Id ? null : plan;
        StopRequested = false;
        if (Plan is not null)
        {
            AttemptedPlan = null;
            Execution = null;
            ErrorCode = null;
            State = CleanupExecutionPageState.Planned;
        }
        else State = AttemptedPlan is null ? CleanupExecutionPageState.Empty : Execution is null ? CleanupExecutionPageState.Failed : CleanupExecutionPageState.Result;
        Notify();
    }

    public Task ExecuteAsync(ICleanupConfirmation confirmation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        ArgumentNullException.ThrowIfNull(confirmation);
        if (!ExecutionAvailable) throw new ShouException("unsupported_capability", "Cleanup execution awaits native Windows acceptance.");
        if (!CanExecute || Plan is not { } plan) throw new ShouException("plan_stale", "Prepare and confirm a current permanent-cleanup plan.");
        return RunAsync(plan, confirmation);
    }

    public Task ReadExecutionAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!CanReadExecution || AttemptedPlan is not { } plan) throw new ShouException("invalid_argument", "Wait for the current attempt before reading its record.");
        return RunAsync(plan, null);
    }

    private async Task RunAsync(CleanupPlan expected, ICleanupConfirmation? confirmation)
    {
        var reading = confirmation is null;
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource();
        operation = current;
        Plan = null;
        AttemptedPlan = expected;
        Execution = null;
        ErrorCode = null;
        StopRequested = false;
        State = reading ? CleanupExecutionPageState.Reading : CleanupExecutionPageState.Executing;
        Notify();
        try
        {
            var result = reading ? await operations.ReadExecutionAsync(expected.Id, current.Token) :
                await operations.ExecuteAsync(expected.Id, confirmation!, current.Token);
            if (disposed || currentGeneration != generation) return;
            if (reading) current.Token.ThrowIfCancellationRequested();
            if (result is null)
            {
                ErrorCode = "execution_not_recorded";
                State = CleanupExecutionPageState.Result;
                return;
            }
            if (result.PlanId != expected.Id || result.PlanDigest != expected.Digest || result.Action != expected.Action ||
                !Enum.IsDefined(result.State) || result.Items.IsDefault || result.Items.Length != expected.Items.Length ||
                result.Items.Select(item => item.ItemId).Distinct().Count() != result.Items.Length ||
                result.Items.Any(item => !Enum.IsDefined(item.State) || !expected.Items.Any(target => target.Id == item.ItemId)))
                throw new ShouException("store_corrupt", "The cleanup result does not belong to the reviewed plan.");
            Execution = result;
            State = CleanupExecutionPageState.Result;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (disposed || currentGeneration != generation) return;
            State = CleanupExecutionPageState.Cancelled;
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            if (disposed || currentGeneration != generation) return;
            ErrorCode = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : error is IOException ? "io_error" : "internal_error";
            State = CleanupExecutionPageState.Failed;
        }
        finally
        {
            if (!disposed && currentGeneration == generation) { operation = null; Notify(); }
        }
    }

    public void Cancel()
    {
        if (disposed || operation is null || StopRequested) return;
        StopRequested = true;
        operation.Cancel();
        Notify();
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        generation++;
        operation?.Cancel();
        operation = null;
        Plan = AttemptedPlan = null;
        Execution = null;
        ErrorCode = null;
        StopRequested = false;
        State = CleanupExecutionPageState.Empty;
        GC.SuppressFinalize(this);
    }
    private void Notify()
    {
        if (!disposed) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }
}
