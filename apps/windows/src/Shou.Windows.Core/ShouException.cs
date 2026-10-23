namespace Shou.Windows.Core;

public sealed class ShouException(string code, string message, Exception? innerException = null)
    : Exception(message, innerException)
{
    public string Code { get; } = code;
}
