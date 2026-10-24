using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;
using Shou.Windows.Core;
using static Shou.Windows.Platform.Tests.WindowsFileSystemTests;

namespace Shou.Windows.Platform.Tests;

public sealed class NativeDiagnosticsTests
{
    [Fact]
    public void StructuredEvidenceKeepsStagesAndNativeCodesWithoutMessagesPathsOrSids()
    {
        var exception = new ShouException("permission_denied", "password=do-not-log", new Win32Exception(5, "C:/Users/Private/secret.txt"));
        var item = new OperationDiagnostic("op1", "parent1", "locations.prepare", "failed", 12,
            Stage: "parent_security", Path: WindowsPath.Parse("C:/Users/Private/secret.txt"), OwnerKind: "administrators", Error: exception);
        var json = NativeDiagnostics.Format(item);
        Assert.DoesNotContain("do-not-log", json);
        Assert.DoesNotContain("Private", json);
        Assert.DoesNotContain("secret.txt", json);
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        Assert.Equal(1, root.GetProperty("schema_version").GetInt32());
        Assert.Equal("parent1", root.GetProperty("parent_id").GetString());
        Assert.Equal("parent_security", root.GetProperty("stage").GetString());
        Assert.Equal("permission_denied", root.GetProperty("code").GetString());
        Assert.Equal(5, root.GetProperty("exceptions")[1].GetProperty("win32_error").GetInt32());
        Assert.Equal(16, root.GetProperty("path_ref").GetString()!.Length);
        using var repeated = JsonDocument.Parse(NativeDiagnostics.Format(item));
        Assert.Equal(root.GetProperty("path_ref").GetString(), repeated.RootElement.GetProperty("path_ref").GetString());
    }

    [Fact]
    public void UntrustedDiagnosticLabelsCannotSmugglePrivateText()
    {
        var item = new OperationDiagnostic("op1", null, "C:/private/path", "failed", 0, Stage: "token=secret", Error: new ShouException("key=secret", "secret"));
        var json = NativeDiagnostics.Format(item);
        Assert.DoesNotContain("secret", json);
        Assert.DoesNotContain("private/path", json);
        Assert.Contains("redacted", json);
    }

    [WindowsFact]
    public void DiagnosticFilesRejectHardLinksAndKeepTheOutsideBytes()
    {
        using var fixture = new NativeFixture();
        var root = WindowsPath.Parse(fixture.CreateDirectory("Diagnostics"));
        var store = new WindowsRecordStore(root);
        using var pinned = store.PinPrivateDirectory();
        var outside = fixture.Write("outside.jsonl", []);
        var log = Path.Combine(root.Value, "application.jsonl");
        Assert.True(FixtureNative.CreateHardLink(log, outside, 0), $"Hard-link fixture failed: {Marshal.GetLastWin32Error()}");
        Assert.Equal("store_corrupt", Assert.Throws<ShouException>(() => store.OpenDiagnosticFile("application.jsonl")).Code);
        Assert.Empty(File.ReadAllBytes(outside));
    }

    [WindowsFact]
    public async Task ConcurrentEventsAreValidJsonAndRotationStaysBounded()
    {
        using var fixture = new NativeFixture();
        var store = new WindowsRecordStore(WindowsPath.Parse(Path.Combine(fixture.Root, "Diagnostics")));
        var payload = new string('a', 16_384);
        await Task.WhenAll(Enumerable.Range(0, 90).Select(index => Task.Run(() =>
            NativeDiagnostics.Append(JsonSerializer.Serialize(new { index, payload }), store))));
        var files = Directory.GetFiles(store.Directory.Value, "application.jsonl*");
        Assert.Equal(2, files.Length);
        var ids = new HashSet<int>();
        foreach (var file in files)
        {
            Assert.InRange(new FileInfo(file).Length, 1, 1_048_576);
            foreach (var line in File.ReadLines(file))
            {
                using var parsed = JsonDocument.Parse(line);
                Assert.True(ids.Add(parsed.RootElement.GetProperty("index").GetInt32()));
            }
        }
        Assert.Equal(90, ids.Count);
    }
}
