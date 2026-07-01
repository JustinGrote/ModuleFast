using System.Management.Automation;
using System.Net;
using System.Net.Http.Headers;
using System.Text;

using Polly;
using Polly.Retry;

namespace ModuleFast;

/// <summary>Helper to build a <see cref="WebProxy"/> from standard HTTP_PROXY / HTTPS_PROXY / NO_PROXY environment variables.</summary>
internal static class EnvironmentProxy
{
  internal static IWebProxy? Create()
  {
    // Prefer lowercase (convention on Linux), fall back to uppercase (common on Windows/CI).
    var httpsProxy = Environment.GetEnvironmentVariable("HTTPS_PROXY")
        ?? Environment.GetEnvironmentVariable("https_proxy");
    var httpProxy = Environment.GetEnvironmentVariable("HTTP_PROXY")
        ?? Environment.GetEnvironmentVariable("http_proxy");

    var proxyUrl = httpsProxy ?? httpProxy;
    if (string.IsNullOrWhiteSpace(proxyUrl)) return null;

    var proxy = new WebProxy(proxyUrl);

    var noProxy = Environment.GetEnvironmentVariable("NO_PROXY")
        ?? Environment.GetEnvironmentVariable("no_proxy");
    if (!string.IsNullOrWhiteSpace(noProxy))
    {
      proxy.BypassList = noProxy
          .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
          .Select(host => "^" + System.Text.RegularExpressions.Regex.Escape(host)
              .Replace("\\*", ".*") + "$")
          .ToArray();
    }

    return proxy;
  }
}

public static class ModuleFastClient
{
  /// <summary>Default number of retry attempts for transient HTTP failures.</summary>
  public const int DefaultMaxRetries = 3;

  public static HttpClient Create(NetworkCredential? credential = null, int timeoutSeconds = 30, int maxRetries = DefaultMaxRetries)
  {
    AppContext.SetSwitch("System.Net.SocketsHttpHandler.Http3Support", true);
    SocketsHttpHandler handler = new SocketsHttpHandler
    {
      // Allow more parallel connections to the same host (registry + CDN).
      MaxConnectionsPerServer = 30,
      // Allow an additional TCP connection when all HTTP/2 streams on the first are consumed.
      EnableMultipleHttp2Connections = true,
      InitialHttp2StreamWindowSize = 16777216,
      AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
      // Recycle connections after 5 minutes so stale long-lived connections don't silently fail.
      PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    };

    // Honour HTTP_PROXY / HTTPS_PROXY / NO_PROXY environment variables on all platforms.
    IWebProxy? envProxy = EnvironmentProxy.Create();
    if (envProxy != null)
    {
      handler.Proxy = envProxy;
      handler.UseProxy = true;
    }

    ResilienceHandler resilienceHandler = new ResilienceHandler(CreateResiliencePipeline(maxRetries))
    {
      InnerHandler = handler
    };

    HttpClient client = new HttpClient(resilienceHandler)
    {
      Timeout = TimeSpan.FromSeconds(timeoutSeconds),
      DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrHigher
    };
    client.DefaultRequestHeaders.UserAgent.TryParseAdd("ModuleFast (github.com/JustinGrote/ModuleFast)");
    if (credential != null)
      client.DefaultRequestHeaders.Authorization = ToAuthHeader(credential);
    return client;
  }

  private static ResiliencePipeline<HttpResponseMessage> CreateResiliencePipeline(int maxRetries)
  {
    return new ResiliencePipelineBuilder<HttpResponseMessage>()
      .AddRetry(new RetryStrategyOptions<HttpResponseMessage>
      {
        MaxRetryAttempts = maxRetries,
        BackoffType = DelayBackoffType.Exponential,
        UseJitter = true,
        Delay = TimeSpan.FromMilliseconds(200),
        ShouldHandle = static args => ValueTask.FromResult(ShouldRetry(args.Outcome)),
        DelayGenerator = static args =>
        {
          // Respect Retry-After header on 429 responses
          if (args.Outcome.Result?.StatusCode == HttpStatusCode.TooManyRequests &&
              args.Outcome.Result.Headers.RetryAfter is { } retryAfter)
          {
            TimeSpan? delay = retryAfter.Delta
                ?? (retryAfter.Date.HasValue ? retryAfter.Date.Value - DateTimeOffset.UtcNow : (TimeSpan?)null);
            if (delay.HasValue && delay.Value > TimeSpan.Zero)
              return ValueTask.FromResult<TimeSpan?>(delay.Value);
          }
          return ValueTask.FromResult<TimeSpan?>(null); // use default backoff
        }
      })
      .Build();
  }

  private static bool ShouldRetry(Outcome<HttpResponseMessage> outcome)
  {
    // Retry on transient exceptions (timeouts, connection resets, etc.)
    if (outcome.Exception is HttpRequestException or TaskCanceledException)
      return true;

    if (outcome.Result is null)
      return false;

    return outcome.Result.StatusCode is
      HttpStatusCode.TooManyRequests or        // 429
      HttpStatusCode.RequestTimeout or         // 408
      HttpStatusCode.InternalServerError or    // 500
      HttpStatusCode.BadGateway or             // 502
      HttpStatusCode.ServiceUnavailable or     // 503
      HttpStatusCode.GatewayTimeout;           // 504
  }

  public static AuthenticationHeaderValue ToAuthHeader(PSCredential credential)
  {
    return ToAuthHeader(credential.GetNetworkCredential());
  }

  public static AuthenticationHeaderValue ToAuthHeader(NetworkCredential credential)
  {
    var token = Convert.ToBase64String(
        Encoding.UTF8.GetBytes($"{credential.UserName}:{credential.Password}"));
    return new AuthenticationHeaderValue("Basic", token);
  }
}