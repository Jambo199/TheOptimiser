using System.Text.Json.Serialization;

namespace TheOptimiser.Models;

// Maps catalog.json (built from the 18 reverse-engineered tools). JSON is lower/camelCase;
// deserialized with PropertyNameCaseInsensitive, with [JsonPropertyName] only where the
// JSON name is snake_case and case-insensitive matching is not enough.

public sealed class Tweak
{
    public string Hive { get; set; } = "";
    public string Path { get; set; } = "";
    public string Name { get; set; } = "";
    public string Value { get; set; } = "";
    public string Type { get; set; } = "";
    public string? Default { get; set; }
    public string Category { get; set; } = "";
    public string Description { get; set; } = "";
    public string[] Sources { get; set; } = [];
    public bool DefaultSelected { get; set; }

    // UI-only state (not from JSON)
    [JsonIgnore] public bool Selected { get; set; }
}

public sealed class DebloatApp
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public string Safety { get; set; } = "optional";
    public string Method { get; set; } = "Appx";
    public string[] Sources { get; set; } = [];
    [JsonIgnore] public bool Selected { get; set; }
    [JsonIgnore] public bool? Installed { get; set; }
}

public sealed class InstallApp
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public string Description { get; set; } = "";
    public string[] Sources { get; set; } = [];
    [JsonIgnore] public bool Selected { get; set; }
    [JsonIgnore] public bool? Installed { get; set; }
}

public sealed class ServiceTweak
{
    public string Name { get; set; } = "";
    public string Startup { get; set; } = "";
    public string Original { get; set; } = "";
    public string Category { get; set; } = "";
    public string[] Sources { get; set; } = [];
    [JsonIgnore] public bool Selected { get; set; }
}

public sealed class Advanced
{
    public Tweak[] Defender { get; set; } = [];
    [JsonPropertyName("updates_block_all")] public Tweak[] UpdatesBlockAll { get; set; } = [];
    [JsonPropertyName("updates_drivers_only")] public Tweak[] UpdatesDriversOnly { get; set; } = [];
}

public sealed class Catalog
{
    public Tweak[] Registry { get; set; } = [];
    public ServiceTweak[] Services { get; set; } = [];
    public DebloatApp[] Debloat { get; set; } = [];
    public InstallApp[] Install { get; set; } = [];
    public Advanced Advanced { get; set; } = new();
}
