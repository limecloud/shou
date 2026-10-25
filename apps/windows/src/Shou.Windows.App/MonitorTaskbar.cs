using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal static class MonitorTaskbar
{
    public static async Task PrepareAsync()
    {
        try
        {
            if (!global::Windows.UI.StartScreen.JumpList.IsSupported()) return;
            var list = await global::Windows.UI.StartScreen.JumpList.LoadCurrentAsync();
            foreach (var previous in list.Items.Where(item => item.Arguments == "--page monitor").ToArray()) list.Items.Remove(previous);
            var item = global::Windows.UI.StartScreen.JumpListItem.CreateWithArguments("--page monitor", new TextCatalog().Get("Open System Monitor"));
            item.GroupName = "Shou"; list.Items.Add(item);
            await list.SaveAsync();
        }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
}
