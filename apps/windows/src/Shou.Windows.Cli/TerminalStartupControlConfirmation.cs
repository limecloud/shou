using System.Text.Encodings.Web;
using System.Text.Json;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.Cli;

internal sealed class TerminalStartupControlConfirmation(Func<string, CancellationToken, Task<string?>> prompt, string locale) : IStartupControlConfirmation
{
    public async Task<bool> RequestAsync(StartupControlReview review, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var text = new TextCatalog(locale);
        var phrase = "STARTUP " + review.Action.ToString().ToUpperInvariant() + " " + review.Id;
        var scope = JsonSerializer.Serialize(review, new JsonSerializerOptions(ContractJson.Options) { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        var response = await prompt(scope + Environment.NewLine + text.Get("This changes only the task switch. Running instances are not stopped, and startup conditions may still prevent it from running.") +
            Environment.NewLine + text.Format("Review the exact scope above. Type %@ to confirm; any other input cancels.", phrase) + Environment.NewLine, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return response is { Length: <= 256 } && string.Equals(response.Trim(), phrase, StringComparison.Ordinal);
    }
}
