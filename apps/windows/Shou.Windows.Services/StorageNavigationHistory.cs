namespace Shou.Windows.Services;

/// <summary>Commit navigation only after the requested directory has loaded.</summary>
public sealed class StorageNavigationHistory
{
    private readonly Stack<string> previous = new(), next = new();
    public string Current { get; private set; } = ".";
    public string? BackTarget => previous.TryPeek(out var path) ? path : null;
    public string? ForwardTarget => next.TryPeek(out var path) ? path : null;
    public void Reset() { Current = "."; previous.Clear(); next.Clear(); }
    public void Visit(string path)
    {
        if (path == Current) return;
        previous.Push(Current); Current = path; next.Clear();
    }
    public void CommitBack()
    {
        if (!previous.TryPop(out var path)) return;
        next.Push(Current); Current = path;
    }
    public void CommitForward()
    {
        if (!next.TryPop(out var path)) return;
        previous.Push(Current); Current = path;
    }
}
