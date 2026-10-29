using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

/// <summary>Selection intent is immediate; only completed, current reviews can enter a frozen batch.</summary>
public sealed class ApplicationSelectionViewModel(Func<ApplicationUninstallViewModel> createReview) : IDisposable
{
    private readonly Dictionary<string, ApplicationSelectionItem> items = new(StringComparer.Ordinal);
    private readonly Queue<string> queue = new();
    private Task? reviewing;
    private bool disposed;
    private bool stopRequested;
    public event EventHandler? Changed;
    public IEnumerable<ApplicationSelectionItem> Selected => items.Values.Where(item => item.IsSelected);
    public int SelectedCount => Selected.Count();
    public bool IsPreparing { get; private set; }
    public bool IsExecuting { get; private set; }
    public bool IsReviewing { get; private set; }
    public bool IsClosing { get; private set; }
    public bool CanChangeSelection => !disposed && !IsPreparing && !IsExecuting && !IsClosing && !items.Values.Any(item => item.Review.State is ApplicationUninstallPageState.Authorizing or ApplicationUninstallPageState.Closing);
    public bool CanExecute => CanChangeSelection && !IsReviewing && SelectedCount > 0 && Selected.All(item => item.Review.ExecutionAvailable && item.Review.CanPreparePlan);
    public bool CanCloseSelected => CanChangeSelection && !IsReviewing && Selected.Any(item => item.Review.CanClose);

    public async Task CloseSelectedAndRecheckAsync()
    {
        if (!CanCloseSelected) return;
        var frozen = Selected.Where(item => item.Review.CanClose).ToArray();
        stopRequested = false; IsClosing = true; Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            foreach (var item in frozen)
            {
                if (disposed || stopRequested) break;
                await item.Review.CloseAndRecheckAsync();
            }
        }
        finally { IsClosing = false; if (!disposed) Changed?.Invoke(this, EventArgs.Empty); }
    }

    public ApplicationSelectionItem Item(string id)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!items.TryGetValue(id, out var item))
        {
            item = new(id, createReview());
            item.PropertyChanged += ItemChanged;
            items.Add(id, item);
        }
        return item;
    }
    public async Task SelectAsync(string id, bool selected)
    {
        if (!CanChangeSelection) return;
        var item = Item(id);
        item.SetSelected(selected);
        if (!selected) { Changed?.Invoke(this, EventArgs.Empty); return; }
        if (item.Review.RequiresAuthorization && !IsReviewing) await item.Review.PrepareAuthorizationAsync(id);
        else await InspectAsync(id, refresh: false);
    }
    public Task InspectAsync(string id, bool refresh = true)
    {
        if (!CanChangeSelection) return Task.CompletedTask;
        var item = Item(id);
        if (!refresh && (item.Review.Review is not null || item.Review.IsBusy || item.IsQueued)) return reviewing ?? Task.CompletedTask;
        if (!item.IsQueued && !item.Review.IsBusy) { item.SetQueued(true); queue.Enqueue(id); }
        if (!IsReviewing) { IsReviewing = true; reviewing = DrainAsync(); }
        Changed?.Invoke(this, EventArgs.Empty);
        return reviewing ?? Task.CompletedTask;
    }
    private async Task DrainAsync()
    {
        try
        {
        while (!disposed && queue.TryDequeue(out var id))
        {
            var item = items[id];
            item.SetQueued(false);
            await item.Review.InspectAsync(id);
            if (disposed) return;
            if (item.IsSelected && item.Review.RequiresAuthorization) await item.Review.PrepareAuthorizationAsync(id);
        }
        }
        finally { IsReviewing = false; if (!disposed) Changed?.Invoke(this, EventArgs.Empty); }
    }
    public async Task ExecuteSelectedAsync(Func<ApplicationUninstallPlan, IApplicationUninstallConfirmation> confirmation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!CanExecute) throw new ShouException("confirmation_required", "Finish reviewing every selected installation.");
        var frozen = Selected.OrderBy(item => item.Id, StringComparer.Ordinal).ToArray();
        stopRequested = false; IsPreparing = true; Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            foreach (var item in frozen)
            {
                var expected = item.Review.Review!;
                await item.Review.PreparePlanAsync();
                if (disposed || stopRequested || item.Review.Plan is not { } plan || plan.Review.Digest != expected.Digest ||
                    plan.Review.Application.Id != item.Id || plan.Review.Installation.Identity != expected.Installation.Identity) return;
            }
            IsPreparing = false; IsExecuting = true; Changed?.Invoke(this, EventArgs.Empty);
            foreach (var item in frozen)
            {
                if (disposed || stopRequested || item.Review.Plan is not { } plan || !item.Review.CanExecute) break;
                await item.Review.ExecuteAsync(confirmation(plan));
                // Uncertain/failed results require a new review; never retry or dispatch later installers automatically.
                if (item.Review.Execution?.State != ApplicationUninstallState.Completed) break;
                item.SetSelected(false);
            }
        }
        finally { IsPreparing = false; IsExecuting = false; if (!disposed) Changed?.Invoke(this, EventArgs.Empty); }
    }
    public void Clear()
    {
        if (!CanChangeSelection) return;
        foreach (var item in items.Values) item.SetSelected(false);
        Changed?.Invoke(this, EventArgs.Empty);
    }
    public void Reset()
    {
        if (!CanChangeSelection || IsReviewing) return;
        foreach (var item in items.Values) { item.PropertyChanged -= ItemChanged; item.Dispose(); }
        items.Clear(); Changed?.Invoke(this, EventArgs.Empty);
    }
    public void Stop()
    {
        stopRequested = true;
        queue.Clear();
        foreach (var item in items.Values) { item.SetQueued(false); item.Review.Cancel(); }
    }
    private void ItemChanged(object? sender, PropertyChangedEventArgs args) => Changed?.Invoke(this, EventArgs.Empty);
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        queue.Clear();
        foreach (var item in items.Values) { item.PropertyChanged -= ItemChanged; item.Dispose(); }
        items.Clear();
        GC.SuppressFinalize(this);
    }
}

public sealed class ApplicationSelectionItem : INotifyPropertyChanged, IDisposable
{
    public string Id { get; }
    public ApplicationUninstallViewModel Review { get; }
    public bool IsSelected { get; private set; }
    public bool IsQueued { get; private set; }
    public event PropertyChangedEventHandler? PropertyChanged;
    internal ApplicationSelectionItem(string id, ApplicationUninstallViewModel review)
    { Id = id; Review = review; Review.PropertyChanged += ReviewChanged; }
    internal void SetSelected(bool selected) { if (IsSelected == selected) return; IsSelected = selected; PropertyChanged?.Invoke(this, new(nameof(IsSelected))); }
    internal void SetQueued(bool queued) { if (IsQueued == queued) return; IsQueued = queued; PropertyChanged?.Invoke(this, new(nameof(IsQueued))); }
    private void ReviewChanged(object? sender, PropertyChangedEventArgs args)
    { if (args.PropertyName == nameof(ApplicationUninstallViewModel.State)) PropertyChanged?.Invoke(this, new(nameof(Review))); }
    public void Dispose() { Review.PropertyChanged -= ReviewChanged; Review.Dispose(); GC.SuppressFinalize(this); }
}
