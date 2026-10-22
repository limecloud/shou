using System.Reflection;
using System.Text.Json.Nodes;
using Shou.Windows.Services;

internal static class SystemPreviewChecks
{
    public static async Task Run(Func<string, Func<Task>, Task> check)
    {
        var executable = Environment.ProcessPath!;
        var prefix = Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
            ? new[] { Assembly.GetExecutingAssembly().Location } : System.Array.Empty<string>();
        WindowsPreviewSession Session(string mode, int milliseconds = 2000) => new(executable, prefix.Concat(["--preview-fixture", mode]), TimeSpan.FromMilliseconds(milliseconds));
        var input = new JsonObject { ["generated_fixture"] = true };
        async Task Refuses(string mode, string code)
        {
            try { await Session(mode).RunAsync(input, 123, () => { }); }
            catch (BridgeException error) when (error.Code == code) { return; }
            throw new Exception("Unexpected system preview outcome: " + mode);
        }
        await check("system preview owns one bounded ready/closed protocol", async () => {
            var ready = 0; await Session("valid").RunAsync(input, 123, () => ready++);
            if (ready != 1) throw new Exception("Preview did not initialize exactly once.");
            foreach (var mode in new[] { "duplicate", "partial", "badexit", "missing-ready" }) await Refuses(mode, mode == "badexit" || mode == "missing-ready" ? "preview_unavailable" : "transport_failed");
            await Refuses("error", "plan_stale");
        });
        await check("system preview bounds pipes and startup without timing out an active view", async () => {
            await Refuses("overflow", "output_limit"); await Refuses("stderr-overflow", "output_limit");
            try { await Session("timeout", 150).RunAsync(input, 123, () => { }); throw new Exception("A stalled preview stayed alive."); }
            catch (BridgeException error) when (error.Code == "preview_timeout") { }
            // The startup deadline is removed after ready. This fixture closes
            // after a longer interval, without touching an installed provider.
            await Session("delayed-close", 2000).RunAsync(input, 123, () => { });
        });
        await check("closing system preview cancels its own process and validates before launch", async () => {
            using var stopping = new CancellationTokenSource();
            try { await Session("hang").RunAsync(input, 123, () => stopping.Cancel(), stopping.Token); throw new Exception("Preview ignored cancellation."); }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested) { }
            foreach (var oversized in new[] { false, true }) {
                var value = oversized ? new JsonObject { ["too_large"] = new string('x', 65537) } : input;
                try { await Session("valid").RunAsync(value, oversized ? 123UL : 0UL, () => { }); throw new Exception("Invalid preview input was launched."); }
                catch (BridgeException error) when (error.Code == (oversized ? "input_limit" : "invalid_preview")) { }
            }
        });
    }
}
