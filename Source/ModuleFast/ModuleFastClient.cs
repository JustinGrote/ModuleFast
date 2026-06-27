using System.Management.Automation;
using System.Net;
using System.Net.Http.Headers;
using System.Text;

using Polly;
using Polly.Retry;

namespace ModuleFast;

public static class ModuleFastClient
{
  /// <summary>Default number of retry attempts for transient HTTP failures.</summary>
  public const int DefaultMaxRetries = 3;

  public static HttpClient Create(PSCredential? credential = null, int timeoutSeconds = 30, int maxRetries = DefaultMaxRetries)
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

    var resilienceHandler = new ResilienceHandler(CreateResiliencePipeline(maxRetries))
    {
      InnerHandler = handler
    };

    var client = new HttpClient(resilienceHandler)
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
        Delay = TimeSpan.FromSeconds(1),
        ShouldHandle = static args => ValueTask.FromResult(ShouldRetry(args.Outcome)),
        DelayGenerator = static args =>
        {
          // Respect Retry-After header on 429 responses
          if (args.Outcome.Result?.StatusCode == HttpStatusCode.TooManyRequests &&
              args.Outcome.Result.Headers.RetryAfter is { } retryAfter)
          {
            var delay = retryAfter.Delta
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
    var token = Convert.ToBase64String(
        Encoding.UTF8.GetBytes($"{credential.UserName}:{credential.GetNetworkCredential().Password}"));
    return new AuthenticationHeaderValue("Basic", token);
  }
}