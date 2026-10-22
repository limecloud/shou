using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Media.Imaging;
using Shou.Windows.Services;

namespace Shou.Windows;

public partial class FilePreviewDialog : Window
{
    private readonly BridgeProcessClient client;
    private readonly string scanId, path;
    private string absolutePath = "";
    private readonly CancellationTokenSource reading = new();
    private bool closed;

    public FilePreviewDialog(Window? owner, BridgeProcessClient client, string scanId, string path)
    {
        InitializeComponent(); Owner = owner; this.client = client; this.scanId = scanId; this.path = path;
        FileNameLabel.Text = path.Split('/').Last(); FilePathLabel.Text = path;
        PreviewStatus.Text = "正在读取本机预览…";
        Loaded += async (_, _) => await ReadAsync();
        Closed += (_, _) => { closed = true; reading.Cancel(); reading.Dispose(); };
    }

    private async Task ReadAsync()
    {
        try
        {
            var preview = await client.RequestAsync("storage.preview", new() { ["scan_id"] = scanId, ["path"] = path }, cancellation: reading.Token);
            if (!closed) ShowPreview(preview);
        }
        catch (Exception error) { if (!closed) PreviewStatus.Text = "预览未完成：" + error.Message; }
        finally { if (!closed) ReadingProgress.Visibility = Visibility.Collapsed; }
    }

    private void ShowPreview(JsonNode preview)
    {
        if (preview["path"]?.GetValue<string>() != path) throw new BridgeException("transport_failed", "预览结果与所选项目不一致。");
        TextPreview.Visibility = Visibility.Collapsed; ImageContainer.Visibility = Visibility.Collapsed; ImagePreview.Source = null;
        absolutePath = preview["absolute_path"]?.GetValue<string>() ?? "";
        FilePathLabel.Text = absolutePath;
        var measured = DateTimeOffset.TryParse(preview["measured_at"]?.GetValue<string>(), out var date) ? date.ToLocalTime().ToString("g") : "扫描时";
        FileFacts.Text = $"扫描快照 {measured} · 逻辑大小 {MainViewModel.Bytes(preview["logical_bytes"]?.GetValue<long>() ?? 0)} · 分配空间 {MainViewModel.Bytes(preview["allocated_bytes"]?.GetValue<long>() ?? 0)}";
        PreviewStatus.Text = preview["notice"]?.GetValue<string>() switch {
            "snapshot_metadata" => "显示此目录在扫描时的统计。",
            "format_unavailable" => "此格式显示文件信息，暂不提供内容预览。",
            "image_too_large" => "图片超过 4 MiB 预览上限，显示文件信息。",
            "text_prefix" => "显示文件开头的 256 KiB，后续内容已省略。",
            _ => "只读预览。内容仅在本机显示。"
        };
        if (preview["format"]?.GetValue<string>() == "text") {
            TextPreview.Text = preview["text"]?.GetValue<string>() ?? ""; TextPreview.Visibility = Visibility.Visible;
        }
        else if (preview["format"]?.GetValue<string>() == "image" && preview["image"]?.GetValue<string>() is { } encoded) {
            var bytes = Convert.FromBase64String(encoded);
            if (bytes.Length > 4 * 1024 * 1024) throw new BridgeException("output_limit", "图片超过预览上限。");
            using var stream = new MemoryStream(bytes, false);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.OnDemand);
            var frame = decoder.Frames[0];
            if (frame.PixelWidth <= 0 || frame.PixelHeight <= 0 || (long)frame.PixelWidth * frame.PixelHeight > 40_000_000)
                throw new BridgeException("output_limit", "图片尺寸超过预览上限。");
            stream.Position = 0;
            var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.DecodePixelWidth = Math.Min(frame.PixelWidth, 1600); bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze();
            ImagePreview.Source = bitmap; ImageContainer.Visibility = Visibility.Visible;
        }
    }
    private void CopyPathClicked(object sender, RoutedEventArgs args) { if (absolutePath.Length > 0) Clipboard.SetText(absolutePath); }
    internal void VerifyLayout()
    {
        ShowPreview(new JsonObject { ["path"] = path, ["absolute_path"] = "C:/layout-fixture/中文/preview.txt", ["format"] = "text", ["logical_bytes"] = 1048576, ["allocated_bytes"] = 1048576, ["measured_at"] = "2026-10-22T00:00:00Z", ["notice"] = "text_prefix", ["text"] = "生成的界面夹具\nRead-only text with <script> as literal content." });
        ReadingProgress.Visibility = Visibility.Collapsed;
        foreach (var size in new[] { new Size(860, 650), new Size(520, 400) }) { Measure(size); Arrange(new Rect(new Point(0, 0), size)); UpdateLayout(); }
        var image = new PngBitmapEncoder();
        image.Frames.Add(BitmapFrame.Create(BitmapSource.Create(1, 1, 96, 96, System.Windows.Media.PixelFormats.Bgra32, null, new byte[] { 192, 128, 32, 255 }, 4)));
        using var stream = new MemoryStream(); image.Save(stream);
        ShowPreview(new JsonObject { ["path"] = path, ["absolute_path"] = "C:/layout-fixture/image.png", ["format"] = "image", ["image"] = Convert.ToBase64String(stream.ToArray()) });
        Measure(new Size(860, 650)); Arrange(new Rect(0, 0, 860, 650)); UpdateLayout();
    }
}
