using System.Collections.Concurrent;

namespace ModuleFast;

public class ModuleFastCache
{
  private readonly ConcurrentDictionary<string, Task<string>> _cache = new(StringComparer.OrdinalIgnoreCase);
  public static readonly ModuleFastCache Instance = new();

  /// <summary>
  /// Atomically returns the cached task for <paramref name="key"/>, or adds and returns a new task
  /// produced by <paramref name="factory"/>. Using <see cref="ConcurrentDictionary{TKey,TValue}.GetOrAdd"/>
  /// eliminates the get-then-set race that would otherwise fire duplicate in-flight HTTP requests for the
  /// same URI when multiple dependency-resolution tasks complete simultaneously.
  /// </summary>
  public Task<string> GetOrAdd(string key, Func<string, Task<string>> factory) =>
      _cache.GetOrAdd(key, factory);

  public void Clear() => _cache.Clear();
}