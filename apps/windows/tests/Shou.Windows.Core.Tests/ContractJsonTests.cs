using System.Text.Json;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class ContractJsonTests
{
    [Fact]
    public void NativeIdentityAndWindowsPathsRoundTripWithStableMachineNames()
    {
        var fs = new MemoryFileSystem();
        var entry = fs.Add(@"C:\Users\开发者\cache.bin");
        var encoded = JsonSerializer.Serialize(entry, ContractJson.Options);
        using var document = JsonDocument.Parse(encoded);
        Assert.Equal(entry.Path.Value, document.RootElement.GetProperty("path").GetString());
        Assert.Equal("file", document.RootElement.GetProperty("kind").GetString());
        Assert.Equal(entry.Identity.OwnerSid, document.RootElement.GetProperty("identity").GetProperty("owner_sid").GetString());
        Assert.Equal(JsonValueKind.String, document.RootElement.GetProperty("identity").GetProperty("volume_serial_number").ValueKind);
        Assert.Equal(entry, JsonSerializer.Deserialize<FileEntry>(encoded, ContractJson.Options));
    }

    [Theory]
    [InlineData("{\"path\":null}")]
    [InlineData("{\"invented\":true}")]
    public void RejectsMissingRequiredMetadataAndUnknownProperties(string json) =>
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<FileEntry>(json, ContractJson.Options));

    [Fact]
    public void ImportedPathsStillUseWindowsSafetyParsing() =>
        Assert.Throws<ShouException>(() => JsonSerializer.Deserialize<WindowsPath>("\"C:/Work/../escape\"", ContractJson.Options));

    [Fact]
    public void NativeIdentityIsNotReducedToPosixFields()
    {
        var identity = new FileIdentity(ulong.MaxValue, new string('f', 32), "S-1-5-21-1234");
        Assert.Equal(new string('F', 32), identity.FileId);
        Assert.Equal(ulong.MaxValue, identity.VolumeSerialNumber);
        Assert.Throws<ShouException>(() => new FileIdentity(1, "1234", "S-1-5-21-1234"));
        Assert.Throws<ShouException>(() => new FileIdentity(1, new string('f', 32), "1234"));
    }
}
