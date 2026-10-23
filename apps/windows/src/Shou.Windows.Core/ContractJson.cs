using System.Text.Json;
using System.Text.Json.Serialization;

namespace Shou.Windows.Core;

public static class ContractJson
{
    public static JsonSerializerOptions Options { get; } = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
            WriteIndented = true,
            MaxDepth = 64,
            AllowDuplicateProperties = false,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            RespectNullableAnnotations = true,
            RespectRequiredConstructorParameters = true
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower, allowIntegerValues: false));
        options.Converters.Add(new WindowsPathConverter());
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }

    private sealed class WindowsPathConverter : JsonConverter<WindowsPath>
    {
        public override WindowsPath Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            WindowsPath.Parse(reader.GetString() ?? throw new JsonException("A Windows path is required."));
        public override void Write(Utf8JsonWriter writer, WindowsPath value, JsonSerializerOptions options) => writer.WriteStringValue(value.Value);
    }
}
