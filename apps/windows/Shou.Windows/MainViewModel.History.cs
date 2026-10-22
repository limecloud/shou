using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed class HistoryItemRow(string id, string path, string state, long bytes, bool canRestore, bool canPurge, string? error, string? resultingPath) : ObservableObject
{
    public HistoryFollowUpChoice Choice { get; } = new(id, canRestore, canPurge);
    public string Path { get; } = path;
    public string State { get; } = state;
    public long AllocatedBytes { get; } = bytes;
    public string Size => MainViewModel.Bytes(AllocatedBytes);
    public string? Error { get; } = error;
    public string? ResultingPath { get; } = resultingPath;
    public bool Eligible => Choice.CanRestore || Choice.CanPurge;
    public string Actions => Choice.CanRestore && Choice.CanPurge ? T("恢复 / 永久删除") : Choice.CanRestore ? T("恢复") : Choice.CanPurge ? T("永久删除") : T("无可执行操作");
    private bool selected;
    public bool IsSelected { get => selected; set => SetProperty(ref selected, value && Eligible); }
}

public sealed partial class MainViewModel
{
    private bool changingHistorySelection;
    public bool HistorySelectionEnabled => !IsBusy;
    public string HistorySelectionSummary
    {
        get
        {
            var selected = HistoryItems.Where(item => item.IsSelected).ToArray();
            return F("已选择 {0} 项 · {1}",selected.Length,Bytes(selected.Sum(item => item.AllocatedBytes))) +
                (selected.Length > HistoryFollowUpSelection.MaximumItems ? T(" · 每次最多 500 项，请减少选择") : "");
        }
    }
    public IRelayCommand SelectHistoryItemsCommand { get; private set; } = null!;
    public IRelayCommand ClearHistoryItemsCommand { get; private set; } = null!;
    public IRelayCommand InspectHistoryCommand { get; private set; } = null!;

    private void InitializeHistory()
    {
        SelectHistoryItemsCommand = new RelayCommand(() => SetHistorySelection(true), () => !IsBusy && HistoryItems.Any(item => item.Eligible && !item.IsSelected));
        ClearHistoryItemsCommand = new RelayCommand(() => SetHistorySelection(false), () => !IsBusy && HistoryItems.Any(item => item.IsSelected));
        InspectHistoryCommand = new RelayCommand(() => dialogs.InspectHistory(client, SelectedHistory!.Id), () => !IsBusy && SelectedHistory is not null);
        commands.AddRange([SelectHistoryItemsCommand, ClearHistoryItemsCommand, InspectHistoryCommand]);
    }
    private HistoryFollowUpChoice[] SelectedHistoryChoices() => HistoryItems.Where(item => item.IsSelected).Select(item => item.Choice).ToArray();
    private bool CanFollowUpHistory(string action) => SelectedHistory is not null && HistoryFollowUpSelection.CanSubmit(action, SelectedHistoryChoices());

    private void ResetHistoryItems(HistoryRow? receipt)
    {
        foreach (var item in HistoryItems) item.PropertyChanged -= HistoryItemChanged;
        HistoryItems.Clear();
        foreach (var item in receipt?.Items ?? [])
        {
            item.IsSelected = false;
            item.PropertyChanged += HistoryItemChanged;
            HistoryItems.Add(item);
        }
        HistorySelectionChanged();
    }
    private void HistoryItemChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (!changingHistorySelection && args.PropertyName == nameof(HistoryItemRow.IsSelected)) HistorySelectionChanged();
    }
    private void SetHistorySelection(bool selected)
    {
        changingHistorySelection = true;
        try { foreach (var item in HistoryItems) item.IsSelected = selected; }
        finally { changingHistorySelection = false; HistorySelectionChanged(); }
    }
    private void HistorySelectionChanged()
    {
        OnPropertyChanged(nameof(HistorySelectionSummary));
        RefreshCommands();
    }
}
