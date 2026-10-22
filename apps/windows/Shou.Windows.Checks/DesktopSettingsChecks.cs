using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Shou.Windows.Services;

internal static class DesktopSettingsChecks
{
    private static void Require(bool condition) { if (!condition) throw new Exception("Desktop settings check failed."); }
    private static void Invalid(Action action)
    {
        try { action(); }
        catch (Exception error) when (error is FormatException or JsonException) { return; }
        throw new Exception("Invalid desktop preferences were accepted.");
    }

    public static async Task Run(Func<string, Func<Task>, Task> check)
    {
        await check("界面偏好使用独占夹具验证默认值和持久化往返", () =>
        {
            var fixture = Directory.CreateTempSubdirectory("shou-desktop-preferences-");
            try
            {
                var path = Path.Combine(fixture.FullName, "desktop", "preferences.json");
                var store = new DesktopPreferenceStore(path);
                Require(store.Read() == new DesktopPreferences() && !File.Exists(path));
                foreach (var language in new[] { "system", "zh-CN", "en" })
                foreach (var appearance in new[] { "system", "light", "dark" })
                foreach (var reduceMotion in new[] { false, true })
                {
                    var expected = new DesktopPreferences(language, appearance, reduceMotion);
                    store.Save(expected);
                    Require(new DesktopPreferenceStore(path).Read() == expected);
                    Require(!Directory.EnumerateFiles(Path.GetDirectoryName(path)!, ".preferences-*.tmp").Any());
                }
            }
            finally { fixture.Delete(recursive: true); }
            return Task.CompletedTask;
        });
        await check("界面偏好拒绝重复未知字段、错误版本类型与超限输入", () =>
        {
            var fixture = Directory.CreateTempSubdirectory("shou-desktop-invalid-");
            try
            {
                var path = Path.Combine(fixture.FullName, "preferences.json");
                var store = new DesktopPreferenceStore(path);
                const string valid = """{"version":1,"language":"system","appearance":"system","reduce_motion":false}""";
                foreach (var value in new[] {
                    "{}", "[]", "null", "{", valid.Replace("\"version\":1", "\"version\":2"),
                    valid.Replace("\"version\":1", "\"version\":1.5"), valid.Replace("\"version\":1", "\"version\":\"1\""),
                    valid.Replace("\"language\":\"system\"", "\"language\":null"),
                    valid.Replace("\"language\":\"system\"", "\"language\":false"),
                    valid.Replace("\"language\":\"system\"", "\"language\":\"fr\""),
                    valid.Replace("\"appearance\":\"system\"", "\"appearance\":\"auto\""),
                    valid.Replace("\"reduce_motion\":false", "\"reduce_motion\":0"),
                    valid.Replace("\"reduce_motion\":false", "\"reduce_motion\":\"false\""),
                    valid.Replace("\"version\":1", "\"version\":1,\"version\":1"),
                    valid.Replace("\"version\":1", "\"version\":1,\"extra\":true"),
                    valid.Replace(",\"reduce_motion\":false", ""), valid + new string(' ', 8192)
                })
                {
                    File.WriteAllText(path, value);
                    Invalid(() => store.Read());
                    Require(File.ReadAllText(path) == value);
                }
            }
            finally { fixture.Delete(recursive: true); }
            return Task.CompletedTask;
        });
        await check("偏好保存失败保留旧文件并清理本次临时文件", () =>
        {
            var fixture = Directory.CreateTempSubdirectory("shou-desktop-save-failure-");
            try
            {
                var path = Path.Combine(fixture.FullName, "preferences.json");
                var store = new DesktopPreferenceStore(path);
                store.Save(new("en", "dark", true));
                var original = File.ReadAllBytes(path);
                Invalid(() => store.Save(new("invalid", "dark")));
                Require(File.ReadAllBytes(path).SequenceEqual(original));
                var occupied = Path.Combine(fixture.FullName, "occupied.json");
                Directory.CreateDirectory(occupied);
                File.WriteAllText(Path.Combine(occupied, "keep.txt"), "generated fixture");
                try { new DesktopPreferenceStore(occupied).Save(new()); throw new Exception("Occupied destination accepted."); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
                Require(File.ReadAllBytes(path).SequenceEqual(original));
                Require(File.ReadAllText(Path.Combine(occupied, "keep.txt")) == "generated fixture");
                Require(!Directory.EnumerateFiles(fixture.FullName, ".preferences-*.tmp").Any());
            }
            finally { fixture.Delete(recursive: true); }
            return Task.CompletedTask;
        });
        await check("语言解析与 Windows 辅助功能优先级", () =>
        {
            Require(new DesktopPreferences().ResolveLanguage(CultureInfo.GetCultureInfo("zh-TW")) == "zh-CN");
            Require(new DesktopPreferences().ResolveLanguage(CultureInfo.GetCultureInfo("fr-FR")) == "en");
            Require(new DesktopPreferences("en").ResolveLanguage(CultureInfo.GetCultureInfo("zh-CN")) == "en");
            Require(new DesktopPreferences("zh-CN").ResolveLanguage(CultureInfo.GetCultureInfo("en-US")) == "zh-CN");
            foreach (var reduce in new[] { false, true })
            foreach (var animations in new[] { false, true })
            foreach (var contrast in new[] { false, true })
                Require(new DesktopPreferences(ReduceMotion: reduce).UsesReducedMotion(animations, contrast) == (reduce || !animations || contrast));
            return Task.CompletedTask;
        });
        var previousLanguage = UiText.RequestedLanguage;
        var previousCulture = CultureInfo.CurrentUICulture;
        var previousDefaultCulture = CultureInfo.DefaultThreadCurrentUICulture;
        try
        {
            await check("中英文目录键、共享内置文案与原始用户内容边界", () =>
            {
                Require(UiText.Catalog.Count > 900);
                Require(UiText.Catalog.Keys.Select(UiText.Key).Distinct().Count() == UiText.Catalog.Count);
                foreach (var language in new[] { "zh-CN", "en" })
                {
                    UiText.SetLanguage(language, CultureInfo.InvariantCulture);
                    foreach (var (source, english) in UiText.Catalog)
                    {
                        Require(!string.IsNullOrEmpty(english) && !Regex.IsMatch(english, "[\\p{IsCJKUnifiedIdeographs}]"));
                        Require(UiText.FromKey(UiText.Key(source)) == UiText.T(source));
                        if (language == "en") Require(UiText.T(source) == english);
                    }
                    Require(UiText.T("C:/fixture/项目/build") == "C:/fixture/项目/build");
                    Require(UiText.T("我的规则原文") == "我的规则原文");
                }
                UiText.SetLanguage("zh-CN", CultureInfo.InvariantCulture);
                Require(UiText.T("Personal Rules") == "个人规则");
                Require(UiText.T("取消") == "取消");
                Require(UiText.T("application_running") == "应用正在运行，请退出后重新扫描。");
                UiText.SetLanguage("en", CultureInfo.InvariantCulture);
                Require(UiText.T("application_running") == "Application is running. Quit it and scan again.");
                return Task.CompletedTask;
            });
            await check("翻译保留全部格式参数和格式语义", () =>
            {
                static string[] Tokens(string value) => Regex.Matches(value, @"(?<!\{)\{\d+(?:,-?\d+)?(?::[^{}]+)?\}(?!\})").Select(match => match.Value).Order(StringComparer.Ordinal).ToArray();
                foreach (var (source, english) in UiText.Catalog)
                {
                    var sourceFormat = CompositeFormat.Parse(source);
                    var englishFormat = CompositeFormat.Parse(english);
                    Require(sourceFormat.MinimumArgumentCount == englishFormat.MinimumArgumentCount && Tokens(source).SequenceEqual(Tokens(english)));
                    if (sourceFormat.MinimumArgumentCount == 0) continue;
                    object[] values = Enumerable.Range(0, sourceFormat.MinimumArgumentCount).Select(index => Tokens(source).Any(token => token == "{" + index + ":g}") ? (object)DateTimeOffset.UnixEpoch : 1234L).ToArray();
                    foreach (var language in new[] { "zh-CN", "en" })
                    {
                        UiText.SetLanguage(language, CultureInfo.InvariantCulture);
                        Require(UiText.F(source, values) == string.Format(CultureInfo.CurrentCulture, language == "en" ? english : source, values));
                    }
                }
                Require(UiText.F("Literal {{value}} {0}", "fixture") == "Literal {value} fixture");
                return Task.CompletedTask;
            });
            await check("AI 认证标识在中英文界面保持不变", () =>
            {
                UiText.SetLanguage("zh-CN", CultureInfo.InvariantCulture);
                var chinese = AiAuthenticationChoices.Create();
                UiText.SetLanguage("en", CultureInfo.InvariantCulture);
                var english = AiAuthenticationChoices.Create();
                Require(chinese.Select(choice => choice.Id).SequenceEqual(new[] { "keychain", "local", "environment", "none" }));
                Require(chinese.Select(choice => choice.Id).SequenceEqual(english.Select(choice => choice.Id)));
                Require(chinese.Zip(english).All(pair => pair.First.Name != pair.Second.Name));
                return Task.CompletedTask;
            });
            await check("外部 AI 请求保留确切路径、语言与禁用草稿和确认边界", () =>
            {
                const string skill="C:/fixture 中文 & 'quoted'/Skill/SKILL.md";
                const string executable="C:/fixture 中文 & 'quoted'/Engine/shou.exe";
                const string directory="C:/projects/{keep}/中文 output";
                foreach(var language in new[] { "zh-CN","en" })
                {
                    UiText.SetLanguage(language,CultureInfo.InvariantCulture);
                    var scoped=AgentRuleHandoff.Create(skill,executable,directory);
                    var general=AgentRuleHandoff.Create(skill,executable,null);
                    Require(scoped.Contains(skill) && scoped.Contains(executable) && scoped.Contains(directory));
                    Require(general.Contains(skill) && general.Contains(executable) && !general.Contains(directory));
                    Require(language=="en" ? scoped.Contains("disabled drafts") && scoped.Contains("confirming actual deletion") && scoped.Contains("receipt") : scoped.Contains("停用草稿") && scoped.Contains("确认实际删除") && scoped.Contains("回执"));
                }
                return Task.CompletedTask;
            });
        }
        finally
        {
            UiText.SetLanguage(previousLanguage, previousCulture);
            CultureInfo.CurrentUICulture = previousCulture;
            CultureInfo.DefaultThreadCurrentUICulture = previousDefaultCulture;
        }
    }
}
