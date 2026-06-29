using System.Collections.Concurrent;

namespace ModuleFast;

public enum ModuleFastMessageKind
{
  Verbose,
  Debug,
  Warning
}

/// <summary>
/// A thread-safe buffered logger that implements <see cref="IModuleFastLogger"/>.
/// Messages are queued and can be flushed to another logger later (useful for background tasks).
/// </summary>
public sealed class ModuleFastMessageBuffer : IModuleFastLogger
{
  private readonly ConcurrentQueue<(ModuleFastMessageKind Kind, string Message)> _messages = new();

  public void Verbose(string message) => _messages.Enqueue((ModuleFastMessageKind.Verbose, message));

  public void Debug(string message) => _messages.Enqueue((ModuleFastMessageKind.Debug, message));

  public void Warning(string message) => _messages.Enqueue((ModuleFastMessageKind.Warning, message));

  /// <summary>
  /// Flushes all buffered messages to the specified logger.
  /// </summary>
  public void Flush(IModuleFastLogger logger)
  {
    while (_messages.TryDequeue(out (ModuleFastMessageKind Kind, string Message) message))
    {
      switch (message.Kind)
      {
        case ModuleFastMessageKind.Verbose:
          logger.Verbose(message.Message);
          break;
        case ModuleFastMessageKind.Debug:
          logger.Debug(message.Message);
          break;
        case ModuleFastMessageKind.Warning:
          logger.Warning(message.Message);
          break;
      }
    }
  }
}