using System.Net;
using System.Net.Http.Headers;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed class WindowsApplicationUpdateCatalog : IApplicationUpdateCatalog
{
    private readonly Func<HttpMessageHandler> handlerFactory;
    public WindowsApplicationUpdateCatalog() : this(() => new SocketsHttpHandler
    { AllowAutoRedirect = false, UseCookies = false, Credentials = null, PreAuthenticate = false, AutomaticDecompression = DecompressionMethods.None }) { }
    internal WindowsApplicationUpdateCatalog(Func<HttpMessageHandler> handlerFactory) => this.handlerFactory = handlerFactory;

    public async Task<byte[]> ReadAsync(CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); deadline.CancelAfter(TimeSpan.FromSeconds(15));
        using var client = new HttpClient(handlerFactory(), disposeHandler: true) { Timeout = TimeSpan.FromSeconds(10) };
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/microsoft/vscode/releases/latest");
        request.Headers.UserAgent.ParseAdd("Shou-Update-Discovery/1");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
        if ((int)response.StatusCode is >= 300 and < 400) throw new ShouException("update_redirect_refused", "The catalog redirected outside its fixed endpoint.");
        if (response.StatusCode != HttpStatusCode.OK || response.Content.Headers.ContentType?.MediaType is not ("application/json" or "application/vnd.github+json"))
            throw new ShouException("update_invalid_response", "The catalog response is unavailable or unsupported.");
        if (response.Content.Headers.ContentLength > ApplicationUpdateChecker.MaximumMetadataBytes) throw TooLarge();
        await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
        using var result = new MemoryStream(); var buffer = new byte[16_384];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, deadline.Token).ConfigureAwait(false); if (count == 0) break;
            if (result.Length + count > ApplicationUpdateChecker.MaximumMetadataBytes) throw TooLarge();
            result.Write(buffer, 0, count);
        }
        return result.ToArray();
    }

    public static ApplicationUpdateChecker CreateChecker() => new(new(new WindowsApplicationInventory()), new WindowsApplicationUpdateCatalog());
    private static ShouException TooLarge() => new("update_response_too_large", "The catalog response exceeded its byte limit.");
}
