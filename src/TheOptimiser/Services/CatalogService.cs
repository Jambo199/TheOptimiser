using System.IO;
using System.Text.Json;
using TheOptimiser.Models;

namespace TheOptimiser.Services;

public static class CatalogService
{
    public static Catalog Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "catalog.json");
        var json = File.ReadAllText(path);
        var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        return JsonSerializer.Deserialize<Catalog>(json, opts)
               ?? throw new InvalidOperationException("catalog.json failed to parse.");
    }
}
