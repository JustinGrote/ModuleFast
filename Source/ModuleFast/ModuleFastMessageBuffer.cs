using System.Collections.Concurrent;
using System.Management.Automation;

namespace ModuleFast;

public enum ModuleFastMessageKind
{
  Verbose,
  Debug,
  Warning
}

public sealed class ModuleFastMessageBuffer
{
  private readonly ConcurrentQueue<(ModuleFastMessageKind Kind, string Message)> _messages = new();

  public void Verbose(string message) => _messages.Enqueue((ModuleFastMessageKind.Verbose, message));

  public void Debug(string message) => _messages.Enqueue((ModuleFastMessageKind.Debug, message));

  public void Warning(string message) => _messages.Enqueue((ModuleFastMessageKind.Warning, message));

  public void Flush(PSCmdlet cmdlet)
  {
    while (_messages.TryDequeue(out var message))
    {
      switch (message.Kind)
      {
        case ModuleFastMessageKind.Verbose:
          cmdlet.WriteVerbose(message.Message);
          break;
        case ModuleFastMessageKind.Debug:
          cmdlet.WriteDebug(message.Message);
          break;
        case ModuleFastMessageKind.Warning:
          cmdlet.WriteWarning(message.Message);
          break;
      }
    }
  }
}