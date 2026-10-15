using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using EW.Minecraft.Function;
using Xunit;

public class BedrockStatusTests
{
    private const string ValidStatus = "{\"name\":\"Azure Bedrock\",\"protocol\":2177,\"version\":\"1.26.50\",\"players\":0,\"maxPlayers\":4}";

    [Fact]
    public async Task RequestsNetherNetStatusOnConfiguredPort()
    {
        using var client = CreateClient(ValidStatus, HttpStatusCode.OK, request =>
            Assert.Equal("http://bedrock.example:19200/v1/join", request.RequestUri.ToString()));
        var status = await BedrockStatus.GetAsync(client, "bedrock.example", 19200);
        Assert.Equal("1.26.50", status.Version);
        Assert.Equal(0, status.Players);
        Assert.Equal(4, status.MaxPlayers);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not JSON")]
    [InlineData("{}")]
    [InlineData("[]")]
    [InlineData("{\"name\":\"Other HTTP server\"}")]
    [InlineData("{\"name\":\"Bedrock\",\"protocol\":1,\"version\":\"1.26.50\",\"players\":5,\"maxPlayers\":4}")]
    [InlineData("{\"name\":\"Bedrock\",\"protocol\":1,\"version\":\"1.26.50\",\"players\":-1,\"maxPlayers\":4}")]
    [InlineData("{\"name\":\"Bedrock\",\"protocol\":1,\"version\":\"1.26.50\",\"players\":\"0\",\"maxPlayers\":4}")]
    [InlineData("{\"name\":\"Bedrock\",\"protocol\":1,\"version\":\"1.26.50\",\"players\":0,\"maxPlayers\":0}")]
    [InlineData("{\"name\":\"Bedrock\",\"protocol\":0,\"version\":\"1.26.50\",\"players\":0,\"maxPlayers\":4}")]
    public async Task RejectsInvalidServerStatus(string body)
    {
        using var client = CreateClient(body);
        await Assert.ThrowsAsync<InvalidDataException>(() => BedrockStatus.GetAsync(client, "bedrock.example", 19132));
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    public async Task RejectsUnsuccessfulHttpResponses(HttpStatusCode code)
    {
        using var client = CreateClient(ValidStatus, code);
        await Assert.ThrowsAsync<HttpRequestException>(() => BedrockStatus.GetAsync(client, "bedrock.example", 19132));
    }

    [Fact]
    public async Task HonorsRequestTimeout()
    {
        using var client = new HttpClient(new ResponseHandler(async (request, token) =>
        {
            await Task.Delay(Timeout.Infinite, token);
            return new HttpResponseMessage(HttpStatusCode.OK);
        })) { Timeout = TimeSpan.FromMilliseconds(50) };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => BedrockStatus.GetAsync(client, "bedrock.example", 19132));
    }

    private static HttpClient CreateClient(string body, HttpStatusCode code = HttpStatusCode.OK, Action<HttpRequestMessage> inspect = null)
    {
        return new HttpClient(new ResponseHandler((request, token) =>
        {
            inspect?.Invoke(request);
            return Task.FromResult(new HttpResponseMessage(code) { Content = new StringContent(body) });
        }));
    }

    private sealed class ResponseHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond;

        public ResponseHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond)
        {
            this.respond = respond;
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            return respond(request, cancellationToken);
        }
    }
}
