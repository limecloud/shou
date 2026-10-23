using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Xml;
using System.Xml.Linq;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

// Only the local scheduler is connected. These ports expose no registration, execution or control methods.
internal interface IScheduledTaskReader : IDisposable
{
    IScheduledTaskFolder OpenFolder(string path);
}
internal interface IScheduledTaskFolder : IDisposable
{
    int TaskCount { get; }
    int FolderCount { get; }
    ScheduledTaskRead ReadTask(int index, CancellationToken token);
    string ReadFolderPath(int index);
}
internal interface IScheduledTaskProperties
{
    string Path { get; }
    string Xml { get; }
    bool Enabled { get; }
    int State { get; }
}
internal sealed record ScheduledTaskRead(string Path, StartupRegistration? Registration);

internal static class WindowsScheduledStartupTasks
{
    internal const int MaximumXmlCharacters = 256 * 1024;
    internal const int MaximumDepth = 32;
    private static readonly XNamespace Schema = "http://schemas.microsoft.com/windows/2004/02/mit/task";

    internal static StartupInventory Read(int limit, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        using var reader = new LocalScheduledTaskReader();
        return Read(reader, limit, token);
    }

    internal static StartupInventory Read(IScheduledTaskReader reader, int limit, CancellationToken token)
    {
        if (limit is < 1 or > 10_000) throw new ArgumentOutOfRangeException(nameof(limit));
        var items = ImmutableArray.CreateBuilder<StartupRegistration>();
        var issues = new HashSet<string>(StringComparer.Ordinal);
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new Stack<(string Path, int Depth)>();
        pending.Push(("\\", 0));
        var inspected = 0;
        while (pending.TryPop(out var next))
        {
            token.ThrowIfCancellationRequested();
            if (!TakeEntry()) break;
            if (!visited.Add(next.Path)) { issues.Add("source_changed"); continue; }
            try
            {
                using var folder = reader.OpenFolder(next.Path);
                token.ThrowIfCancellationRequested();
                var tasks = folder.TaskCount;
                var folders = folder.FolderCount;
                if (tasks < 0 || folders < 0) throw InvalidMetadata();
                for (var index = 1; index <= tasks; index++)
                {
                    token.ThrowIfCancellationRequested();
                    if (!TakeEntry()) break;
                    try
                    {
                        var task = folder.ReadTask(index, token);
                        token.ThrowIfCancellationRequested();
                        if (!DirectChild(next.Path, task.Path)) throw new ShouException("registration_changed", "The task moved during discovery.");
                        if (task.Registration is { } item)
                        {
                            items.Add(item);
                            foreach (var issue in item.Issues.Where(value => value.StartsWith("scheduled_task_status_", StringComparison.Ordinal))) issues.Add(issue);
                        }
                    }
                    catch (Exception error) when (ReadFailure(error)) { issues.Add(ErrorCode(error)); }
                }
                for (var index = 1; index <= folders; index++)
                {
                    token.ThrowIfCancellationRequested();
                    if (!TakeEntry()) break;
                    try
                    {
                        var path = folder.ReadFolderPath(index);
                        if (!DirectChild(next.Path, path)) throw new ShouException("source_changed", "The task folder moved during discovery.");
                        if (next.Depth == MaximumDepth) { issues.Add("depth_limit"); continue; }
                        pending.Push((path, next.Depth + 1));
                    }
                    catch (Exception error) when (ReadFailure(error)) { issues.Add(ErrorCode(error)); }
                }
                token.ThrowIfCancellationRequested();
                if (tasks != folder.TaskCount || folders != folder.FolderCount) issues.Add("source_changed");
            }
            catch (Exception error) when (ReadFailure(error)) { issues.Add(ErrorCode(error)); }
        }
        token.ThrowIfCancellationRequested();
        return new(items.ToImmutable(), [new(StartupSource.ScheduledTasks,
            issues.Count == 0 ? StartupSourceState.Complete : StartupSourceState.Partial,
            inspected, issues.Order(StringComparer.Ordinal).ToImmutableArray())]);

        bool TakeEntry()
        {
            if (inspected == limit) { issues.Add("entry_limit"); return false; }
            inspected++;
            return true;
        }
    }

    // RegisteredTask.Enabled and State describe the task engine, not trigger eligibility or app processes.
    internal static ScheduledTaskRead ReadTask(IScheduledTaskProperties task, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var path = task.Path;
        token.ThrowIfCancellationRequested();
        var xml = task.Xml;
        if (xml is not { Length: > 0 and <= MaximumXmlCharacters }) throw InvalidMetadata();
        var item = Parse(path, xml);
        token.ThrowIfCancellationRequested();
        if (item is not null)
        {
            ScheduledTaskStatus? status = null;
            string? issue = null;
            try
            {
                var enabled = task.Enabled;
                token.ThrowIfCancellationRequested();
                var state = task.State;
                token.ThrowIfCancellationRequested();
                var enabledAgain = task.Enabled;
                token.ThrowIfCancellationRequested();
                var stateAgain = task.State;
                token.ThrowIfCancellationRequested();
                if (!Enum.IsDefined((ScheduledTaskState)state) || !Enum.IsDefined((ScheduledTaskState)stateAgain))
                    issue = "scheduled_task_status_invalid";
                else if (enabled != enabledAgain || state != stateAgain)
                    issue = "scheduled_task_status_changed";
                else status = new(enabled, (ScheduledTaskState)state);
            }
            catch (Exception error) when (ReadFailure(error)) { issue = "scheduled_task_status_unavailable"; }
            item = item with { ScheduledTask = status, Issues = issue is null ? item.Issues : item.Issues.Add(issue) };
        }
        token.ThrowIfCancellationRequested();
        var currentPath = task.Path;
        token.ThrowIfCancellationRequested();
        var currentXml = task.Xml;
        token.ThrowIfCancellationRequested();
        if (path != currentPath || xml != currentXml)
            throw new ShouException("registration_changed", "The scheduled task changed during discovery.");
        return new(path, item);
    }

    // Task paths are scheduler identifiers, not filesystem paths. The XML and all action arguments stay here.
    internal static StartupRegistration? Parse(string path, string xml)
    {
        if (!ValidPath(path) || xml.Length is 0 or > MaximumXmlCharacters) throw InvalidMetadata();
        try
        {
            using var input = new StringReader(xml);
            using var reader = XmlReader.Create(input, new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null,
                MaxCharactersInDocument = MaximumXmlCharacters
            });
            var document = XDocument.Load(reader, LoadOptions.None);
            var task = document.Root;
            if (task?.Name != Schema + "Task" || task.Elements(Schema + "Triggers").Count() > 1 ||
                task.Elements(Schema + "Actions").Count() > 1) throw InvalidMetadata();
            var triggers = task.Element(Schema + "Triggers");
            if (triggers is null || !triggers.Elements().Any(trigger => trigger.Name == Schema + "LogonTrigger" || trigger.Name == Schema + "BootTrigger")) return null;
            var actions = task.Element(Schema + "Actions")?.Elements().ToArray() ?? [];
            var issues = ImmutableArray<string>.Empty;
            WindowsPath? executable = null;
            if (actions.Length == 1 && actions[0].Name == Schema + "Exec")
            {
                var command = actions[0].Elements(Schema + "Command").ToArray();
                if (command.Length == 1 && !command[0].HasElements) executable = LiteralExecutable(command[0].Value);
            }
            if (executable is null) issues = issues.Add(actions.Length > 1 ? "multiple_actions" : "executable_unresolved");
            return new(StartupSource.ScheduledTasks, path, path[(path.LastIndexOf('\\') + 1)..], executable?.Value, Issues: issues);
        }
        catch (XmlException) { throw InvalidMetadata(); }
    }

    private static WindowsPath? LiteralExecutable(string path)
    {
        if (path.Contains('%') || !(path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".com", StringComparison.OrdinalIgnoreCase))) return null;
        try { return WindowsPath.Parse(path); }
        catch (ShouException) { return null; }
    }
    internal static bool ValidPath(string path) => path is { Length: > 1 and <= 32760 } && path[0] == '\\' &&
        !path.Split('\\').Skip(1).Any(part => part.Length == 0 || part is "." or ".." || part.Any(character => char.IsControl(character) || character is '/' or '\0'));
    private static bool DirectChild(string parent, string path) => ValidPath(path) &&
        path[..path.LastIndexOf('\\')].Equals(parent == "\\" ? "" : parent, StringComparison.OrdinalIgnoreCase);
    internal static ShouException InvalidMetadata() => new("invalid_registration_metadata", "A scheduled task definition is invalid or exceeds its read limit.");
    private static bool ReadFailure(Exception error) => error is ShouException or COMException or UnauthorizedAccessException or InvalidCastException or ArgumentException;
    private static string ErrorCode(Exception error) => error is UnauthorizedAccessException || error is COMException { HResult: unchecked((int)0x80070005) }
        ? "permission_denied" : error is ShouException known ? known.Code : "scheduled_task_read_failed";
}

// Task Scheduler 2.0 automation: GetTasks includes hidden tasks; Connect uses the current local identity.
// Each RCW is confined to the native worker and released on that worker, including on cancellation.
internal sealed class LocalScheduledTaskReader : IScheduledTaskReader
{
    private readonly object service;
    internal LocalScheduledTaskReader()
    {
        service = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("0f87369f-a4e5-4cfc-bd3e-73e6154572dd"), throwOnError: true)!)!;
        try { ((dynamic)service).Connect(); }
        catch { Release(service); throw; }
    }
    public IScheduledTaskFolder OpenFolder(string path) => new LocalScheduledTaskFolder((object)((dynamic)service).GetFolder(path));
    public void Dispose() => Release(service);
    internal static void Release(object? value) { if (value is not null && Marshal.IsComObject(value)) Marshal.FinalReleaseComObject(value); }
}

internal sealed class LocalScheduledTaskFolder : IScheduledTaskFolder
{
    private readonly object folder;
    private readonly object tasks;
    private readonly object folders;
    internal LocalScheduledTaskFolder(object folder)
    {
        this.folder = folder;
        object? taskCollection = null;
        try
        {
            taskCollection = (object)((dynamic)folder).GetTasks(1);
            folders = (object)((dynamic)folder).GetFolders(0);
            tasks = taskCollection;
        }
        catch { LocalScheduledTaskReader.Release(taskCollection); LocalScheduledTaskReader.Release(folder); throw; }
    }
    public int TaskCount => (int)((dynamic)tasks).Count;
    public int FolderCount => (int)((dynamic)folders).Count;
    public ScheduledTaskRead ReadTask(int index, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        object? task = null;
        try
        {
            task = (object)((dynamic)tasks)[index];
            token.ThrowIfCancellationRequested();
            return WindowsScheduledStartupTasks.ReadTask(new LocalScheduledTaskProperties(task), token);
        }
        finally { LocalScheduledTaskReader.Release(task); }
    }
    public string ReadFolderPath(int index)
    {
        object? child = null;
        try { child = (object)((dynamic)folders)[index]; return (string)((dynamic)child).Path; }
        finally { LocalScheduledTaskReader.Release(child); }
    }
    public void Dispose()
    {
        LocalScheduledTaskReader.Release(folders);
        LocalScheduledTaskReader.Release(tasks);
        LocalScheduledTaskReader.Release(folder);
    }
}

internal sealed class LocalScheduledTaskProperties(object task) : IScheduledTaskProperties
{
    public string Path => (string)((dynamic)task).Path;
    public string Xml => (string)((dynamic)task).Xml;
    public bool Enabled => (bool)((dynamic)task).Enabled;
    public int State => (int)((dynamic)task).State;
}
