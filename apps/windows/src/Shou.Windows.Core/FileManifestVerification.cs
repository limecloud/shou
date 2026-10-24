namespace Shou.Windows.Core;

/// <summary>Shared evidence comparison; directory metadata may change only after an authorized unlink.</summary>
public static class FileManifestVerification
{
    public static bool MatchesEntry(FileEntry actual, FileEntry expected, bool allowingDirectoryChanges = false) =>
        allowingDirectoryChanges && expected.Kind == EntryKind.Directory
            ? actual.Path == expected.Path && actual.Kind == EntryKind.Directory && actual.Identity == expected.Identity && actual.IsCaseSensitive == expected.IsCaseSensitive
            : actual == expected;
}
