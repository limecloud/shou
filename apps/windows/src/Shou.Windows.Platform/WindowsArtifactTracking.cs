using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Bounded native observations. Never starts Git, loads repository configuration or follows worktree pointers.</summary>
public sealed class WindowsArtifactTracking : IArtifactTracking
{
    public async Task<bool> HasTrackedContentAsync(WindowsPath target, string ownerSid, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(3));
        try
        {
            return await NativeOperationScheduler.RunAsync(() => Inspect(target, ownerSid, deadline.Token), deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw GitIndexReader.Unavailable(); }
    }

    private static bool Inspect(WindowsPath target, string ownerSid, CancellationToken token)
    {
        var depth = 0;
        for (var path = target.Parent; path is not null; path = path.Parent)
        {
            token.ThrowIfCancellationRequested();
            if (++depth > 256) throw GitIndexReader.Unavailable();
            using var pinned = WindowsFileSystem.PinPath(path);
            var before = WindowsFileSystem.ReadEntry(path, pinned.Final);
            // Ambiguous case-sensitive metadata aliases cannot prove the absence of another repository marker.
            if (before.Kind != EntryKind.Directory || before.IsCaseSensitive) throw GitIndexReader.Unavailable();
            foreach (var unsupported in new[] { ".hg", ".svn" })
            {
                using var marker = OptionalChild(pinned.Final, path.Append(unsupported));
                if (marker is not null) throw GitIndexReader.Unavailable();
            }
            var gitPath = path.Append(".git");
            using var git = OptionalChild(pinned.Final, gitPath);
            var tracked = false;
            if (git is not null)
            {
                var gitEntry = WindowsFileSystem.ReadEntry(gitPath, git);
                if (gitEntry.Kind != EntryKind.Directory || gitEntry.Identity.OwnerSid != ownerSid || gitEntry.IsCaseSensitive) throw GitIndexReader.Unavailable();
                // Worktrees, missing indexes, reparse points and unreadable metadata remain unavailable.
                var indexPath = gitPath.Append("index");
                using var index = NativeFileHandles.OpenChild(git, indexPath, caseSensitive: false);
                var indexEntry = WindowsFileSystem.ReadEntry(indexPath, index);
                if (indexEntry.Kind != EntryKind.File || indexEntry.LinkCount != 1 || indexEntry.Identity.OwnerSid != ownerSid) throw GitIndexReader.Unavailable();
                var bytes = WindowsFileSystem.ReadMetadataFile(indexPath, GitIndexReader.MaximumBytes, requireSingleLink: true, token);
                tracked = GitIndexReader.HasTrackedContent(bytes, target.RelativeTo(path, caseSensitive: true), token);
                if (WindowsFileSystem.ReadEntry(indexPath, index) != indexEntry || WindowsFileSystem.ReadEntry(gitPath, git) != gitEntry) throw GitIndexReader.Unavailable();
            }
            if (WindowsFileSystem.ReadEntry(path, pinned.Final) != before) throw GitIndexReader.Unavailable();
            if (tracked) return true;
            // Continue beyond nested repositories: a containing repository may also track the target.
        }
        return false;
    }

    private static SafeFileHandle? OptionalChild(SafeFileHandle parent, WindowsPath path)
    {
        try { return NativeFileHandles.OpenChild(parent, path, caseSensitive: false); }
        catch (ShouException error) when (error.Code == "not_found") { return null; }
    }
}
