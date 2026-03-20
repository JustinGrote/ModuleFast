using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Management.Automation;

namespace ModuleFast;

public static class ModuleFastClient
{
    public static HttpClient Create(PSCredential? credential = null, int timeoutSeconds = 30)
    {
        AppContext.SetSwitch("System.Net.SocketsHttpHandler.Http3Support", true);
        var handler = new SocketsHttpHandler
        {
            MaxConnectionsPerServer = 10,
            InitialHttp2StreamWindowSize = 16777216,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli
        };
        var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(timeoutSeconds)
        };
        client.DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrHigher;
        client.DefaultRequestHeaders.UserAgent.TryParseAdd("ModuleFast (github.com/JustinGrote/ModuleFast)");
        if (credential != null)
            client.DefaultRequestHeaders.Authorization = ToAuthHeader(credential);
        return client;
    }

    public static AuthenticationHeaderValue ToAuthHeader(PSCredential credential)
    {
        var token = Convert.ToBase64String(
            Encoding.UTF8.GetBytes($"{credential.UserName}:{credential.GetNetworkCredential().Password}"));
        return new AuthenticationHeaderValue("Basic", token);
    }
}
