using System.Text.Encodings.Web;
using System.Text.Json;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.Cli;

internal sealed class TerminalApplicationUninstallConfirmation(Func<string, CancellationToken, Task<string?>> prompt, string locale) : IApplicationUninstallConfirmation
{
    public async Task<bool> RequestAsync(ApplicationUninstallPlan plan, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var text = new TextCatalog(locale);
        var phrase = "UNINSTALL " + plan.Id;
        var scope = JsonSerializer.Serialize(plan, new JsonSerializerOptions(ContractJson.Options) { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        var message = scope + Environment.NewLine + text.Get("The system installer may stop managed apps or services and remove data. Shou cannot restore this operation.") + Environment.NewLine +
            text.Format("Review the exact scope above. Type %@ to confirm; any other input cancels.", phrase) + Environment.NewLine;
        var response = await prompt(message, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return response is { Length: <= 256 } && string.Equals(response.Trim(), phrase, StringComparison.Ordinal);
    }
}
