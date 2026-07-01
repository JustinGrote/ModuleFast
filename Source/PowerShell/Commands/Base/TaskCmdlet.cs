namespace System.Management.Automation;

using System.Collections;
using System.Collections.Concurrent;
using System.Threading;

using ModuleFast;

public class TaskCmdletInteractor(TaskCmdlet cmdlet) : CmdletInteraction
{
  public string? HostName => cmdlet.Host.Name;

  public Task<bool> Confirm(string target, string action) => cmdlet.Confirm(target, action);

  public object? GetVariable(string name) => cmdlet.Exec(() => cmdlet.GetVariableValue(name));

  public void Debug(string message) => cmdlet.Debug(message, false);

  public void Verbose(string message) => cmdlet.Verbose(message);

  public void Info(string message, string[]? tags = null) => cmdlet.Info(message, tags);

  public void Warning(string message) => cmdlet.Warning(message);
}

public abstract class TaskCmdlet : TaskCmdlet<object> { }

public abstract class TaskCmdlet<TOutput> : BetterPSCmdlet, IDisposable
  where TOutput : notnull
{
  /// <summary>Called once before the first pipeline object. Override for async initialization.</summary>
  protected virtual Task Begin() => Task.CompletedTask;

  /// <summary>Called for each pipeline input object. Override to process items asynchronously.</summary>
  protected virtual Task Process() => Task.CompletedTask;

  /// <summary>Called after all pipeline input has been processed. Override for async finalization.</summary>
  protected virtual Task End() => Task.CompletedTask;

  /// <summary>Called when the pipeline is stopped (Ctrl+C). Override for async cleanup/resource release.</summary>
  protected virtual Task Clean() => Task.CompletedTask;

  /// <summary>Synchronous hook executed on the main thread <em>before</em> <see cref="Begin"/> is enqueued. Use for setup that must run on the pipeline thread (e.g. reading bound parameters).</summary>
  protected virtual void PreBegin() { }

  /// <summary>Synchronous hook executed on the main thread <em>after</em> <see cref="Begin"/> completes and its output is drained.</summary>
  protected virtual void PostBegin() { }

  /// <summary>Synchronous hook executed on the main thread <em>before</em> <see cref="Process"/> is enqueued.</summary>
  protected virtual void PreProcess() { }

  /// <summary>Synchronous hook executed on the main thread <em>after</em> <see cref="Process"/> completes and its output is drained.</summary>
  protected virtual void PostProcess() { }

  /// <summary>Synchronous hook executed on the main thread <em>before</em> <see cref="End"/> is enqueued.</summary>
  protected virtual void PreEnd() { }

  /// <summary>Synchronous hook executed on the main thread <em>after</em> <see cref="End"/> completes and its output is drained.</summary>
  protected virtual void PostEnd() { }

  /// <summary>Synchronous hook executed on the main thread during <see cref="StopProcessing"/> before <see cref="Clean"/> runs.</summary>
  protected virtual void PreClean() { }

  /// <summary>Synchronous hook executed on the main thread during <see cref="StopProcessing"/> before <see cref="Clean"/> runs.</summary>
  protected virtual void PostClean() { }

  /// <summary>
  /// Queues output for the cmdlet pipeline. This is the primary method used to send data through the async pipeline,
  /// and the other output helpers build on top of it.
  /// </summary>
  private void AddOutput(object item, bool raw = false, CancellationToken? cancelToken = null)
  {
    if (_output is null)
    {
      throw new InvalidOperationException("WriteObject cannot be called before the pipeline is initialized.");
    }
    _output.Add(new(item, raw), cancelToken ?? PipelineStopToken);
  }

  /// <summary>
  /// Queues an action to be executed on the main thread of the cmdlet. This is useful for evaluating script properties, etc. that need to be run on the main thread to avoid marshalling issues. Your function can return a result and it will be brought back to the calling thread, but it must be serializable across threads (i.e. no PSObjects, etc.)
  /// </summary>
  public async Task<T> Exec<T>(Func<T> action)
  {
    TaskCompletionSource<object?> response = new();
    AddOutput(new MainAction(() => action(), response));
    return (T?)await response.Task.ConfigureAwait(false) ?? default!;
  }

  /// <summary>
  /// Queues an action to be executed on the main thread of the cmdlet. This is useful for evaluating script properties, etc. that need to be run on the main thread to avoid marshalling issues.
  /// </summary>
  protected async Task Post(Action action)
  {
    TaskCompletionSource<object?> response = new();
    AddOutput(new MainAction(() =>
    {
      action();
      return null;
    }, response));
    await response.Task.ConfigureAwait(false);
  }

  /// <summary>
  /// Buffers output from asynchronous pipeline steps on separate threads before writing it to the pipeline.
  /// A single collection is reused across all pipeline steps for the cmdlet's lifetime.
  /// </summary>
  private BlockingCollection<OutputItem> _output = [];

  /// <summary>
  /// Work queue feeding the single persistent background worker. Each pipeline step
  /// (Begin, Process, End) enqueues its async method here rather than spawning a new Task.Run.
  /// </summary>
  private readonly BlockingCollection<Func<Task>> _workQueue = [];

  /// <summary>
  /// The single background worker task that processes all pipeline steps sequentially.
  /// </summary>
  private Task? _workerTask;

  // Override the pscmdlet entrypoints to route through the persistent worker
  protected sealed override void BeginProcessing()
  {
    _workerTask = Task.Run(WorkerLoopAsync, PipelineStopToken);
    PreBegin();
    ExecuteStep(Begin);
    PostBegin();
  }

  protected sealed override void ProcessRecord()
  {
    PreProcess();
    ExecuteStep(Process);
    PostProcess();
  }

  protected sealed override void EndProcessing()
  {
    PreEnd();
    ExecuteStep(End);

    // Signal no more work; the worker will complete the output collection
    _workQueue.CompleteAdding();

    // Drain any final items (e.g. if worker adds output after the sentinel race)
    foreach (OutputItem item in _output.GetConsumingEnumerable(PipelineStopToken))
    {
      ProcessOutput(item);
    }

    // Wait for the worker to finish and clean up
    _workerTask?.GetAwaiter().GetResult();

    PostEnd();
  }


  /// <summary>
  /// Enqueues an async work item to the persistent worker and drains output on the
  /// main thread until the step signals completion via a <see cref="StepComplete"/> sentinel.
  /// </summary>
  private void ExecuteStep(Func<Task> work)
  {
    _workQueue.Add(work, PipelineStopToken);

    // Drain output items until the worker signals this step is done
    foreach (OutputItem item in _output.GetConsumingEnumerable(PipelineStopToken))
    {
      if (item.Item is StepComplete) return;
      ProcessOutput(item);
    }
  }

  /// <summary>
  /// The single persistent background worker. Processes queued work items sequentially,
  /// emitting a <see cref="StepComplete"/> sentinel after each one so the main thread
  /// knows when to stop draining and return from the current pipeline step.
  /// </summary>
  private async Task WorkerLoopAsync()
  {
    try
    {
      foreach (Func<Task> work in _workQueue.GetConsumingEnumerable(PipelineStopToken))
      {
        try
        {
          await work().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
          Error(ex, terminating: true);
        }
        // Signal step completion so the main thread's EnqueueAndDrain returns
        _output.Add(new OutputItem(new StepComplete(), false), PipelineStopToken);
      }
    }
    finally
    {
      _output.CompleteAdding();
    }
  }

  /// <summary>
  /// Executes the Clean step in isolation. Used by StopProcessing when the main
  /// worker may already be dead due to cancellation.
  /// </summary>
  private void ExecuteCleanStep()
  {
    PreClean();
    using var cleanOutput = new BlockingCollection<OutputItem>();
    _output = cleanOutput;

    var task = Task.Run(async () =>
    {
      try
      {
        await Clean().ConfigureAwait(false);
      }
      catch { /* best-effort cleanup */ }
      finally
      {
        cleanOutput.CompleteAdding();
      }
    });

    try
    {
      foreach (OutputItem item in cleanOutput.GetConsumingEnumerable())
        ProcessOutput(item);
    }
    catch { /* pipeline may already be stopped */ }

    try { task.GetAwaiter().GetResult(); } catch { }
    PostClean();
  }

  private void ProcessOutput(OutputItem inputObject)
  {
    (object? item, bool raw) = inputObject;

    if (raw)
    {
      base.WriteObject(item);
      return;
    }

    switch (item)
    {
      case TerminatingError terminatingError:
        ThrowTerminatingError(terminatingError.Error);
        break;
      case ShouldProcessPrompt prompt:
        bool response = string.IsNullOrEmpty(prompt.Action)
          ? ShouldProcess(prompt.Target)
          : ShouldProcess(prompt.Target, prompt.Action);
        prompt.Response.TrySetResult(response);
        break;
      case ShouldProcessCustomPrompt customPrompt:
        bool customResponse = ShouldProcess(customPrompt.whatIfMessage, customPrompt.confirmHeader, customPrompt.confirmMessage);
        customPrompt.Response.TrySetResult(customResponse);
        break;
      case ErrorRecord errorRecord:
        base.WriteError(errorRecord);
        break;
      case InformationRecord informationRecord:
        base.WriteInformation(informationRecord);
        break;
      case TaggedInformationInfo taggedInformationInfo:
        base.WriteInformation(taggedInformationInfo.MessageData, taggedInformationInfo.Tags);
        break;
      case WarningRecord warningRecord:
        base.WriteWarning(warningRecord.Message);
        break;
      case VerboseRecord verboseRecord:
        base.WriteVerbose(verboseRecord.Message);
        break;
      case DebugRecord debugRecord:
        base.WriteDebug(debugRecord.Message);
        break;
      case ProgressRecord progressRecord:
        base.WriteProgress(progressRecord);
        break;
      case MainAction mainAction:
        try
        {
          object? result = mainAction.Action();
          mainAction.Response?.TrySetResult(result);
        }
        catch (Exception ex)
        {
          if (mainAction.Response == null) throw;
          mainAction.Response.TrySetException(ex);
        }
        finally
        {
          // Ensure we don't have any deadlocks by waiting on the main thread for a response that will never come because of an exception, etc.
          if (!mainAction.Response?.Task?.IsCompleted ?? false)
          {
            mainAction.Response?.TrySetCanceled();
          }
        }
        break;
      case TOutput:
        base.WriteObject(item);
        break;
      default:
        throw new InvalidOperationException($"Unexpected output item type: {item.GetType().FullName}");
    }
  }


  /// <summary>
  /// Writes an object to the pipeline via the async-safe output buffer.
  /// This override routes output through the <see cref="BlockingCollection{T}"/> so it can
  /// be called from any thread without marshalling issues.
  /// </summary>
  /// <param name="outputObject">The object to emit to the pipeline.</param>
  /// <param name="enumerateCollection">When <c>true</c>, enumerates <see cref="IEnumerable"/> objects and writes each element individually.</param>
  public void WriteObject(IEnumerable<TOutput> outputObject, bool enumerateCollection = false)
  {
    if (enumerateCollection && outputObject is not string)
    {
      foreach (TOutput? item in outputObject)
      {
        if (item is null) continue;
        AddOutput(item, true);
        return;
      }
    }

    AddOutput(outputObject, true);
  }
  public void WriteObject(TOutput outputObject) => WriteObject([outputObject], false);
  public new void WriteObject(object outputObject, bool enumerateCollection = false) => throw new InvalidCastException("You attempted to write an object not compatible with the cmdlet's generic output type.");

  public void Output(TOutput output) => AddOutput(output);
  public void Output(IEnumerable<TOutput> output) => AddOutput(output, true);
  public new void Debug(string message, bool raw = false) => WriteDebug(raw ? message : $"{Name}: {message}");
  public new void Verbose(string message, bool raw = false) => WriteVerbose(raw ? message : $"{Name}: {message}");
  public new void Warning(string message, bool raw = false) => WriteWarning(raw ? message : $"{Name}: {message}");
  public new void Info(string message, string[]? tags = null, bool raw = false)
    => WriteInformation(raw ? message : $"{Name}: {message}", tags ?? []);
  public void WriteHost(string message, bool raw = false)
    => WriteInformation(raw ? message : $"{Name}: {message}", ["PSHOST"]);
  public new void Progress(
    string activity,
    string status = "",
    string currentOperation = "",
    int percentComplete = 0,
    int id = 1,
    int parentId = -1,
    bool completed = false
  ) => WriteProgress(new ProgressRecord(id, activity, status)
  {
    CurrentOperation = currentOperation,
    ParentActivityId = parentId,
    RecordType = completed || percentComplete == 100 ? ProgressRecordType.Completed : ProgressRecordType.Processing,
    PercentComplete = percentComplete
  });

  public new void Error(
      Exception exception,
      string? recommendedAction = null,
      string errorId = "PSCmdletError",
      object? targetObject = null,
      // Usually comes from the exception message, specify this to override
      string? errorDetailsMessage = null,
      // This is often autodetermined
      ErrorCategory? category = null,
      bool terminating = false)
  {
    ErrorRecord error = new(
        exception,
        errorId,
        category ?? exception switch
        {
          ArgumentException => ErrorCategory.InvalidArgument,
          FileNotFoundException => ErrorCategory.ObjectNotFound,
          InvalidOperationException => ErrorCategory.InvalidOperation,
          NotSupportedException => ErrorCategory.NotSpecified,
          UnauthorizedAccessException => ErrorCategory.SecurityError,
          PathTooLongException => ErrorCategory.InvalidArgument,
          DirectoryNotFoundException => ErrorCategory.ObjectNotFound,
          IOException => ErrorCategory.WriteError,
          NullReferenceException => ErrorCategory.InvalidData,
          FormatException => ErrorCategory.InvalidData,
          TimeoutException => ErrorCategory.OperationTimeout,
          OutOfMemoryException => ErrorCategory.ResourceUnavailable,
          NotImplementedException => ErrorCategory.NotImplemented,
          OperationCanceledException => ErrorCategory.OperationStopped,
          AccessViolationException => ErrorCategory.SecurityError,
          InvalidCastException => ErrorCategory.InvalidType,
          _ => ErrorCategory.NotSpecified
        },
        targetObject
    )
    {
      ErrorDetails = new ErrorDetails(errorDetailsMessage ?? exception.Message)
      {
        RecommendedAction = recommendedAction
      }
    };


    if (terminating)
    {
      AddOutput(new TerminatingError(error));
    }
    else
    {
      WriteError(error);
    }
  }

  public new void Error(
    string message,
    string? recommendedAction = null,
    string errorId = "PSCmdletError",
    object? targetObject = null,
    ErrorCategory category = ErrorCategory.NotSpecified,
    bool terminating = false
  ) => Error(
    new CmdletInvocationException(message), recommendedAction, errorId, targetObject, null, category, terminating
  );

  /// <summary>Writes a warning message to the pipeline via the async-safe output buffer.</summary>
  public new void WriteWarning(string message) => AddOutput(new WarningRecord(message));

  /// <summary>Writes a verbose message to the pipeline via the async-safe output buffer.</summary>
  public new void WriteVerbose(string message) => AddOutput(new VerboseRecord(message));

  /// <summary>Writes a debug message to the pipeline via the async-safe output buffer.</summary>
  public new void WriteDebug(string message) => AddOutput(new DebugRecord(message));

  /// <summary>Writes a non-terminating error to the pipeline via the async-safe output buffer.</summary>
  public new void WriteError(ErrorRecord errorRecord) => AddOutput(errorRecord);

  /// <summary>Writes a progress record to the pipeline via the async-safe output buffer.</summary>
  public new void WriteProgress(ProgressRecord progressRecord) => AddOutput(progressRecord);

  /// <summary>Writes an information record to the pipeline via the async-safe output buffer.</summary>
  public new void WriteInformation(InformationRecord informationRecord) => AddOutput(informationRecord);

  /// <summary>Writes tagged information data to the pipeline via the async-safe output buffer.</summary>
  public new void WriteInformation(object messageData, string[] tags)
    => AddOutput(new TaggedInformationInfo(messageData, tags));

  /// <summary>
  /// Async-safe equivalent of <see cref="PSCmdlet.ShouldProcess(string, string)"/>.
  /// Marshals the confirmation prompt to the main thread and awaits the user's response.
  /// </summary>
  /// <param name="target">The resource being acted upon (shown in -WhatIf output).</param>
  /// <param name="action">The action being performed. If empty, uses a default message.</param>
  /// <returns><c>true</c> if the operation should proceed; <c>false</c> if the user declined.</returns>
  public async Task<bool> Confirm(string target, string action = "")
  {
    TaskCompletionSource<bool> response = new();
    await using CancellationTokenRegistration _ = PipelineStopToken.Register(() => response.TrySetCanceled());
    AddOutput(new ShouldProcessPrompt(target, action, response));
    return await response.Task.ConfigureAwait(false);
  }

  /// <summary>
  /// Async-safe ShouldProcess with full control over the confirmation dialog text.
  /// Marshals the prompt to the main thread and awaits the user's response.
  /// </summary>
  /// <param name="whatIfMessage">Message displayed when -WhatIf is specified.</param>
  /// <param name="confirmHeader">Header displayed in the confirmation dialog.</param>
  /// <param name="confirmMessage">Body text displayed in the confirmation dialog.</param>
  /// <returns><c>true</c> if the operation should proceed; <c>false</c> if the user declined.</returns>
  public async Task<bool> ConfirmCustom(string whatIfMessage, string confirmHeader = "", string confirmMessage = "")
  {
    TaskCompletionSource<bool> response = new();
    await using CancellationTokenRegistration _ = PipelineStopToken.Register(() => response.TrySetCanceled());
    AddOutput(new ShouldProcessCustomPrompt(whatIfMessage, confirmHeader, confirmMessage, response));
    return await response.Task.ConfigureAwait(false);
  }


  // PowerShell 7.6 introduces a builtin PipelineStopToken, for older versions we
  // implement our own cancellation stop trigger and its cleanup. Once 7.6 is the
  // baseline we can remove the else block.
  private bool _disposed;

  /// <summary>Releases resources used by the cmdlet, including the background worker and output collection.</summary>
  public void Dispose()
  {
    if (_disposed) return;
#if !NET10_0_OR_GREATER
    _cancelSource.Dispose();
#endif
    _workQueue.Dispose();
    _output.Dispose();
    _disposed = true;
    GC.SuppressFinalize(this);
  }

#if !NET10_0_OR_GREATER
  /// Polyfill of the PipelineStopToken from earlier versions

  private readonly CancellationTokenSource _cancelSource = new();

  public CancellationToken PipelineStopToken => _cancelSource.Token;

  protected override void StopProcessing()
  {
    _cancelSource.Cancel();
    ExecuteCleanStep();
  }
#else
  protected sealed override void StopProcessing() => ExecuteCleanStep();
#endif
}

/// <summary>
/// Lightweight base class extending <see cref="PSCmdlet"/> with convenient helper methods
/// for writing output, errors, verbose/debug/warning messages, and progress.
/// Used as the base for both synchronous cmdlets and <see cref="TaskCmdlet"/>.
/// </summary>
public class BetterPSCmdlet : PSCmdlet
{
  /// <summary>The cmdlet's invocation name, used as a prefix in diagnostic messages.</summary>
  protected string Name => MyInvocation.MyCommand.Name;

  internal void Debug(string message, bool raw = false) => WriteDebug(raw ? message : $"{Name}: {message}");
  internal void Verbose(string message, bool raw = false) => WriteVerbose(raw ? message : $"{Name}: {message}");
  internal void Warning(string message, bool raw = false) => WriteWarning(raw ? message : $"{Name}: {message}");


  internal void Info(string message, string[]? tags = null, bool raw = false)
    => WriteInformation(raw ? message : $"{Name}: {message}", tags ?? []);
  internal void Console(string message, bool raw = false)
    => WriteInformation(raw ? message : $"{Name}: {message}", ["PSHOST"]);
  internal void Progress(
    string activity,
    string status = "",
    string currentOperation = "",
    int percentComplete = 0,
    int id = 1,
    int parentId = -1,
    bool completed = false
  ) => WriteProgress(new ProgressRecord(id, activity, status)
  {
    CurrentOperation = currentOperation,
    ParentActivityId = parentId,
    RecordType = completed || percentComplete == 100 ? ProgressRecordType.Completed : ProgressRecordType.Processing,
    PercentComplete = percentComplete
  });

  internal void Error(
      Exception exception,
      string? recommendedAction = null,
      string errorId = "PSCmdletError",
      object? targetObject = null,
      // Usually comes from the exception message, specify this to override
      string? errorDetailsMessage = null,
      // This is often autodetermined
      ErrorCategory? category = null,
      bool terminating = false)
  {
    ErrorRecord error = new(
        exception,
        errorId,
        category ?? exception switch
        {
          ArgumentException => ErrorCategory.InvalidArgument,
          FileNotFoundException => ErrorCategory.ObjectNotFound,
          InvalidOperationException => ErrorCategory.InvalidOperation,
          NotSupportedException => ErrorCategory.NotSpecified,
          UnauthorizedAccessException => ErrorCategory.SecurityError,
          PathTooLongException => ErrorCategory.InvalidArgument,
          DirectoryNotFoundException => ErrorCategory.ObjectNotFound,
          IOException => ErrorCategory.WriteError,
          NullReferenceException => ErrorCategory.InvalidData,
          FormatException => ErrorCategory.InvalidData,
          TimeoutException => ErrorCategory.OperationTimeout,
          OutOfMemoryException => ErrorCategory.ResourceUnavailable,
          NotImplementedException => ErrorCategory.NotImplemented,
          OperationCanceledException => ErrorCategory.OperationStopped,
          AccessViolationException => ErrorCategory.SecurityError,
          InvalidCastException => ErrorCategory.InvalidType,
          _ => ErrorCategory.NotSpecified
        },
        targetObject
    )
    {
      ErrorDetails = new ErrorDetails(errorDetailsMessage ?? exception.Message)
      {
        RecommendedAction = recommendedAction
      }
    };

    if (terminating)
    {
      ThrowTerminatingError(error);
    }
    else
    {
      try
      {
        WriteError(error);
      }
      catch (PipelineStoppedException)
      {
        // This can happen if the pipeline is already stopping when we try to write the error, in that case we just swallow it since the error is likely still visible in the console and there's nothing we can do about it.
      }
    }
  }

  internal void Error(
    string message,
    string? recommendedAction = null,
    string errorId = "PSCmdletError",
    object? targetObject = null,
    ErrorCategory category = ErrorCategory.NotSpecified,
    bool terminating = false
  ) => Error(
    new CmdletInvocationException(message), recommendedAction, errorId, targetObject, null, category, terminating
  );
}

internal record OutputItem(object Item, bool Raw);
internal record TaggedInformationInfo(object MessageData, string[] Tags);
internal record ShouldProcessPrompt(string Target, string Action, TaskCompletionSource<bool> Response);
internal record ShouldProcessCustomPrompt(
    string whatIfMessage,
    string confirmHeader,
    string confirmMessage,
    TaskCompletionSource<bool> Response
);
internal record TerminatingError(ErrorRecord Error);
/** Send this via the pipeline to execute an action on the main thread **/
internal record MainAction(Func<object?> Action, TaskCompletionSource<object?>? Response = null);
/** Sentinel item placed in the output collection to signal that a pipeline step has completed **/
internal record StepComplete;
