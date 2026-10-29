using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

internal interface IStartupTaskControlHandle : IDisposable
{
    string Path { get; }
    string Xml { get; }
    bool Enabled { get; }
    string? OwnerSid { get; }
    int? RunLevel => null;
    void SetEnabled(bool enabled);
}

public sealed class WindowsStartupControlInspector : IStartupControlInspector
{
    public static StartupControlReviewer CreateReviewer() => new(new WindowsStartupControlInspector(), ActorSid());

    public async Task<StartupControlTask> InspectAsync(string taskPath, CancellationToken cancellationToken)
    {
        if (!StartupControlReviewer.ValidTaskPath(taskPath)) throw new ShouException("invalid_argument", "Choose an exact scheduled-task identifier.");
        if (WindowsSystemAuthorization.Shared.IsAuthorized)
        {
            var reply = await WindowsSystemAuthorization.Shared.PerformAsync(new(Guid.NewGuid(), AuthorizationOperation.StartupInspect, TaskPath:taskPath), cancellationToken).ConfigureAwait(false);
            return reply.Startup is { } task && task.TaskPath == taskPath && task.ActorSid == ActorSid() ? task : throw WindowsAuthorizationChannel.Failure();
        }
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || !Environment.Is64BitProcess)
            throw new ShouException("unsupported_platform", "Scheduled-task review requires supported Windows.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        var readToken = deadline.Token;
        try
        {
            return await NativeOperationScheduler.RunAsync(() =>
            {
                using var task = new LocalStartupTaskControlHandle(taskPath);
                return Read(task, ActorSid(), readToken);
            }, readToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new ShouException("time_limit", "The scheduled-task review exceeded its read deadline."); }
        catch (COMException error)
        { throw new ShouException(error.HResult == unchecked((int)0x80070005) ? "permission_denied" : "startup_task_unavailable", "The exact scheduled task could not be reviewed.", error); }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        { throw new ShouException("startup_task_unavailable", "The exact scheduled task does not exist.", error); }
        catch (UnauthorizedAccessException error)
        { throw new ShouException("permission_denied", "The exact scheduled task could not be reviewed.", error); }
    }

    internal static StartupControlTask Read(IStartupTaskControlHandle task, string actorSid, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var path = task.Path;
        token.ThrowIfCancellationRequested();
        var xml = task.Xml;
        token.ThrowIfCancellationRequested();
        var enabled = task.Enabled;
        token.ThrowIfCancellationRequested();
        var owner = task.OwnerSid;
        token.ThrowIfCancellationRequested();
        var runLevel = task.RunLevel;
        token.ThrowIfCancellationRequested();
        var facts = Parse(path, xml, actorSid, enabled, owner, runLevel);
        var currentPath = task.Path;
        token.ThrowIfCancellationRequested();
        var currentXml = task.Xml;
        token.ThrowIfCancellationRequested();
        var currentEnabled = task.Enabled;
        token.ThrowIfCancellationRequested();
        var currentOwner = task.OwnerSid;
        token.ThrowIfCancellationRequested();
        var currentRunLevel = task.RunLevel;
        token.ThrowIfCancellationRequested();
        if (currentPath != path || currentXml != xml || currentEnabled != enabled || currentOwner != owner || currentRunLevel != runLevel)
            throw new ShouException("startup_changed", "The scheduled task changed during review.");
        return facts;
    }

    internal static StartupControlTask Parse(string path, string xml, string actorSid, bool enabled, string? ownerSid, int? nativeRunLevel = null)
    {
        if (!StartupControlReviewer.ValidTaskPath(path) || xml is not { Length: > 0 and <= WindowsScheduledStartupTasks.MaximumXmlCharacters })
            throw Invalid();
        if (WindowsScheduledStartupTasks.Parse(path, xml) is null)
            throw new ShouException("unsupported_capability", "Only an exact boot/logon scheduled task can be reviewed for startup control.");
        try
        {
            using var input = new StringReader(xml);
            using var reader = XmlReader.Create(input, new XmlReaderSettings
            { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, IgnoreWhitespace = true,
                MaxCharactersInDocument = WindowsScheduledStartupTasks.MaximumXmlCharacters });
            var document = XDocument.Load(reader, LoadOptions.None);
            XNamespace schema = "http://schemas.microsoft.com/windows/2004/02/mit/task";
            var root = document.Root!;
            var settings = root.Elements(schema + "Settings").ToArray();
            if (settings.Length > 1) throw Invalid();
            var enablement = settings.SingleOrDefault()?.Elements(schema + "Enabled").ToArray() ?? [];
            if (enablement.Length > 1 || enablement.Any(value => value.HasElements)) throw Invalid();
            if ((enablement.Length == 0 || XmlConvert.ToBoolean(enablement[0].Value.Trim())) != enabled)
                throw new ShouException("startup_changed", "The task setting and observed enablement disagree.");
            // Only the intended task switch is excluded; every other definition field remains fingerprinted.
            foreach (var element in enablement) element.Remove();
            if (settings.Length == 1 && !settings[0].HasAttributes && !settings[0].Nodes().Any()) settings[0].Remove();
            var digest = "sha256:" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(document.ToString(SaveOptions.DisableFormatting))));
            var principalSets = root.Elements(schema + "Principals").ToArray();
            var principals = principalSets.Length == 1 ? principalSets[0].Elements(schema + "Principal").ToArray() : [];
            var principal = principals.Length == 1 ? principals[0] : null;
            string? Scalar(string name)
            {
                var values = principal?.Elements(schema + name).ToArray() ?? [];
                return values.Length == 1 && !values[0].HasElements ? values[0].Value.Trim() : null;
            }
            var matches = principal is not null && !principal.Elements(schema + "GroupId").Any() && Scalar("UserId") == actorSid;
            var interactive = Scalar("LogonType") == "InteractiveToken";
            // Scheduler may omit the default RunLevel in normalized XML. Only the native COM
            // observation may fill that gap; missing XML alone never grants control eligibility.
            var runLevels = principal?.Elements(schema + "RunLevel").ToArray() ?? [];
            var ordinary = principal is not null && (nativeRunLevel is null or 0) &&
                (runLevels.Length == 1 && Scalar("RunLevel") == "LeastPrivilege" || runLevels.Length == 0 && nativeRunLevel == 0);
            return new(path, digest, actorSid, enabled, ownerSid == actorSid, matches, interactive, ordinary,
                path.Equals(@"\Microsoft", StringComparison.OrdinalIgnoreCase) || path.StartsWith(@"\Microsoft\", StringComparison.OrdinalIgnoreCase), ImmutableArray<string>.Empty);
        }
        catch (Exception error) when (error is XmlException or FormatException) { throw Invalid(); }
    }

    internal static string ActorSid()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return identity.User?.Value ?? throw new ShouException("permission_denied", "The current Windows actor is unavailable.");
    }
    private static ShouException Invalid() => new("startup_inspection_invalid", "The task definition cannot produce a bounded startup control observation.");
}

public sealed class WindowsStartupControlMutation : IStartupControlMutation
{
    public static bool PublicExecutionAvailable => false;
    public bool Available => NativeWindowsSupport.IsSupported;

    public async Task<StartupControlNativeResult> ApplyAsync(StartupControlReview review, DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken)
    {
        if (WindowsSystemAuthorization.Shared.IsAuthorized)
        {
            var reply = await WindowsSystemAuthorization.Shared.PerformAsync(new(Guid.NewGuid(), AuthorizationOperation.StartupToggle, Startup:review, ExpiresAt:authorizationExpiresAt), cancellationToken).ConfigureAwait(false);
            return reply.StartupResult ?? throw WindowsAuthorizationChannel.Failure();
        }
        if (!Available) return NotStarted("unsupported_platform");
        if (!StartupControlReviewer.ValidTaskPath(review.Task.TaskPath)) return NotStarted("startup_inspection_invalid");
        try
        {
            return await NativeOperationScheduler.RunToCompletionAsync(() =>
            {
                var operationEntered = false;
                try
                {
                    using var task = new LocalStartupTaskControlHandle(review.Task.TaskPath);
                    operationEntered = true;
                    return Apply(task, WindowsStartupControlInspector.ActorSid, review, authorizationExpiresAt, TimeProvider.System, cancellationToken);
                }
                catch (Exception error) when (Failure(error)) { return operationEntered
                    ? new(StartupControlNativeOutcome.Unknown, null, null, "startup_result_unknown") : NotStarted("startup_preflight_failed"); }
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return NotStarted("cancelled_before_startup_change"); }
    }

    internal static StartupControlNativeResult Apply(IStartupTaskControlHandle task, Func<string> actorSid, StartupControlReview review,
        DateTimeOffset expiresAt, TimeProvider clock, CancellationToken token)
    {
        var attempted = false;
        try
        {
            if (token.IsCancellationRequested) return NotStarted("cancelled_before_startup_change");
            if (expiresAt.Offset != TimeSpan.Zero || clock.GetUtcNow() < review.CreatedAt || clock.GetUtcNow() >= expiresAt || expiresAt > review.ExpiresAt)
                return NotStarted("startup_authorization_expired");
            var current = WindowsStartupControlInspector.Read(task, actorSid(), token);
            if (!Same(current, review.Task) || !review.CanChange || !current.OwnerMatchesActor || !current.PrincipalMatchesActor ||
                !current.InteractiveToken || !current.LeastPrivilege || current.ProtectedLocation || !current.Issues.IsEmpty ||
                current.Enabled == review.DesiredEnabled) return NotStarted("startup_changed");
            if (actorSid() != review.Task.ActorSid) return NotStarted("startup_actor_changed");
            if (token.IsCancellationRequested) return NotStarted("cancelled_before_startup_change");
            if (clock.GetUtcNow() < review.CreatedAt || clock.GetUtcNow() >= expiresAt) return NotStarted("startup_authorization_expired");
            attempted = true;
            task.SetEnabled(review.DesiredEnabled);
            // Once the setter is invoked, retain the lease and observe its result without caller cancellation.
            try
            {
                var observed = WindowsStartupControlInspector.Read(task, actorSid(), CancellationToken.None);
                return new(StartupControlNativeOutcome.Applied, observed.Enabled,
                    Same(observed with { Enabled = review.Task.Enabled }, review.Task));
            }
            catch (Exception error) when (Failure(error))
            { return new(StartupControlNativeOutcome.Applied, null, null, "startup_observation_unavailable"); }
        }
        catch (Exception error) when (Failure(error) || error is OperationCanceledException)
        { return attempted ? new(StartupControlNativeOutcome.Unknown, null, null, "startup_result_unknown") :
            NotStarted(token.IsCancellationRequested ? "cancelled_before_startup_change" : "startup_preflight_failed"); }
    }
    private static bool Same(StartupControlTask left, StartupControlTask right) =>
        JsonSerializer.Serialize(left, ContractJson.Options) == JsonSerializer.Serialize(right, ContractJson.Options);
    private static bool Failure(Exception error) => error is ShouException or COMException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or IOException;
    private static StartupControlNativeResult NotStarted(string reason) => new(StartupControlNativeOutcome.NotStarted, null, null, reason);
}

internal sealed class LocalStartupTaskControlHandle : IStartupTaskControlHandle
{
    private object? service;
    private object? folder;
    private object? task;
    internal LocalStartupTaskControlHandle(string path)
    {
        if (!StartupControlReviewer.ValidTaskPath(path)) throw new ShouException("invalid_argument", "Choose an exact scheduled-task identifier.");
        try
        {
            service = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("0f87369f-a4e5-4cfc-bd3e-73e6154572dd"), throwOnError: true)!)!;
            ((dynamic)service).Connect();
            var separator = path.LastIndexOf('\\');
            folder = (object)((dynamic)service).GetFolder(separator == 0 ? "\\" : path[..separator]);
            task = (object)((dynamic)folder).GetTask(path[(separator + 1)..]);
        }
        catch { Dispose(); throw; }
    }
    public string Path => (string)((dynamic)task!).Path;
    public string Xml => (string)((dynamic)task!).Xml;
    public bool Enabled => (bool)((dynamic)task!).Enabled;
    public string? OwnerSid => new RawSecurityDescriptor((string)((dynamic)task!).GetSecurityDescriptor(1)).Owner?.Value;
    public int? RunLevel => ReadRunLevel(task!);
    internal static int ReadRunLevel(object task)
    {
        object? definition = null, principal = null;
        try
        {
            definition = (object)((dynamic)task).Definition;
            principal = (object)((dynamic)definition).Principal;
            return (int)((dynamic)principal).RunLevel;
        }
        finally { LocalScheduledTaskReader.Release(principal); LocalScheduledTaskReader.Release(definition); }
    }
    public void SetEnabled(bool enabled)
    {
        var name = Path[(Path.LastIndexOf('\\') + 1)..];
        ((dynamic)task!).Enabled = enabled;
        // IRegisteredTask caches its XML; reacquire before checking the changed setting.
        LocalScheduledTaskReader.Release(task); task = null;
        task = (object)((dynamic)folder!).GetTask(name);
    }
    public void Dispose()
    {
        LocalScheduledTaskReader.Release(task); task = null;
        LocalScheduledTaskReader.Release(folder); folder = null;
        LocalScheduledTaskReader.Release(service); service = null;
    }
}
