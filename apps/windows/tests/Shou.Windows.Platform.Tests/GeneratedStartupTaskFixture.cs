using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

/// <summary>Owns one newly generated task in a random folder. Its only trigger and demand starts are disabled.
/// No existing task identifier, executable or account is accepted as input.</summary>
internal sealed class GeneratedStartupTaskFixture : IAsyncDisposable
{
    internal const string OptInVariable = "SHOU_TEST_GENERATED_STARTUP";
    internal const string EvidenceVariable = "SHOU_TEST_GENERATED_STARTUP_EVIDENCE";
    private static readonly XNamespace Schema = "http://schemas.microsoft.com/windows/2004/02/mit/task";
    private readonly string marker = "shou-generated-startup-" + Guid.NewGuid().ToString("N");
    private readonly string folderName = "ShouGeneratedStartup-" + Guid.NewGuid().ToString("N");
    private const string TaskName = "fixture-内容 with spaces";
    private string? definitionDigest;
    private bool folderCreated;
    private bool registrationAttempted;
    private bool disposed;
    private int sequence;
    public string OwnerSid { get; }
    public string Root { get; }
    public string FolderPath => "\\" + folderName;
    public string TaskPath => FolderPath + "\\" + TaskName;
    public string PrivateArgument => "--generated-private-" + marker;
    private string NeverRunExecutable => Path.Combine(Root, "never-run.generated.exe");
    private string Security => "O:" + OwnerSid + "D:P(A;;FA;;;" + OwnerSid + ")(A;;FA;;;SY)";

    private GeneratedStartupTaskFixture()
    {
        RequireEnabled();
        using var actor = WindowsIdentity.GetCurrent();
        OwnerSid = actor.User?.Value ?? throw new InvalidOperationException("A current user SID is required.");
        var evidence = Environment.GetEnvironmentVariable(EvidenceVariable) ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShouBuild", "generated-startup-evidence");
        var parent = WindowsPath.Parse(Path.GetFullPath(evidence));
        if (new DriveInfo(Path.GetPathRoot(parent.Value)!).DriveType != DriveType.Fixed)
            throw new InvalidOperationException("Generated startup evidence requires a fixed local Windows drive.");
        Root = Path.Combine(parent.Value, "fixture-" + Guid.NewGuid().ToString("N"));
        if (Path.Exists(Root)) throw new InvalidOperationException("The random fixture output already exists; no task was registered.");
        new DirectoryInfo(Root).Create(WindowsFileSystemTests.NativeFixture.PrivateDirectorySecurity());
        using var markerFile = new FileStream(Path.Combine(Root, "protected-generated-data.txt"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
        markerFile.Write(Encoding.UTF8.GetBytes(marker));
    }

    public static async Task<GeneratedStartupTaskFixture> CreateAsync()
    {
        var fixture = new GeneratedStartupTaskFixture();
        try
        {
            await fixture.OnSchedulerAsync(service =>
            {
                object? root = null, folder = null, task = null;
                try
                {
                    if (FindFolder(service, fixture.FolderPath) is { } existing)
                    {
                        LocalScheduledTaskReader.Release(existing);
                        throw new InvalidOperationException("The random fixture folder already exists; nothing was registered.");
                    }
                    root = (object)((dynamic)service).GetFolder("\\");
                    folder = (object)((dynamic)root).CreateFolder(fixture.folderName, fixture.Security);
                    fixture.folderCreated = true;
                    fixture.RequireFolderOwner(folder);
                    fixture.registrationAttempted = true;
                    task = (object)((dynamic)folder).RegisterTask(TaskName, fixture.Definition(), 2,
                        fixture.OwnerSid, null, 3, fixture.Security); // TASK_CREATE; interactive token; no password.
                    var facts = fixture.ReadOwned(task, requireDigest: false);
                    if (facts.Enabled) throw new InvalidOperationException("A generated task must start disabled.");
                    fixture.definitionDigest = facts.DefinitionDigest;
                    return true;
                }
                finally { Release(task, folder, root); }
            });
            await fixture.SaveEvidenceAsync("registered_disabled", null);
            return fixture;
        }
        catch (Exception failure)
        {
            try { await fixture.DisposeAsync(); }
            catch (Exception cleanup) { throw new AggregateException($"Generated task failed; evidence: {fixture.Root}; task: {fixture.TaskPath}", failure, cleanup); }
            throw new InvalidOperationException($"Generated task failed; evidence: {fixture.Root}", failure);
        }
    }

    public StartupControlReviewer Reviewer() => new(new WindowsStartupControlInspector(), OwnerSid);
    public Task<StartupControlTask> ObserveAsync() => WithOwnedTaskAsync(task => ReadOwned(task));

    public async Task ChangeGeneratedDefinitionAsync()
    {
        RequireEnabled();
        await OnSchedulerAsync(service =>
        {
            object? folder = null, task = null, updated = null;
            try
            {
                folder = (object)((dynamic)service).GetFolder(FolderPath);
                RequireFolderOwner(folder);
                task = (object)((dynamic)folder).GetTask(TaskName);
                ReadOwned(task);
                var xml = XDocument.Parse((string)((dynamic)task).Xml);
                var settings = xml.Root!.Element(Schema + "Settings")!;
                var hidden = settings.Element(Schema + "Hidden");
                if (hidden is null) settings.Add(new XElement(Schema + "Hidden", true));
                else hidden.Value = "true";
                updated = (object)((dynamic)folder).RegisterTask(TaskName, xml.ToString(SaveOptions.DisableFormatting), 4,
                    OwnerSid, null, 3, Security); // TASK_UPDATE never creates a missing task.
                var facts = ReadOwned(updated, requireDigest: false);
                if (facts.DefinitionDigest == definitionDigest) throw new InvalidOperationException("The generated definition did not change.");
                definitionDigest = facts.DefinitionDigest;
                return true;
            }
            finally { Release(updated, task, folder); }
        });
        await SaveEvidenceAsync("generated_definition_changed", null);
    }

    public async Task SaveEvidenceAsync(string stage, StartupControlExecution? execution)
    {
        var facts = await ObserveAsync();
        Assert.Equal(marker, File.ReadAllText(Path.Combine(Root, "protected-generated-data.txt"), Encoding.UTF8));
        Assert.False(File.Exists(NeverRunExecutable));
        WriteEvidence(stage, new
        {
            task_present = true, facts, execution,
            generated_trigger_disabled = true, demand_start_disabled = true,
            marker_file_sha256 = Hash(File.ReadAllBytes(Path.Combine(Root, "protected-generated-data.txt")))
        });
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        RequireEnabled();
        if (!folderCreated)
        {
            disposed = true;
            WriteEvidence("registration_not_completed", new { generated_folder_absence_verified = false });
            return;
        }
        if (folderCreated)
        {
            await OnSchedulerAsync(service =>
            {
                object? root = null, folder = null, task = null, tasks = null, folders = null;
                try
                {
                    folder = FindFolder(service, FolderPath);
                    if (folder is null) return true;
                    RequireFolderOwner(folder);
                    task = FindTask(folder, TaskName);
                    if (task is not null)
                    {
                        // A failed/ambiguous registration without a verified definition is retained for inspection.
                        if (!registrationAttempted || definitionDigest is null)
                            throw new InvalidOperationException("Refusing teardown without the generated task's verified definition.");
                        ReadOwned(task);
                        ((dynamic)folder).DeleteTask(TaskName, 0);
                    }
                    tasks = (object)((dynamic)folder).GetTasks(1);
                    folders = (object)((dynamic)folder).GetFolders(0);
                    if ((int)((dynamic)tasks).Count != 0 || (int)((dynamic)folders).Count != 0)
                        throw new InvalidOperationException("Refusing teardown of a fixture folder containing unexpected entries.");
                    root = (object)((dynamic)service).GetFolder("\\");
                    ((dynamic)root).DeleteFolder(folderName, 0);
                    if (FindFolder(service, FolderPath) is { } remaining)
                    {
                        LocalScheduledTaskReader.Release(remaining);
                        throw new InvalidOperationException("The generated task folder still exists after teardown.");
                    }
                    return true;
                }
                finally { Release(folders, tasks, task, folder, root); }
            });
        }
        disposed = true;
        // Preserve generated marker files, evidence and private operation records; remove no filesystem tree.
        Assert.Equal(marker, File.ReadAllText(Path.Combine(Root, "protected-generated-data.txt"), Encoding.UTF8));
        Assert.False(File.Exists(NeverRunExecutable));
        WriteEvidence("fixture_removed", new
        {
            task_present = false, generated_folder_absent = true,
            marker_file_sha256 = Hash(File.ReadAllBytes(Path.Combine(Root, "protected-generated-data.txt")))
        });
    }

    private Task<T> WithOwnedTaskAsync<T>(Func<object, T> operation) => OnSchedulerAsync(service =>
    {
        object? folder = null, task = null;
        try
        {
            folder = (object)((dynamic)service).GetFolder(FolderPath);
            RequireFolderOwner(folder);
            task = (object)((dynamic)folder).GetTask(TaskName);
            ReadOwned(task);
            return operation(task);
        }
        finally { Release(task, folder); }
    });

    private Task<T> OnSchedulerAsync<T>(Func<object, T> operation) => NativeOperationScheduler.RunToCompletionAsync(() =>
    {
        RequireEnabled();
        using var actor = WindowsIdentity.GetCurrent();
        if (actor.User?.Value != OwnerSid) throw new InvalidOperationException("The fixture actor changed.");
        object? service = null;
        try
        {
            service = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("0f87369f-a4e5-4cfc-bd3e-73e6154572dd"), true)!)!;
            ((dynamic)service).Connect();
            return operation(service);
        }
        finally { Release(service); }
    }, CancellationToken.None);

    private StartupControlTask ReadOwned(object task, bool requireDigest = true)
    {
        dynamic native = task;
        var path = (string)native.Path;
        var xml = (string)native.Xml;
        var enabled = (bool)native.Enabled;
        var owner = new RawSecurityDescriptor((string)native.GetSecurityDescriptor(1)).Owner?.Value;
        var facts = WindowsStartupControlInspector.Parse(path, xml, OwnerSid, enabled, owner, LocalStartupTaskControlHandle.ReadRunLevel(task));
        // Preserve generated definitions so scheduler normalization can be investigated without
        // weakening the identity check or requiring another paid cloud session.
        if (!requireDigest)
            File.WriteAllText(Path.Combine(Root, "expected-definition.xml"), xml, Encoding.UTF8);
        else if (definitionDigest is not null && facts.DefinitionDigest != definitionDigest)
            File.WriteAllText(Path.Combine(Root, "mismatched-definition.xml"), xml, Encoding.UTF8);
        var root = XDocument.Parse(xml).Root!;
        var trigger = root.Element(Schema + "Triggers")?.Elements().SingleOrDefault();
        var action = root.Element(Schema + "Actions")?.Elements().SingleOrDefault();
        if (path != TaskPath || !facts.OwnerMatchesActor || !facts.PrincipalMatchesActor || !facts.InteractiveToken || !facts.LeastPrivilege ||
            root.Element(Schema + "RegistrationInfo")?.Element(Schema + "Source")?.Value != marker ||
            trigger?.Name != Schema + "LogonTrigger" || trigger.Element(Schema + "Enabled")?.Value != "false" ||
            AccountSid(trigger.Element(Schema + "UserId")?.Value) != OwnerSid ||
            root.Element(Schema + "Settings")?.Element(Schema + "AllowStartOnDemand")?.Value != "false" ||
            action?.Name != Schema + "Exec" || action.Element(Schema + "Command")?.Value != NeverRunExecutable ||
            action.Element(Schema + "Arguments")?.Value != PrivateArgument || (int)native.State == 4 ||
            requireDigest && (definitionDigest is null || facts.DefinitionDigest != definitionDigest))
            throw new InvalidOperationException("The task no longer matches this inert, current-user generated fixture. No teardown is authorized. " +
                JsonSerializer.Serialize(new { path_matches = path == TaskPath, facts.OwnerMatchesActor, facts.PrincipalMatchesActor,
                    facts.InteractiveToken, facts.LeastPrivilege, source_matches = root.Element(Schema + "RegistrationInfo")?.Element(Schema + "Source")?.Value == marker,
                    trigger_matches = trigger?.Name == Schema + "LogonTrigger", trigger_disabled = trigger?.Element(Schema + "Enabled")?.Value == "false",
                    trigger_actor_matches = AccountSid(trigger?.Element(Schema + "UserId")?.Value) == OwnerSid,
                    demand_disabled = root.Element(Schema + "Settings")?.Element(Schema + "AllowStartOnDemand")?.Value == "false",
                    action_matches = action?.Name == Schema + "Exec", command_matches = action?.Element(Schema + "Command")?.Value == NeverRunExecutable,
                    arguments_match = action?.Element(Schema + "Arguments")?.Value == PrivateArgument, task_state = (int)native.State,
                    digest_matches = facts.DefinitionDigest == definitionDigest, expected_digest = definitionDigest, observed_digest = facts.DefinitionDigest }));
        if ((string)native.Path != path || (string)native.Xml != xml || (bool)native.Enabled != enabled ||
            new RawSecurityDescriptor((string)native.GetSecurityDescriptor(1)).Owner?.Value != owner)
            throw new InvalidOperationException("The generated task changed during fixture verification.");
        return facts;
    }

    private void RequireFolderOwner(object folder)
    {
        if ((string)((dynamic)folder).Path != FolderPath ||
            new RawSecurityDescriptor((string)((dynamic)folder).GetSecurityDescriptor(1)).Owner?.Value != OwnerSid)
            throw new InvalidOperationException("The fixture task folder has a different identity or owner.");
    }

    private static string? AccountSid(string? account)
    {
        if (string.IsNullOrWhiteSpace(account)) return null;
        try
        {
            return account.StartsWith("S-1-", StringComparison.Ordinal)
                ? new SecurityIdentifier(account).Value
                : ((SecurityIdentifier)new NTAccount(account).Translate(typeof(SecurityIdentifier))).Value;
        }
        catch (IdentityNotMappedException) { return null; }
        catch (ArgumentException) { return null; }
    }

    private string Definition() => new XDocument(new XElement(Schema + "Task", new XAttribute("version", "1.2"),
        new XElement(Schema + "RegistrationInfo", new XElement(Schema + "Source", marker)),
        new XElement(Schema + "Triggers", new XElement(Schema + "LogonTrigger",
            new XElement(Schema + "Enabled", false), new XElement(Schema + "UserId", OwnerSid))),
        new XElement(Schema + "Principals", new XElement(Schema + "Principal", new XAttribute("id", "Actor"),
            new XElement(Schema + "UserId", OwnerSid), new XElement(Schema + "LogonType", "InteractiveToken"),
            new XElement(Schema + "RunLevel", "LeastPrivilege"))),
        new XElement(Schema + "Settings", new XElement(Schema + "Enabled", false), new XElement(Schema + "AllowStartOnDemand", false)),
        new XElement(Schema + "Actions", new XAttribute("Context", "Actor"), new XElement(Schema + "Exec",
            new XElement(Schema + "Command", NeverRunExecutable), new XElement(Schema + "Arguments", PrivateArgument))))).ToString(SaveOptions.DisableFormatting);

    private void WriteEvidence(string stage, object details) => File.WriteAllText(Path.Combine(Root, $"{++sequence:D2}-{stage}.json"),
        JsonSerializer.Serialize(new
        {
            schema_version = 1, stage, at_utc = DateTimeOffset.UtcNow, task_path = TaskPath, owner_sid = OwnerSid,
            os = RuntimeInformation.OSDescription, process_arch = RuntimeInformation.ProcessArchitecture.ToString(),
            os_arch = RuntimeInformation.OSArchitecture.ToString(), generated_task_only = true, native_runtime_checked = true,
            public_execution_enabled = WindowsStartupControlMutation.PublicExecutionAvailable, details
        }, ContractJson.Options));

    private static object? FindFolder(object service, string path)
    {
        try { return (object)((dynamic)service).GetFolder(path); }
        catch (Exception error) when (Missing(error)) { return null; }
    }
    private static object? FindTask(object folder, string name)
    {
        try { return (object)((dynamic)folder).GetTask(name); }
        catch (Exception error) when (Missing(error)) { return null; }
    }
    private static bool Missing(Exception error) => (error is COMException or FileNotFoundException or DirectoryNotFoundException) &&
        (error.HResult is unchecked((int)0x80070002) or unchecked((int)0x80070003));
    private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    private static void Release(params object?[] values) { foreach (var value in values) LocalScheduledTaskReader.Release(value); }
    private static void RequireEnabled()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || !Environment.Is64BitProcess ||
            RuntimeInformation.ProcessArchitecture != RuntimeInformation.OSArchitecture ||
            RuntimeInformation.ProcessArchitecture is not (Architecture.X64 or Architecture.Arm64) ||
            Environment.GetEnvironmentVariable(OptInVariable) != "1")
            throw new InvalidOperationException("Generated task changes require explicit opt-in on matching native Windows 11.");
    }
}
