using System.Text.Json;

namespace Shou.Windows.Core.Tests;

public sealed class UserDiagnosticsTests
{
    [Theory]
    [InlineData(null, null, DiagnosticState.Unknown)]
    [InlineData(0L, 0L, DiagnosticState.Unknown)]
    [InlineData(10L, 11L, DiagnosticState.Unknown)]
    [InlineData(10_000_000_000L, 1_000_000_000L, DiagnosticState.Attention)]
    [InlineData(10_000_000_000L, 5_000_000_000L, DiagnosticState.Normal)]
    public void InvalidAndLowCapacityKeepAccurateStatus(long? capacity, long? free, DiagnosticState expected)
    {
        var report = DiagnosticReport.Create("0.14.0", "x64", "10.0.26100", 8, 16_000_000_000, capacity, free, DiagnosticRecordState.Missing);
        Assert.Equal(expected, report.Checks[0].State);
        Assert.Equal(expected == DiagnosticState.Unknown ? "partial" : "complete", report.Status);
        Assert.Equal(DiagnosticState.NotApplicable, report.Checks[1].State);
        Assert.Equal(DiagnosticState.NotConfigured, report.Checks[2].State);
        Assert.Equal(3, report.Checks.Length);
    }

    [Theory]
    [InlineData(DiagnosticRecordState.PrivateDirectory, DiagnosticState.Normal)]
    [InlineData(DiagnosticRecordState.Unsafe, DiagnosticState.Attention)]
    [InlineData(DiagnosticRecordState.Unavailable, DiagnosticState.Unknown)]
    public void ReportDoesNotExposeArbitraryNativePayloads(DiagnosticRecordState records, DiagnosticState expected)
    {
        var report = DiagnosticReport.Create("0.14.0", "arm64", "10.0.26100", 8, null, null, null, records);
        Assert.Equal(expected, report.Checks[2].State);
        Assert.Equal("partial", report.Status);
        var json = JsonSerializer.Serialize(report, ContractJson.Options);
        using var document = JsonDocument.Parse(json);
        Assert.Equal(1, document.RootElement.GetProperty("format_version").GetInt32());
        Assert.Equal(JsonValueKind.Null, document.RootElement.GetProperty("physical_memory_bytes").ValueKind);
        Assert.DoesNotContain("C:/", json);
        Assert.Contains("Nothing is uploaded.", report.Text(key => key));
    }
}
