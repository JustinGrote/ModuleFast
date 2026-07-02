using Polly;

namespace ModuleFast;

/// <summary>
/// A DelegatingHandler that wraps HTTP requests with a Polly resilience pipeline
/// for retry logic with exponential backoff and Retry-After header support.
/// </summary>
internal sealed class ResilienceHandler(ResiliencePipeline<HttpResponseMessage> pipeline) : DelegatingHandler
{
  protected override async Task<HttpResponseMessage> SendAsync(
      HttpRequestMessage request, CancellationToken cancellationToken)
  {
    return await pipeline.ExecuteAsync(
      async ct => await base.SendAsync(request, ct).ConfigureAwait(false),
      cancellationToken
    ).ConfigureAwait(false);
  }
}