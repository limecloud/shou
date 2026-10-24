using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Shou.Windows.Core;

namespace Shou.Windows.App;

/// <summary>Expose production state through UI Automation and record transitions, not progress ticks.</summary>
internal static class PageDiagnostics
{
    private sealed class Previous { public string? Signature; }
    private static readonly ConditionalWeakTable<FrameworkElement, Previous> States = new();

    internal static void Update(FrameworkElement page, string name, object state, string? error = null, long? count = null)
    {
        var status = state.ToString()!.ToLowerInvariant();
        var signature = status + (error is null ? "" : ":" + error);
        AutomationProperties.SetAutomationId(page, "page." + name);
        AutomationProperties.SetItemStatus(page, signature);
        var previous = States.GetOrCreateValue(page);
        if (previous.Signature == signature) return;
        previous.Signature = signature;
        using var diagnostic = OperationDiagnostics.Start("page." + name);
        if (error is not null) diagnostic.Issue(error, "presentation");
        diagnostic.Complete(status, count);
    }
}
