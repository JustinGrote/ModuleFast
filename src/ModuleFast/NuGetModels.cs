using System.Text.Json.Serialization;

namespace ModuleFast;

public class RegistrationIndex
{
    public RegistrationResource[] Resources { get; set; } = [];
}

public class RegistrationResource
{
    [JsonPropertyName("@type")] public string Type { get; set; } = "";
    [JsonPropertyName("@id")] public string Id { get; set; } = "";
}

public class RegistrationResponse
{
    public int Count { get; set; }
    public RegistrationPage[] Items { get; set; } = [];
}

public class RegistrationPage
{
    [JsonPropertyName("@id")] public string Id { get; set; } = "";
    public string? Lower { get; set; }
    public string? Upper { get; set; }
    public RegistrationLeaf[]? Items { get; set; }
}

public class RegistrationLeaf
{
    public string? PackageContent { get; set; }
    public CatalogEntry CatalogEntry { get; set; } = new();
}

public class CatalogEntry
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    public string Version { get; set; } = "";
    public string[]? Tags { get; set; }
    public DependencyGroup[]? DependencyGroups { get; set; }
    public string? PackageContent { get; set; }
}

public class DependencyGroup
{
    public Dependency[]? Dependencies { get; set; }
}

public class Dependency
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    public string? Range { get; set; }
}
