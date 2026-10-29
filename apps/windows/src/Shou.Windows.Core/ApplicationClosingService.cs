using System.Collections.Immutable;

namespace Shou.Windows.Core;

/// <summary>Only observed users of this verified installation may receive a normal-close request.</summary>
public sealed class ApplicationClosingService(IWindowsFileSystem files, ICleanupApplicationClosing closing)
{
    public bool Available => closing.Available;
    public async Task<ImmutableArray<CleanupApplicationCloseResult>> CloseAsync(ApplicationUninstallReview review, CancellationToken token)
    {
        if (!Available) throw new ShouException("unsupported_capability", "Quit affected apps, then scan again.");
        if (review.Installation.IsProtected || review.Application.IsSystemPackage || review.Installation.Identity is null ||
            review.Installation.InstalledRoot is not { Kind: EntryKind.Directory } root || root.Path.IsVolumeRoot ||
            review.Activity.State != ActivityState.Active || review.BlockingReasons.Any(reason => reason != "application_running"))
            throw new ShouException("application_activity_unknown", "Review the exact installation before requesting its applications to quit.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        var snapshot = await new StorageScanner(files).ScanAsync(root.Path, new(4096, 32, TimeSpan.FromSeconds(10)), null, deadline.Token);
        if (!snapshot.IsComplete || !snapshot.IsCompleteAt(root.Path) || !snapshot.Issues.IsEmpty ||
            snapshot.RootIdentity != root.Identity || snapshot.Entries.IsDefaultOrEmpty || snapshot.Entries[0].Entry != root ||
            snapshot.Entries.Any(item => item.Entry.Kind is not (EntryKind.File or EntryKind.Directory) || item.Entry.Kind == EntryKind.File && item.Entry.LinkCount != 1)) throw Stale();
        var paths = snapshot.Entries.Where(item => item.Entry.Kind == EntryKind.File).Select(item => item.Entry.Path).ToImmutableArray();
        if (paths.IsEmpty) throw Stale();
        var users = await closing.InspectAsync(paths, deadline.Token);
        if (!users.Complete || users.Applications.IsDefaultOrEmpty) throw Stale();
        foreach (var item in snapshot.Entries)
            if (await files.InspectAsync(item.Entry.Path, deadline.Token) != item.Entry) throw Stale();
        // Native closing rechecks PID, birth time, account, session and image; no force option exists.
        return await new CleanupApplicationClosingService(closing).CloseSelectedAsync(users, users.Applications, token);
    }
    private static ShouException Stale() => new("application_activity_unknown", "Application users could not be verified. Save your work and quit manually.");
}
