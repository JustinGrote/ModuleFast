using System.Management.Automation;
using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace ModuleFast;

public static class ModuleFastClient
{
  public static HttpClient Create(PSCredential? credential = null, int timeoutSeconds = 30)
  {
    AppContext.SetSwitch("System.Net.SocketsHttpHandler.Http3Support", true);
    var handler = new SocketsHttpHandler
    {
      // Allow more parallel connections to the same host (registry + CDN).
      MaxConnectionsPerServer = 20,
      // Allow an additional TCP connection when all HTTP/2 streams on the first are consumed.
      EnableMultipleHttp2Connections = true,
      InitialHttp2StreamWindowSize = 16777216,
      AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
      // Recycle connections after 5 minutes so stale long-lived connections don't silently fail.
      PooledConnectionLifetime = TimeSpan.FromMinutes(5),
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