using System.Windows.Markup;

namespace Shou.Windows;

[MarkupExtensionReturnType(typeof(string))]
public sealed class TextExtension(string key) : MarkupExtension
{
    public string Key { get; set; } = key;
    public override object ProvideValue(IServiceProvider serviceProvider) => UiText.FromKey(Key);
}
