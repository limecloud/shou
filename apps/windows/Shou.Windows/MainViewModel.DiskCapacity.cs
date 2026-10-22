namespace Shou.Windows;

public sealed partial class MainViewModel
{
    private static string DefaultCapacityPath => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public string CleanupCapacityPath => SelectedWorkspace?.Path ?? DefaultCapacityPath;
    public string StorageCapacityPath => CurrentStorageFolder ?? DefaultCapacityPath;
    private string largeFilesCapacityPath = DefaultCapacityPath;
    public string LargeFilesCapacityPath { get => largeFilesCapacityPath; private set => SetProperty(ref largeFilesCapacityPath, value); }
}
