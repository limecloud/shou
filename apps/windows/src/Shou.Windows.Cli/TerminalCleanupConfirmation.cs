using System.Text.Encodings.Web;
using System.Text.Json;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.Cli;

/// <summary>Only the current exact plan phrase can create domain consent; the prompt never writes stdout.</summary>
internal sealed class TerminalCleanupConfirmation(Func<string, CancellationToken, Task<string?>> prompt, string locale) : ICleanupConfirmation
{
    public async Task<bool> RequestAsync(CleanupReview review, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var text = new TextCatalog(locale);
        var phrase = (review.Action == CleanupAction.Permanent ? "PURGE " : "TRASH ") + review.PlanId;
        var options = new JsonSerializerOptions(ContractJson.Options) { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        var scope = JsonSerializer.Serialize(review, options);
        var warning = review.Action == CleanupAction.Permanent ? text.Get("Permanent deletion cannot be undone.") + Environment.NewLine : "";
        var message = scope + Environment.NewLine + warning + text.Format("Review the exact scope above. Type %@ to confirm; any other input cancels.", phrase) + Environment.NewLine;
        var response = await prompt(message, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        return response is { Length: <= 256 } && string.Equals(response.Trim(), phrase, StringComparison.Ordinal);
    }
}

internal static class WindowsConsolePrompt
{
    private static readonly SemaphoreSlim Sessions = new(1, 1);

    public static async Task<string?> ReadAsync(string message, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindows() || Console.IsInputRedirected || Console.IsErrorRedirected) throw Required();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromMinutes(1));
        var token = deadline.Token;
        try
        {
            await Sessions.WaitAsync(token);
            var reader = Task.Run(async () =>
            {
                try
                {
                    Console.Error.Write(message);
                    var input = new System.Text.StringBuilder();
                    var overflow = false;
                    while (true)
                    {
                        token.ThrowIfCancellationRequested();
                        if (!Console.KeyAvailable) { await Task.Delay(25, token); continue; }
                        var key = Console.ReadKey(intercept: true);
                        token.ThrowIfCancellationRequested();
                        if (key.Key is ConsoleKey.Enter or ConsoleKey.Escape)
                        {
                            Console.Error.WriteLine();
                            return key.Key == ConsoleKey.Escape || overflow ? null : input.ToString();
                        }
                        if (key.Key == ConsoleKey.Backspace)
                        {
                            if (input.Length > 0) { input.Length--; Console.Error.Write("\b \b"); }
                        }
                        else if (!char.IsControl(key.KeyChar))
                        {
                            if (input.Length < 256) { input.Append(key.KeyChar); Console.Error.Write(key.KeyChar); }
                            else overflow = true;
                        }
                    }
                }
                finally { Sessions.Release(); }
            }, CancellationToken.None);
            _ = reader.ContinueWith(completed => { _ = completed.Exception; }, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return await reader.WaitAsync(token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { throw Required(); }
        catch (Exception error) when (error is IOException or InvalidOperationException) { throw Required(); }
    }

    private static ShouException Required() => new("confirmation_required", "An interactive input and diagnostic terminal are required within one minute. No targets were changed.");
}
