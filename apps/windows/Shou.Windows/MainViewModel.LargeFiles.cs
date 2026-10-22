using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed record LargeFileTypeRow(string Id,string Name);
public sealed class LargeFileRow(string path,string root,long allocatedBytes,long logicalBytes,string? reason) : ObservableObject
{
    public string Path { get; }=path;
    public string Name => Path.Split('/').Last();
    public string AbsolutePath => root.TrimEnd('/','\\')+"/"+Path;
    public long AllocatedBytes { get; }=allocatedBytes;
    public string Size => MainViewModel.Bytes(AllocatedBytes);
    public string LogicalSize => MainViewModel.Bytes(logicalBytes);
    public string Protection => reason ?? "可选择";
    public bool Eligible => reason is null;
    private bool selected;
    public bool IsSelected { get=>selected; set=>SetProperty(ref selected,value && Eligible); }
}

public sealed partial class MainViewModel
{
    private string largeFilesFolder=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private int largeFilesMinimumMiB=50;
    private LargeFileTypeRow? selectedLargeFileType;
    private string? largeFilesScanId,largeFilesCursor;
    private (int Minimum,string Type)? largeFilesQuery;
    private long largeFilesTotalBytes;
    private int largeFilesTotalCount;
    private bool largeFilesPartial;
    private bool largeFilesBatchSelection;
    private readonly HashSet<string> largeFilesRemovedPaths=new(StringComparer.OrdinalIgnoreCase);

    public ObservableCollection<LargeFileRow> LargeFiles { get; }=[];
    public LargeFileTypeRow[] LargeFileTypes { get; }=[new("all","全部类型"),new("video","视频"),new("audio","音频"),new("image","图片"),new("archive","压缩包"),new("document","文档"),new("ai-model","AI 模型"),new("other","其他")];
    public string LargeFilesFolder { get=>largeFilesFolder; set { if(!IsBusy) SetProperty(ref largeFilesFolder,value); } }
    public int LargeFilesMinimumMiB { get=>largeFilesMinimumMiB; set { if(!IsBusy && value>=0 && SetProperty(ref largeFilesMinimumMiB,value)) LargeFilesChanged(); } }
    public LargeFileTypeRow? SelectedLargeFileType { get=>selectedLargeFileType; set { if(!IsBusy && SetProperty(ref selectedLargeFileType,value)) LargeFilesChanged(); } }
    private (int Minimum,string Type) LargeFileQuery => (LargeFilesMinimumMiB,SelectedLargeFileType?.Id ?? "all");
    private bool LargeFileResultsCurrent => largeFilesScanId is not null && largeFilesQuery==LargeFileQuery;
    public string LargeFilesSummary => $"{(largeFilesPartial ? "部分扫描 · " : "")}扫描时共 {largeFilesTotalCount} 个文件 · {Bytes(largeFilesTotalBytes)} · 已加载 {LargeFiles.Count} 个"+(largeFilesRemovedPaths.Count>0 ? $" · 已处理 {largeFilesRemovedPaths.Count} 个，请重新扫描更新统计" : "")+(LargeFileResultsCurrent ? "" : " · 应用筛选后更新结果");
    public string LargeFilesSelection => $"已选择 {LargeFiles.Count(row=>row.IsSelected)} 个 · {Bytes(LargeFiles.Where(row=>row.IsSelected).Sum(row=>row.AllocatedBytes))}";
    public IAsyncRelayCommand ChooseLargeFilesFolderCommand { get; private set; }=null!;
    public IAsyncRelayCommand ScanLargeFilesCommand { get; private set; }=null!;
    public IAsyncRelayCommand FilterLargeFilesCommand { get; private set; }=null!;
    public IAsyncRelayCommand MoreLargeFilesCommand { get; private set; }=null!;
    public IAsyncRelayCommand UseStorageForLargeFilesCommand { get; private set; }=null!;
    public IRelayCommand SelectLoadedLargeFilesCommand { get; private set; }=null!;
    public IAsyncRelayCommand SelectAllLargeFilesCommand { get; private set; }=null!;
    public IAsyncRelayCommand TrashLargeFilesCommand { get; private set; }=null!;
    public IAsyncRelayCommand PurgeLargeFilesCommand { get; private set; }=null!;
    public IRelayCommand<LargeFileRow> RevealLargeFileCommand { get; private set; }=null!;

    private void InitializeLargeFiles()
    {
        selectedLargeFileType=LargeFileTypes[0];
        ChooseLargeFilesFolderCommand=new AsyncRelayCommand(async () => {
            var path=dialogs.ChooseFolder(); if(path is null) return;
            LargeFilesFolder=path; await ScanLargeFilesAsync();
        },()=>!IsBusy);
        ScanLargeFilesCommand=new AsyncRelayCommand(ScanLargeFilesAsync,()=>!IsBusy && !string.IsNullOrWhiteSpace(LargeFilesFolder));
        FilterLargeFilesCommand=new AsyncRelayCommand(()=>RunAsync(()=>LoadLargeFilesAsync(largeFilesScanId!,false)),()=>!IsBusy && largeFilesScanId is not null);
        MoreLargeFilesCommand=new AsyncRelayCommand(()=>RunAsync(()=>LoadLargeFilesAsync(largeFilesScanId!,true)),()=>!IsBusy && LargeFileResultsCurrent && largeFilesCursor is not null);
        UseStorageForLargeFilesCommand=new AsyncRelayCommand(()=>RunAsync(async () => {
            await LoadLargeFilesAsync(storageScanId!,false); SelectedSection=4;
        }),()=>!IsBusy && storageScanId is not null);
        SelectLoadedLargeFilesCommand=new RelayCommand(()=>{
            var selected=LargeFiles.Any(row=>row.Eligible && !row.IsSelected);
            SetLargeFileSelection(selected);
        },()=>!IsBusy && LargeFileResultsCurrent && LargeFiles.Any(row=>row.Eligible));
        SelectAllLargeFilesCommand=new AsyncRelayCommand(()=>RunAsync(async () => {
            while(largeFilesCursor is not null) { Token.ThrowIfCancellationRequested(); await LoadLargeFilesAsync(largeFilesScanId!,true); }
            Token.ThrowIfCancellationRequested(); SetLargeFileSelection(true);
        }),()=>!IsBusy && LargeFileResultsCurrent && largeFilesTotalCount>0);
        bool CanRemove() => !IsBusy && LargeFileResultsCurrent && LargeFiles.Any(row=>row.IsSelected && row.Eligible);
        TrashLargeFilesCommand=new AsyncRelayCommand(()=>RemoveLargeFilesAsync("trash"),()=>trashAvailable && CanRemove());
        PurgeLargeFilesCommand=new AsyncRelayCommand(()=>RemoveLargeFilesAsync("permanent"),()=>permanentAvailable && CanRemove());
        RevealLargeFileCommand=new RelayCommand<LargeFileRow>(row=>dialogs.RevealFolder(Path.GetDirectoryName(row!.AbsolutePath)!),row=>!IsBusy && row is not null);
        commands.AddRange([ChooseLargeFilesFolderCommand,ScanLargeFilesCommand,FilterLargeFilesCommand,MoreLargeFilesCommand,UseStorageForLargeFilesCommand,SelectLoadedLargeFilesCommand,SelectAllLargeFilesCommand,TrashLargeFilesCommand,PurgeLargeFilesCommand,RevealLargeFileCommand]);
    }
    private void LargeFilesChanged()
    {
        OnPropertyChanged(nameof(LargeFilesSummary)); OnPropertyChanged(nameof(LargeFilesSelection)); RefreshCommands();
    }
    private void SetLargeFileSelection(bool selected)
    {
        largeFilesBatchSelection=true;
        try { foreach(var row in LargeFiles) row.IsSelected=selected; }
        finally { largeFilesBatchSelection=false; LargeFilesChanged(); }
    }
    private Task ScanLargeFilesAsync() => RunAsync(async () => {
        var scan=await client.RequestAsync("storage.scan",new() { ["path"]=LargeFilesFolder },Progress(),cancellation:Token);
        await LoadLargeFilesAsync(Text(scan,"scan_id"),false);
    });
    private async Task LoadLargeFilesAsync(string id,bool more)
    {
        var query=more ? largeFilesQuery!.Value : LargeFileQuery;
        var page=await client.RequestAsync("storage.large-files",new() { ["scan_id"]=id,["minimum_bytes"]=(long)query.Minimum*1024*1024,["type"]=query.Type,["cursor"]=more ? largeFilesCursor : null },cancellation:Token);
        var root=Text(page,"root_path");
        if(id!=largeFilesScanId) largeFilesRemovedPaths.Clear();
        var rows=Array(page["entries"]).Where(item=>!largeFilesRemovedPaths.Contains(Text(item?["entry"],"path"))).Select(item=>new LargeFileRow(Text(item?["entry"],"path"),root,item?["node"]?["allocated_bytes"]?.GetValue<long>() ?? 0,item?["node"]?["logical_bytes"]?.GetValue<long>() ?? 0,item?["removal_block_reason"]?.GetValue<string>())).ToArray();
        if(!more) LargeFiles.Clear();
        largeFilesScanId=id; largeFilesFolder=root; largeFilesQuery=query; largeFilesCursor=page["next_cursor"]?.GetValue<string>();
        largeFilesTotalCount=page["total_count"]?.GetValue<int>() ?? 0; largeFilesTotalBytes=page["total_allocated_bytes"]?.GetValue<long>() ?? 0; largeFilesPartial=Text(page,"status")!="complete";
        foreach(var row in rows) { row.PropertyChanged+=(_,_)=>{ if(!largeFilesBatchSelection) LargeFilesChanged(); }; LargeFiles.Add(row); }
        OnPropertyChanged(nameof(LargeFilesFolder)); LargeFilesChanged();
        Status=largeFilesPartial ? "已列出当前已测量范围内的大文件；部分位置未能扫描。" : "大文件按占用空间排序；类型按扩展名识别，请审阅后选择。";
    }
    private Task RemoveLargeFilesAsync(string action) => RunAsync(async () => {
        var chosen=LargeFiles.Where(row=>row.IsSelected && row.Eligible).ToArray();
        var receipt=await client.RequestAsync("storage.remove",new() { ["scan_id"]=largeFilesScanId,["paths"]=Strings(chosen.Select(row=>row.Path)),["action"]=action },Progress(),review=>dialogs.ConfirmAsync(review,Token),Token);
        var successful=Array(receipt["items"]).Where(item=>Text(item,"state") is "purged" or "trashed").Select(item=>Text(item,"path")).ToArray();
        foreach(var row in chosen.Where(row=>successful.Any(path=>SamePath(path,row.AbsolutePath)))) { largeFilesRemovedPaths.Add(row.Path); LargeFiles.Remove(row); }
        Completion=BuildCompletion(receipt,action); LargeFilesChanged();
        Status="所选大文件已处理，请查看逐项结果。重新扫描可更新总占用。";
        if(!Token.IsCancellationRequested) await LoadHistoryAsync();
    },cleanup:true);
}
