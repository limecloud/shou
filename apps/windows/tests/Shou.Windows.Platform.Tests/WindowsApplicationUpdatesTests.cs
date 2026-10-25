using System.Net;
using System.Net.Http.Headers;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsApplicationUpdatesTests
{
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.Equal("https://api.github.com/repos/microsoft/vscode/releases/latest", request.RequestUri!.AbsoluteUri);
            Assert.Null(request.Headers.Authorization); Assert.False(request.Headers.Contains("Cookie"));
            Assert.Equal(HttpMethod.Get, request.Method); return Task.FromResult(response(request));
        }
    }

    [Theory]
    [InlineData(200, "application/json", 16, null)]
    [InlineData(302, "application/json", 16, "update_redirect_refused")]
    [InlineData(401, "application/json", 16, "update_invalid_response")]
    [InlineData(200, "text/html", 16, "update_invalid_response")]
    [InlineData(200, "application/json", 1048577, "update_response_too_large")]
    public async Task TransportPinsTheSourceAndRejectsRedirectsTypesAndOversize(int status, string type, int bytes, string? code)
    {
        var source = new WindowsApplicationUpdateCatalog(() => new Handler(_ =>
        {
            var response = new HttpResponseMessage((HttpStatusCode)status) { Content = new ByteArrayContent(new byte[bytes]) };
            response.Content.Headers.ContentType = new MediaTypeHeaderValue(type); return response;
        }));
        if (code is null) Assert.Equal(bytes, (await source.ReadAsync(default)).Length);
        else Assert.Equal(code, (await Assert.ThrowsAsync<ShouException>(() => source.ReadAsync(default))).Code);
    }
}
