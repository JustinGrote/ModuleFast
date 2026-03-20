using System.Net;
using System.Net.Http;

namespace ModuleFast;

public static class ModuleFastClient
{
    public static HttpClient Create(int timeoutSeconds = 30)
    {
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
        client.DefaultRequestHeaders.UserAgent.TryParseAdd("ModuleFast (github.com/JustinGrote/ModuleFast)");
        return client;
    }
}
