using System.IO;
using System.Text.Json;
using TheOptimiser.Models;

namespace TheOptimiser.Services;

public static class CatalogService
{
    public static Catalog Load()
    {
        var disk = Path.Combine(AppContext.BaseDirectory, "catalog.json");
        var json = File.Exists(disk) ? File.ReadAllText(disk) : ReadEmbedded();   // disk override wins; else the copy baked into the exe
        var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        return JsonSerializer.Deserialize<Catalog>(json, opts)
               ?? throw new InvalidOperationException("catalog.json failed to parse.");
    }

    private static string ReadEmbedded()
    {
        using var s = typeof(CatalogService).Assembly.GetManifestResourceStream("catalog.json")
                      ?? throw new InvalidOperationException("catalog.json not found on disk or embedded.");
        using var r = new StreamReader(s);
        return r.ReadToEnd();
    }
}
