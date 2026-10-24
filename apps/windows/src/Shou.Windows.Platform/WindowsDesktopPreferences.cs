using System.Text.Json;
using System.Text.Json.Serialization;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed record DesktopPreferences(string Language = "system", string Theme = "system", bool ReduceMotion = false);

/// <summary>Appearance preferences use the same private, atomic storage as other user records.</summary>
public sealed class WindowsDesktopPreferences(IRecordStore store)
{
    private static readonly JsonSerializerOptions Options = new() { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
    public async Task<DesktopPreferences> ReadAsync(CancellationToken token)
    {
        var bytes = await store.ReadAsync("desktop_preferences", 4096, token);
        var value = bytes is null ? new() : JsonSerializer.Deserialize<DesktopPreferences>(bytes, Options)
            ?? throw new ShouException("corrupt_record", "The desktop preferences are invalid.");
        Validate(value);
        return value;
    }
    public Task SaveAsync(DesktopPreferences value, CancellationToken token)
    {
        Validate(value);
        return store.UpdateAsync(transaction => { transaction.Write("desktop_preferences", JsonSerializer.SerializeToUtf8Bytes(value, Options)); return true; }, token);
    }
    private static void Validate(DesktopPreferences value)
    {
        if (value.Language is not ("system" or "zh-CN" or "en-US") || value.Theme is not ("system" or "light" or "dark"))
            throw new ShouException("corrupt_record", "The desktop preferences contain unsupported values.");
    }
}
