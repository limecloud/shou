using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed record PrivacyRangeRow(string Id, string Name);
public sealed class PrivacySourceRow(string id, string browser, string profile, string kind, string status, long? records, string? reason) : ObservableObject
{
    public string Id { get; } = id;
    public string Browser { get; } = browser;
    public string Profile { get; } = profile;
    public string Kind { get; } = kind;
    public string DataKind => Kind == "history" ? T("浏览历史") : Kind == "cookies" ? "Cookie" : Kind;
    public long? RecordCount { get; } = records;
    public string Count => RecordCount?.ToString("N0") ?? "—";
    public bool Eligible => status == "ready" && RecordCount is > 0;
    public string Status => status switch { "ready" => T("可审阅"), "empty" => T("此时间范围没有记录"), "browser-running" => T("浏览器正在运行"), "permission-required" => T("没有读取权限"), "unsupported" => T("此来源不支持"), "schema-unsupported" => T("数据库格式不支持，保留"), _ => T("当前无法核验") };
    public string Details => reason ?? "";
    private bool signOutAllowed, selected;
    public bool CanSelect => Eligible && (Kind != "cookies" || signOutAllowed);
    public bool IsSelected { get => selected; set => SetProperty(ref selected, value && CanSelect); }
    public void AllowSignOut(bool allowed) { signOutAllowed = allowed; if (!CanSelect) IsSelected = false; OnPropertyChanged(nameof(CanSelect)); }
}
public sealed record PrivacyReceiptRow(string Id, string Summary, string Details);

public sealed partial class MainViewModel
{
    private bool privacyAvailable, privacySignOut;
    private string? privacyScanId;
    private PrivacyRangeRow? selectedPrivacyRange;
    private string privacyStatus = T("先关闭浏览器，再扫描并逐项选择隐私来源。"), privacyResult = "";
    public PrivacyRangeRow[] PrivacyRanges { get; } = [new("last-hour", T("最近一小时")), new("last-day", T("最近 24 小时")), new("last-seven-days", T("最近七天")), new("all-time", T("全部时间"))];
    public ObservableCollection<PrivacySourceRow> PrivacySources { get; } = [];
    public ObservableCollection<PrivacyReceiptRow> PrivacyReceipts { get; } = [];
    public PrivacyRangeRow? SelectedPrivacyRange { get => selectedPrivacyRange; set { if (!IsBusy && SetProperty(ref selectedPrivacyRange, value)) { ClearPrivacyScan(); PrivacyStatus = T("时间范围已改变，请重新扫描。"); } } }
    public bool PrivacySignOut { get => privacySignOut; set { if (!IsBusy && SetProperty(ref privacySignOut, value)) { foreach (var row in PrivacySources) row.AllowSignOut(value); PrivacySelectionChanged(); } } }
    public bool PrivacyCanEdit => !IsBusy && privacyAvailable;
    public string PrivacyStatus { get => privacyStatus; private set => SetProperty(ref privacyStatus, value); }
    public string PrivacyResult { get => privacyResult; private set => SetProperty(ref privacyResult, value); }
    public string PrivacySelectionSummary => F("已选 {0} 个来源 · {1:N0} 条记录",PrivacySources.Count(row => row.IsSelected),PrivacySources.Where(row => row.IsSelected).Sum(row => row.RecordCount ?? 0));
    public IAsyncRelayCommand ScanPrivacyCommand { get; private set; } = null!;
    public IAsyncRelayCommand CleanPrivacyCommand { get; private set; } = null!;
    public IAsyncRelayCommand PrivacyHistoryCommand { get; private set; } = null!;
    public IRelayCommand ClearPrivacySelectionCommand { get; private set; } = null!;

    private void InitializePrivacy()
    {
        selectedPrivacyRange = PrivacyRanges[0];
        ScanPrivacyCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            ClearPrivacyScan(); PrivacyResult = "";
            var scan = await client.RequestAsync("privacy.scan", new() { ["range"] = SelectedPrivacyRange!.Id }, Progress(), cancellation: Token);
            privacyScanId = Text(scan, "id"); privacySignOut = false; OnPropertyChanged(nameof(PrivacySignOut));
            foreach (var source in Array(scan["sources"]))
            {
                var definition = source!["definition"]!;
                var row = new PrivacySourceRow(Text(source, "id"), Text(definition, "browser_name"), Text(definition, "profile"), Text(definition, "kind"), Text(source, "status"), source["record_count"]?.GetValue<long>(), source["reason"]?.GetValue<string>());
                row.PropertyChanged += (_, change) => { if (change.PropertyName == nameof(PrivacySourceRow.IsSelected)) PrivacySelectionChanged(); };
                PrivacySources.Add(row);
            }
            PrivacyStatus = F("已统计 {0} 个来源，未自动选择任何项目。数据库格式或状态无法核验的来源会保留。",PrivacySources.Count);
            PrivacySelectionChanged();
        }), () => PrivacyCanEdit && SelectedPrivacyRange is not null);
        CleanPrivacyCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            var selected = PrivacySources.Where(row => row.IsSelected && row.CanSelect).Select(row => row.Id).ToArray();
            PrivacyResult = "";
            try
            {
                var receipt = await client.RequestAsync("privacy.clean", new() { ["scan_id"] = privacyScanId, ["source_ids"] = Strings(selected), ["sign_out"] = PrivacySignOut }, Progress(), review => dialogs.ConfirmAsync(review, Token), Token);
                PrivacyResult = ReceiptDetails(receipt);
                PrivacyStatus = Text(receipt, "state") == "completed" ? T("所选隐私来源清理完成。记录无法恢复。") : T("部分来源未完成，请查看逐项回执；不会自动重试。");
                if (!Token.IsCancellationRequested) await LoadPrivacyHistoryAsync();
            }
            finally { ClearPrivacyScan(); }
        }), () => PrivacyCanEdit && privacyScanId is not null && PrivacySources.Any(row => row.IsSelected && row.CanSelect));
        PrivacyHistoryCommand = new AsyncRelayCommand(() => RunAsync(LoadPrivacyHistoryAsync), () => PrivacyCanEdit);
        ClearPrivacySelectionCommand = new RelayCommand(() => { foreach (var row in PrivacySources) row.IsSelected = false; PrivacySelectionChanged(); }, () => PrivacyCanEdit && PrivacySources.Any(row => row.IsSelected));
        commands.AddRange([ScanPrivacyCommand, CleanPrivacyCommand, PrivacyHistoryCommand, ClearPrivacySelectionCommand]);
    }
    private void ClearPrivacyScan() { privacyScanId = null; PrivacySources.Clear(); privacySignOut = false; OnPropertyChanged(nameof(PrivacySignOut)); PrivacySelectionChanged(); }
    private void PrivacySelectionChanged() { OnPropertyChanged(nameof(PrivacySelectionSummary)); RefreshCommands(); }
    private static string ReceiptDetails(JsonNode receipt) => string.Join("\n", Array(receipt["items"]).Select(item => F("{0} · 已删除 {1:N0} 条 · {2}",Text(item, "source_id"),item?["removed_records"]?.GetValue<long>() ?? 0,Text(item, "state")) + (item?["reason"]?.GetValue<string>() is { } reason ? " · " + reason : "")));
    private async Task LoadPrivacyHistoryAsync()
    {
        var history = await client.RequestAsync("privacy.history", cancellation: Token);
        PrivacyReceipts.Clear();
        foreach (var receipt in Array(history["entries"]))
        {
            var created = DateTimeOffset.TryParse(Text(receipt, "created_at"), out var date) ? date.ToLocalTime().ToString("g") : "";
            PrivacyReceipts.Add(new(Text(receipt, "id"), created + " · " + Text(receipt, "state"), ReceiptDetails(receipt!)));
        }
    }
    internal void VerifyPrivacyLayout()
    {
        privacyAvailable = true; ClearPrivacyScan();
        PrivacySources.Add(new("fixture-history", "Chromium", "Profile 中文", "history", "ready", 12, null));
        PrivacySources.Add(new("fixture-cookie", "Chromium", "Profile 中文", "cookies", "ready", 3, null));
        PrivacySources.Add(new("fixture-blocked", "Firefox", "fixture.default", "history", "browser-running", null, "application_running"));
        if (PrivacySources.Any(row => row.IsSelected) || PrivacySources[1].CanSelect || PrivacySources[2].CanSelect) throw new InvalidOperationException("Privacy defaults selected or enabled an unavailable source.");
        PrivacySources[1].AllowSignOut(true); PrivacySources[1].IsSelected = true; PrivacySources[1].AllowSignOut(false);
        if (PrivacySources[1].IsSelected) throw new InvalidOperationException("Cookie selection survived withdrawal of consent.");
        PrivacyReceipts.Add(new("fixture-receipt", "生成回执 · partial", "fixture-source · 已删除 2 条 · completed\nfixture-blocked · 已删除 0 条 · failed"));
        OnPropertyChanged(nameof(PrivacyCanEdit)); PrivacySelectionChanged();
    }
}
