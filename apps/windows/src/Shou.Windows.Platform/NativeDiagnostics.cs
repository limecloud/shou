using System.Text.Json;

namespace Shou.Windows.Platform;

public static class NativeDiagnostics
{
    public static string LogDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shou", "Logs");

    public static void Write(Exception error)
    {
        try
        {
            Directory.CreateDirectory(LogDirectory);
            var path = Path.Combine(LogDirectory, "application.jsonl");
            if (File.Exists(path) && new FileInfo(path).Length >= 1_048_576)
                File.Move(path, path + ".previous", overwrite: true);
            // Only static XAML startup errors on generated CI hosts may include their resource details.
            var xamlStartupMessage = Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
                error.GetType().FullName == "Microsoft.UI.Xaml.Markup.XamlParseException" ? error.Message : null;
            // Provider responses and other exception messages can contain credentials or private content.
            var line = JsonSerializer.Serialize(new
            {
                at_utc = DateTimeOffset.UtcNow,
                exception_type = error.GetType().FullName,
                hresult = $"0x{error.HResult:X8}",
                xaml_startup_message = xamlStartupMessage,
                stack = error.StackTrace
            });
            File.AppendAllText(path, line + Environment.NewLine);
        }
        catch (Exception loggingError) when (loggingError is IOException or UnauthorizedAccessException) { }
    }
}
