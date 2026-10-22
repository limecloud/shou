using System.Windows;
using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed partial class MainViewModel
{
    private DesktopPreferenceStore desktopPreferenceStore = null!;
    private DesktopPreferences savedDesktopPreferences = new();
    private UiChoice? settingsLanguage, settingsAppearance;
    private bool settingsReduceMotion;
    private string settingsStatus = "", settingsCliStatus = "", settingsDataDirectory = "", settingsVersion = "Shou";
    public UiChoice[] SettingsLanguages { get; } = [new("system", T("跟随 Windows")), new("zh-CN", "简体中文"), new("en", "English")];
    public UiChoice[] SettingsAppearances { get; } = [new("system", T("跟随 Windows")), new("light", T("浅色")), new("dark", T("深色"))];
    public UiChoice? SettingsLanguage { get => settingsLanguage; set => SetProperty(ref settingsLanguage, value); }
    public UiChoice? SettingsAppearance { get => settingsAppearance; set => SetProperty(ref settingsAppearance, value); }
    public bool SettingsReduceMotion { get => settingsReduceMotion; set => SetProperty(ref settingsReduceMotion, value); }
    public string SettingsStatus { get => settingsStatus; private set => SetProperty(ref settingsStatus, value); }
    public string SettingsCliStatus { get => settingsCliStatus; private set => SetProperty(ref settingsCliStatus, value); }
    public string SettingsDataDirectory { get => settingsDataDirectory; private set => SetProperty(ref settingsDataDirectory, value); }
    public string SettingsVersion { get => settingsVersion; private set => SetProperty(ref settingsVersion, value); }
    public string SettingsEnginePath => client.ExecutablePath;
    public bool CanChangeDesktopSettings => !IsBusy && !AiBusy;
    public IRelayCommand SaveDesktopSettingsCommand { get; private set; } = null!;
    public IRelayCommand RestartDesktopCommand { get; private set; } = null!;
    public IRelayCommand OpenDesktopDataCommand { get; private set; } = null!;
    public IRelayCommand CopyDesktopCliCommand { get; private set; } = null!;
    public IRelayCommand OpenDesktopGuideCommand { get; private set; } = null!;
    public IRelayCommand OpenDesktopReleasesCommand { get; private set; } = null!;
    public IRelayCommand OpenDesktopFeedbackCommand { get; private set; } = null!;
    public IRelayCommand OpenDesktopSourceCommand { get; private set; } = null!;
    public IRelayCommand ShowAiSettingsCommand { get; private set; } = null!;
    public IAsyncRelayCommand OpenAgentSetupCommand { get; private set; } = null!;
    public IAsyncRelayCommand InstallDesktopCliCommand { get; private set; } = null!;

    private void InitializeSettings(DesktopPreferenceStore store, DesktopPreferences preferences, string? loadIssue)
    {
        desktopPreferenceStore = store; savedDesktopPreferences = preferences;
        SettingsLanguage = SettingsLanguages.First(row => row.Id == preferences.Language);
        SettingsAppearance = SettingsAppearances.First(row => row.Id == preferences.Appearance);
        SettingsReduceMotion = preferences.ReduceMotion;
        SettingsStatus = loadIssue is null ? "" : T("无法读取已保存的界面设置，暂用默认值。保存设置可替换无效配置；清理规则与历史不受影响。");
        SaveDesktopSettingsCommand = new RelayCommand(SaveDesktopSettings, () => CanChangeDesktopSettings && SettingsLanguage is not null && SettingsAppearance is not null);
        RestartDesktopCommand = new RelayCommand(() => SettingsAction(dialogs.RestartDesktop), () => CanChangeDesktopSettings && !HasAiWork && savedDesktopPreferences.Language != UiText.RequestedLanguage);
        OpenDesktopDataCommand = new RelayCommand(() => SettingsAction(() => dialogs.RevealFolder(SettingsDataDirectory)), () => !IsBusy && !string.IsNullOrEmpty(SettingsDataDirectory));
        CopyDesktopCliCommand = new RelayCommand(() => SettingsAction(() => { Clipboard.SetText("& '" + SettingsEnginePath.Replace("'", "''") + "' --help"); SettingsStatus = T("已复制 PowerShell 帮助命令，未启动终端程序。"); }), () => !IsBusy);
        OpenDesktopGuideCommand = new RelayCommand(() => SettingsAction(() => dialogs.OpenDocumentation(UiText.Language == "zh-CN")), () => !IsBusy);
        OpenDesktopReleasesCommand = new RelayCommand(() => SettingsAction(dialogs.OpenReleases), () => !IsBusy);
        OpenDesktopFeedbackCommand = new RelayCommand(() => SettingsAction(dialogs.OpenFeedback), () => !IsBusy);
        OpenDesktopSourceCommand = new RelayCommand(() => SettingsAction(dialogs.OpenSource), () => !IsBusy);
        ShowAiSettingsCommand = new RelayCommand(() => SelectedSection = 5, () => !IsBusy);
        OpenAgentSetupCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            var setup=await client.RequestAsync("agent.setup",cancellation:Token);
            var outcome=dialogs.AgentRuleSetup(client,setup,SelectedWorkspace?.Path,Token);
            if(!string.IsNullOrEmpty(outcome)) Status=outcome;
        }), () => CanChangeDesktopSettings);
        InstallDesktopCliCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            SettingsCliStatus="";
            var installation=new WindowsCliInstallation(WindowsCliInstallation.BundledTemplate,client.ExecutablePath,WindowsCliInstallation.DefaultDirectory);
            var preview=await Task.Run(installation.Preview,Token);
            if(!dialogs.ReviewCliInstallation(preview,Token))return;
            var result=await Task.Run(()=>installation.Install(preview.Digest,Token),Token);
            SettingsCliStatus=F("CLI 命令已就绪：{0}。请保留完整 Shou 目录。安装不会修改 PATH；终端找不到 shou 时，可直接使用此完整路径。",result.Launcher);
        }), () => CanChangeDesktopSettings);
        commands.AddRange([SaveDesktopSettingsCommand, RestartDesktopCommand, OpenDesktopDataCommand, CopyDesktopCliCommand, OpenDesktopGuideCommand, OpenDesktopReleasesCommand, OpenDesktopFeedbackCommand, OpenDesktopSourceCommand, ShowAiSettingsCommand]);
        commands.Add(OpenAgentSetupCommand);
        commands.Add(InstallDesktopCliCommand);
        PropertyChanged += (_, args) => { if (args.PropertyName is nameof(IsBusy) or nameof(AiBusy)) OnPropertyChanged(nameof(CanChangeDesktopSettings)); };
        DesktopPresentation.Current.PropertyChanged += (_, _) => OnPropertyChanged(nameof(ProgressIndeterminate));
    }

    private void SaveDesktopSettings() => SettingsAction(() =>
    {
        var preferences = new DesktopPreferences(SettingsLanguage!.Id, SettingsAppearance!.Id, SettingsReduceMotion);
        desktopPreferenceStore.Save(preferences);
        savedDesktopPreferences = preferences; DesktopPresentation.Current.Apply(preferences);
        SettingsStatus = preferences.Language != UiText.RequestedLanguage ? T("设置已保存。外观与动态效果已应用，语言将在重新打开 Shou 后生效。") : T("设置已保存并应用。");
    });

    private void SettingsAction(Action action)
    {
        try { action(); }
        catch (Exception) { SettingsStatus = T("设置操作未完成。请检查本机访问权限或默认浏览器后重试；已保存的清理规则与历史会保留。"); }
    }

    internal void VerifySettingsLayout()
    {
        SettingsDataDirectory = "C:/layout-fixture/records"; SettingsVersion = "Shou 0.11.0";
        SelectedSection = 11;
        if (SettingsLanguages.Length != 3 || SettingsAppearances.Length != 3 || SettingsLanguage is null || SettingsAppearance is null)
            throw new InvalidOperationException("Desktop preference choices are incomplete.");
        SettingsStatus = T("设置已保存。外观与动态效果已应用，语言将在重新打开 Shou 后生效。");
    }
}
