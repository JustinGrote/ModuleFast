using System.Collections.Concurrent;

namespace ModuleFast;

public class ModuleFastCache
{
    private ConcurrentDictionary<string, Task<string>> _cache = new(StringComparer.OrdinalIgnoreCase);
    public static readonly ModuleFastCache Instance = new();

    public Task<string>? Get(string key) => _cache.TryGetValue(key, out var v) ? v : null;
    public void Set(string key, Task<string> value) => _cache[key] = value;
    public void Clear() => _cache.Clear();
}
