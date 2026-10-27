using System.Net;
using System.Net.Http.Headers;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed class WindowsDesktopUpdates
{
    private readonly Func<HttpMessageHandler> handlerFactory;
    public WindowsDesktopUpdates() : this(() => new SocketsHttpHandler
    { AllowAutoRedirect = false, UseCookies = false, Credentials = null, AutomaticDecompression = DecompressionMethods.None }) { }
    internal WindowsDesktopUpdates(Func<HttpMessageHandler> handlerFactory) => this.handlerFactory = handlerFactory;

    public async Task<DesktopUpdate> CheckAsync(string currentVersion, string architecture, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
        using var client = new HttpClient(handlerFactory(), disposeHandler: true) { Timeout = TimeSpan.FromSeconds(10) };
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/limecloud/shou/releases/latest");
        request.Headers.UserAgent.ParseAdd("Shou-Desktop-Updater/1");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK || response.Content.Headers.ContentType?.MediaType is not ("application/json" or "application/vnd.github+json") ||
            response.Content.Headers.ContentLength > DesktopUpdate.MaximumMetadataBytes)
            throw new ShouException("desktop_update_unavailable", "The desktop release endpoint did not return supported metadata.");
        await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
        using var bytes = new MemoryStream();
        var buffer = new byte[16_384];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, deadline.Token).ConfigureAwait(false);
            if (count == 0) break;
            if (bytes.Length + count > DesktopUpdate.MaximumMetadataBytes)
                throw new ShouException("desktop_update_unavailable", "The desktop release metadata exceeded its byte limit.");
            bytes.Write(buffer, 0, count);
        }
        return DesktopUpdate.Parse(bytes.ToArray(), currentVersion, architecture);
    }
}
